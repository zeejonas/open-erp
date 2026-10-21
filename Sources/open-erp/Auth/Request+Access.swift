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

    /// Verifies the bearer token. Signature, issuer, audience, and expiry failures are `401`.
    func verifiedAccessToken() async throws -> AccessToken {
        let token: AccessToken
        do {
            token = try await jwt.verify(as: AccessToken.self)
        } catch let abort as any AbortError {
            throw abort
        } catch {
            throw Abort(.unauthorized)
        }
        let oidc = application.oidc
        guard token.issuer.value == oidc.issuer, token.audience.value.contains(oidc.audience) else {
            throw Abort(.unauthorized)
        }
        return token
    }
}
