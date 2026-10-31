import Vapor

struct PlatformAdminMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.user.isPlatformAdmin else { throw Abort(.forbidden) }
        return try await next.respond(to: request)
    }
}
