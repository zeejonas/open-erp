import Fluent
import Vapor

/// Verifies the bearer token and resolves the user by `auth_subject`.
/// A valid token with no bound user is `403`, because users are created only by accepting an invitation.
struct AuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let token = try await request.verifiedAccessToken()
        guard let user = try await User.bound(to: token.subjectID, on: request.db)
        else {
            throw Abort(.forbidden)
        }
        request.user = user
        return try await next.respond(to: request)
    }
}
