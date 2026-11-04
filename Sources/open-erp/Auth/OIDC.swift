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

func configureAuthentication(
    _ app: Application,
    lookup: (String) -> String? = Environment.get
) async throws {
    func nonEmptyEnvironment(_ name: String) -> String? {
        guard let value = lookup(name), !value.isEmpty else { return nil }
        return value
    }

    func requiredEnvironment(_ name: String) throws -> String {
        guard let value = nonEmptyEnvironment(name) else {
            throw MissingEnvironmentVariable(name: name)
        }
        return value
    }

    app.initializeSigningKeyState()
    let configuration: OIDCConfiguration
    if app.environment == .testing {
        configuration = OIDCConfiguration(
            issuer: nonEmptyEnvironment("OIDC_ISSUER") ?? OIDCConfiguration.testingIssuer,
            audience: nonEmptyEnvironment("OIDC_AUDIENCE") ?? OIDCConfiguration.testingAudience,
            userinfoURL: nonEmptyEnvironment("OIDC_USERINFO_URL") ?? OIDCConfiguration.testingUserInfoURL
        )
        let key = try ES256PrivateKey(backing: P256.Signing.PrivateKey())
        await app.jwt.keys.add(ecdsa: key)
        app.signingKeysLoaded = true
    } else {
        configuration = OIDCConfiguration(
            issuer: try requiredEnvironment("OIDC_ISSUER"),
            audience: try requiredEnvironment("OIDC_AUDIENCE"),
            userinfoURL: try requiredEnvironment("OIDC_USERINFO_URL")
        )
        let jwksURL = URI(string: try requiredEnvironment("OIDC_JWKS_URL"))
        // Initialize the JWT integration before the server starts accepting requests.
        app.jwt.keys = JWTKeyCollection()
        let client = app.client
        app.lifecycle.use(JWKSRefresher {
            let response = try await client.get(jwksURL) { $0.timeout = .seconds(10) }
            guard response.status == .ok, let body = response.body else {
                throw AuthenticationConfigurationError(message: "JWKS request returned status \(response.status.code)")
            }
            return Data(body.readableBytesView)
        })
    }

    app.oidc = configuration
    app.userInfoFetcher = UserInfoFetcherBox(fetch: fetchUserInfo)
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
