import Fluent
import SQLKit
import Vapor

/// Verifies the bearer token and resolves the user by `auth_subject`.
/// A valid token with no bound user is `403`, because users are created only by accepting an invitation
/// or registering a service account. Service accounts are re-checked on every request so disable and
/// delete take effect before their tokens expire.
struct AuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let token = try await request.verifiedAccessToken()
        guard let user = try await User.bound(to: token.subjectID, on: request.db)
        else {
            throw Abort(.forbidden)
        }
        request.user = user
        if user.kind == .service {
            guard let account = try await ServiceAccount.find(user.id, on: request.db), account.disabledAt == nil else {
                throw Abort(.forbidden)
            }
            await recordUse(of: account, request: request)
        }
        return try await next.respond(to: request)
    }

    /// Last use is access-review evidence, not an authorization input, so a failure is logged and ignored.
    /// The conditional update writes, and is audited, at most once per account per day.
    private func recordUse(of account: ServiceAccount, request: Request) async {
        if let lastUsedAt = account.lastUsedAt, lastUsedAt > Date().addingTimeInterval(-86_400) { return }
        do {
            let id = try account.requireID()
            try await request.db.auditedTransaction(request.auditContext()) { db in
                try await db.requireSQL().raw("""
                    UPDATE service_accounts SET last_used_at = now()
                    WHERE id = \(bind: id) AND (last_used_at IS NULL OR last_used_at < now() - interval '1 day')
                    """).run()
            }
        } catch {
            request.logger.warning("Could not record service account use", metadata: ["error": "\(String(reflecting: error))"])
        }
    }
}
