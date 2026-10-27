import Fluent
import Vapor
import VaporToOpenAPI

struct MeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let authed = routes.grouped(AuthMiddleware())
        authed.get("me", use: self.show)
            .openAPI(
                summary: "Get me",
                response: .type(GetUserDTO.self),
                auth: .bearer()
            )
        authed.patch("me", use: self.patch)
            .openAPI(
                summary: "Update me",
                body: .type(PatchMeDTO.self),
                response: .type(GetUserDTO.self),
                auth: .bearer()
            )
        authed.get("me", "organizations", use: self.organizations)
            .openAPI(
                summary: "List my organizations",
                description: "Newest updatedAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.",
                query: [.type(ListPage.self), .type(NoFilters.self)],
                response: .type(Page<GetOrganizationDTO>.self),
                auth: .bearer()
            )
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
    func organizations(req: Request) async throws -> Page<GetOrganizationDTO> {
        let (_, page) = try req.listParameters(NoFilters.self)
        let userID = try req.userID()
        let memberships = try await OrganizationUser.query(on: req.db)
            .filter(\.$user.$id == userID)
            .join(Organization.self, on: \OrganizationUser.$organization.$id == \Organization.$id)
            .filter(Organization.self, \.$deletedAt == nil)
            .newestFirst(Organization.self, \.$updatedAt)
            .paginate(page)
        return try memberships.map { try $0.joined(Organization.self).toGetDTO() }
    }
}
