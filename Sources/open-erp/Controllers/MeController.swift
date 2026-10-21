import Fluent
import Vapor

struct MeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let authed = routes.grouped(AuthMiddleware())
        authed.get("me", use: self.show)
        authed.patch("me", use: self.patch)
        authed.get("me", "organizations", use: self.organizations)
    }

    @Sendable
    func show(req: Request) async throws -> GetUserDTO {
        req.user.toGetDTO()
    }

    @Sendable
    func patch(req: Request) async throws -> GetUserDTO {
        try PatchMeDTO.validate(content: req)
        let dto = try req.content.decode(PatchMeDTO.self)
        let user = req.user
        var changed = false
        if let firstName = dto.firstName {
            user.firstName = firstName
            changed = true
        }
        if let lastName = dto.lastName {
            user.lastName = lastName
            changed = true
        }
        if changed {
            user.$updatedBy.id = try user.requireID()
            try await user.update(on: req.db)
        }
        return user.toGetDTO()
    }

    @Sendable
    func organizations(req: Request) async throws -> [GetOrganizationDTO] {
        let userID = try req.userID()
        let memberships = try await OrganizationUser.query(on: req.db)
            .filter(\.$user.$id == userID)
            .join(Organization.self, on: \OrganizationUser.$organization.$id == \Organization.$id)
            .filter(Organization.self, \.$deletedAt == nil)
            .all()
        return try memberships.map { try $0.joined(Organization.self).toGetDTO() }
    }
}
