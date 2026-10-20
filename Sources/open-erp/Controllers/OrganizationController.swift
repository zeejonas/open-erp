import Fluent
import Vapor

struct OrganizationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("organizations", use: self.create)

        let scoped = routes.grouped(OrganizationMiddleware())
        scoped.get("organization", use: self.show)
        scoped.patch("organization", use: self.patch)
        scoped.delete("organization", use: self.delete)
    }

    @Sendable
    func create(req: Request) async throws -> GetOrganizationDTO {
        try CreateOrganizationDTO.validate(content: req)
        let dto = try req.content.decode(CreateOrganizationDTO.self)

        let organization = Organization(
            code: dto.code,
            name: dto.name,
            createdBy: nil,
            updatedBy: nil,
            deletedBy: nil
        )
        try await organization.save(on: req.db)
        return organization.toGetDTO()
    }

    @Sendable
    func show(req: Request) async throws -> GetOrganizationDTO {
        guard let organization = try await Organization.find(req.organizationID, on: req.db) else {
            throw Abort(.notFound)
        }
        return organization.toGetDTO()
    }

    @Sendable
    func patch(req: Request) async throws -> GetOrganizationDTO {
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

        try await organization.update(on: req.db)
        return organization.toGetDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        guard let organization = try await Organization.find(req.organizationID, on: req.db) else {
            throw Abort(.notFound)
        }
        try await organization.delete(on: req.db)
        return .noContent
    }
}
