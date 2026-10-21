import Fluent
import Vapor

struct OrganizationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let scoped = routes.grouped(AuthMiddleware(), OrganizationMiddleware())
        scoped.get("organization", use: self.show)
        scoped.patch("organization", use: self.patch)
        scoped.delete("organization", use: self.delete)
    }

    @Sendable
    func show(req: Request) async throws -> GetOrganizationDTO {
        try req.require(.organizationRead)
        guard let organization = try await Organization.find(req.organizationID, on: req.db) else {
            throw Abort(.notFound)
        }
        return organization.toGetDTO()
    }

    @Sendable
    func patch(req: Request) async throws -> GetOrganizationDTO {
        try req.require(.organizationUpdate)
        try PatchOrganizationDTO.validate(content: req)
        let dto = try req.content.decode(PatchOrganizationDTO.self)

        guard let organization = try await Organization.find(req.organizationID, on: req.db) else {
            throw Abort(.notFound)
        }

        if let code = dto.code {
            organization.code = code
        }
        if let name = dto.name {
            organization.name = name
        }
        organization.$updatedBy.id = try req.userID()

        try await conflictOnDuplicate("An organization with this code already exists") {
            try await organization.update(on: req.db)
        }
        return organization.toGetDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        try req.require(.organizationDelete)
        guard let organization = try await Organization.find(req.organizationID, on: req.db) else {
            throw Abort(.notFound)
        }
        try await organization.softDelete(by: req.userID(), \.$deletedBy, on: req.db)
        return .noContent
    }
}
