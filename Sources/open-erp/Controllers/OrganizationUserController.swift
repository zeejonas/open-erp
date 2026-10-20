import Fluent
import Vapor

struct OrganizationUserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let links = routes.grouped(OrganizationMiddleware()).grouped("organization-users")

        links.post(use: self.create)
        links.group(":userID") { link in
            link.delete(use: self.delete)
        }
    }

    @Sendable
    func create(req: Request) async throws -> HTTPStatus {
        try CreateOrganizationUserDTO.validate(content: req)
        let dto = try req.content.decode(CreateOrganizationUserDTO.self)

        guard try await User.find(dto.userId, on: req.db) != nil else {
            throw Abort(.notFound, reason: "User not found")
        }

        if let existing = try await OrganizationUser.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$user.$id == dto.userId)
            .withDeleted()
            .first()
        {
            if existing.deletedAt == nil {
                throw Abort(.conflict, reason: "User is already linked to this organization")
            }
            existing.$deletedBy.id = nil
            try await existing.restore(on: req.db)
            return .created
        }

        let link = OrganizationUser(
            organizationID: req.organizationID,
            userID: dto.userId
        )
        try await link.save(on: req.db)
        return .created
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }

        guard let link = try await OrganizationUser.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound)
        }

        try await link.delete(on: req.db)
        return .noContent
    }
}
