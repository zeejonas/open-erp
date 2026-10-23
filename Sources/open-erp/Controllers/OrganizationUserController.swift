import Fluent
import Vapor

struct OrganizationUserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let links = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("organization-users")
        links.group(":userID") { link in
            link.delete(use: self.delete)
        }
    }

    /// Removes the member and every group membership held through that membership.
    @Sendable
    func delete(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.organizationUserDelete)
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        return try await req.approvals.submit(.organizationUserDelete(userID: userID))
    }
}
