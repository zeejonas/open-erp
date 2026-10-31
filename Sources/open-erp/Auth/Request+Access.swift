import Fluent
import JWT
import Vapor

struct AuthenticatedUserKey: StorageKey {
    typealias Value = User
}

struct PermissionsKey: StorageKey {
    typealias Value = Set<Permission>
}

extension Request {
    var authenticatedUser: User? {
        storage[AuthenticatedUserKey.self]
    }

    var user: User {
        get {
            guard let user = authenticatedUser else {
                fatalError("AuthMiddleware must run before accessing req.user")
            }
            return user
        }
        set {
            storage[AuthenticatedUserKey.self] = newValue
        }
    }

    var permissions: Set<Permission> {
        get { storage[PermissionsKey.self] ?? [] }
        set { storage[PermissionsKey.self] = newValue }
    }

    func require(_ permission: Permission) throws {
        guard permissions.contains(permission) else {
            throw Abort(.forbidden, reason: "Missing permission \(permission.rawValue)")
        }
    }

    func userID() throws -> UUID {
        try user.requireID()
    }

    /// Every protected path checks the shared primary database before admitting a request.
    func verifiedAccessToken() async throws -> AccessToken {
        let (bearer, token) = try await verifiedAccessTokenIgnoringRevocation()
        let revoked: Bool
        do {
            revoked = try await RevokedAccessToken.find(RevokedAccessToken.fingerprint(bearer), on: db) != nil
        } catch {
            throw ProblemAbort(status: .serviceUnavailable, code: .authenticationUnavailable)
        }
        guard !revoked else {
            throw ProblemAbort(status: .unauthorized, code: .accessTokenRevoked)
        }
        return token
    }

    /// Verifies signature, issuer, audience, and expiry; failures are `401`.
    /// Skips revocation, so only logout may call it.
    func verifiedAccessTokenIgnoringRevocation() async throws -> (bearer: String, token: AccessToken) {
        guard let bearer = headers.bearerAuthorization?.token else {
            throw Abort(.unauthorized)
        }
        let token: AccessToken
        do {
            token = try await jwt.verify(bearer, as: AccessToken.self)
        } catch {
            throw ProblemAbort(status: .unauthorized, code: .invalidAccessToken)
        }
        let oidc = application.oidc
        guard token.issuer.value == oidc.issuer, token.audience.value.contains(oidc.audience) else {
            throw ProblemAbort(status: .unauthorized, code: .invalidAccessToken)
        }
        return (bearer, token)
    }
}
