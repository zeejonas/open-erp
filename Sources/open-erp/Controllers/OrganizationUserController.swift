import Fluent
import Vapor
import VaporToOpenAPI

struct OrganizationUserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let links = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("organization-users")
        links.group(":userID") { link in
            link.delete(use: self.delete)
                .openAPI(
                    summary: "Delete organization user",
                    description: "Requires organization_user:delete. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                    headers: .type(OrganizationHeaders.self),
                    responseDescription: "Deleted",
                    statusCode: 204,
                    auth: .bearer()
                )
                .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
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
