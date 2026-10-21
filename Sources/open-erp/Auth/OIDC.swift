import Crypto
import Foundation
import JWT
import NIOCore
import Vapor

struct OIDCConfiguration: Sendable {
    var issuer: String
    var audience: String
    var userinfoURL: String

    static let testingIssuer = "https://issuer.test.open-erp.local"
    static let testingAudience = "open-erp-test"
    static let testingUserInfoURL = "https://userinfo.test.open-erp.local"
}

struct MissingEnvironmentVariable: Error, CustomStringConvertible {
    var name: String
    var description: String { "Missing \(name)" }
}

struct AuthenticationConfigurationError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

private struct OIDCConfigurationKey: StorageKey {
    typealias Value = OIDCConfiguration
}

extension Application {
    var oidc: OIDCConfiguration {
        get {
            guard let configuration = storage[OIDCConfigurationKey.self] else {
                fatalError("OIDC is not configured")
            }
            return configuration
        }
        set {
            storage[OIDCConfigurationKey.self] = newValue
        }
    }
}

struct UserInfo: Content, Sendable {
    var email: String?
    var emailVerified: Bool

    enum CodingKeys: String, CodingKey {
        case email
        case emailVerified = "email_verified"
    }
}

extension UserInfo {
    /// Some providers send `email_verified` as the string `"true"`; a missing value means unverified.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        if let flag = try? container.decode(Bool.self, forKey: .emailVerified) {
            emailVerified = flag
        } else {
            emailVerified = (try? container.decode(String.self, forKey: .emailVerified)) == "true"
        }
    }
}

final class UserInfoFetcherBox: @unchecked Sendable {
    var fetch: (Request) async throws -> UserInfo

    init(fetch: @escaping (Request) async throws -> UserInfo) {
        self.fetch = fetch
    }
}

private struct UserInfoFetcherKey: StorageKey {
    typealias Value = UserInfoFetcherBox
}

extension Application {
    var userInfoFetcher: UserInfoFetcherBox {
        get {
            guard let fetcher = storage[UserInfoFetcherKey.self] else {
                fatalError("Userinfo fetcher is not configured")
            }
            return fetcher
        }
        set {
            storage[UserInfoFetcherKey.self] = newValue
        }
    }
}

func configureAuthentication(_ app: Application) async throws {
    let configuration: OIDCConfiguration
    if app.environment == .testing {
        configuration = OIDCConfiguration(
            issuer: nonEmptyEnvironment("OIDC_ISSUER") ?? OIDCConfiguration.testingIssuer,
            audience: nonEmptyEnvironment("OIDC_AUDIENCE") ?? OIDCConfiguration.testingAudience,
            userinfoURL: nonEmptyEnvironment("OIDC_USERINFO_URL") ?? OIDCConfiguration.testingUserInfoURL
        )
        let key = try ES256PrivateKey(backing: P256.Signing.PrivateKey())
        await app.jwt.keys.add(ecdsa: key)
    } else {
        configuration = OIDCConfiguration(
            issuer: try requiredEnvironment("OIDC_ISSUER"),
            audience: try requiredEnvironment("OIDC_AUDIENCE"),
            userinfoURL: try requiredEnvironment("OIDC_USERINFO_URL")
        )
        let jwksURL = try requiredEnvironment("OIDC_JWKS_URL")
        let response = try await app.client.get(URI(string: jwksURL))
        guard response.status == .ok, let body = response.body, !body.readableBytesView.isEmpty else {
            throw AuthenticationConfigurationError(message: "Failed to fetch JWKS from OIDC_JWKS_URL")
        }
        // jwt-kit 5.2 loads a JSON Web Key Set with `add(jwksJSON:)`.
        try await app.jwt.keys.add(jwksJSON: String(buffer: body))
    }

    app.oidc = configuration
    app.userInfoFetcher = UserInfoFetcherBox(fetch: fetchUserInfo)
}

private func nonEmptyEnvironment(_ name: String) -> String? {
    guard let value = Environment.get(name), !value.isEmpty else { return nil }
    return value
}

private func requiredEnvironment(_ name: String) throws -> String {
    guard let value = nonEmptyEnvironment(name) else {
        throw MissingEnvironmentVariable(name: name)
    }
    return value
}

func fetchUserInfo(_ request: Request) async throws -> UserInfo {
    guard let token = request.headers.bearerAuthorization?.token else {
        throw Abort(.unauthorized)
    }
    let response = try await request.client.get(URI(string: request.application.oidc.userinfoURL)) { outgoing in
        outgoing.headers.bearerAuthorization = .init(token: token)
    }
    guard response.status == .ok else {
        throw Abort(.badGateway, reason: "OIDC userinfo request failed")
    }
    return try response.content.decode(UserInfo.self)
}
