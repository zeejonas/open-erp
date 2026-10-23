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
    func delete(req: Request) async throws -> HTTPStatus {
        try req.require(.organizationUserDelete)
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }

        guard let membership = try await OrganizationUser.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound)
        }

        let actorID = try req.userID()
        let membershipID = try membership.requireID()
        try await req.db.transaction { db in
            for groupMembership in try await GroupMember.query(on: db)
                .filter(\.$organizationUser.$id == membershipID)
                .all()
            {
                try await groupMembership.softDelete(by: actorID, \.$deletedBy, on: db)
            }
            try await membership.softDelete(by: actorID, \.$deletedBy, on: db)
        }
        return .noContent
    }
}
