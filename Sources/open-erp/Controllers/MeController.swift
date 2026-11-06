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
            .problemResponses()
        authed.patch("me", use: self.patch)
            .openAPI(
                summary: "Update me",
                body: .type(PatchMeDTO.self),
                response: .type(GetUserDTO.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest, .payloadTooLarge, .unsupportedMediaType)
        authed.grouped(OrganizationMiddleware()).get("me", "access", use: self.access)
            .openAPI(
                summary: "Get my organization access",
                description: "Requires active membership. Returns effective permissions in ascending order.",
                headers: .type(OrganizationHeaders.self),
                response: .type(CallerAccessDTO.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest)
        authed.get("me", "organizations", use: self.organizations)
            .openAPI(
                summary: "List my organizations",
                description: "Newest updatedAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.",
                query: [.type(ListPage.self), .type(NoFilters.self)],
                response: .type(Page<GetOrganizationDTO>.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest)
    }

    @Sendable
    func access(req: Request) async throws -> CallerAccessDTO {
        CallerAccessDTO(organizationId: req.organizationID, permissions: req.permissions.map(\.rawValue).sorted())
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
            try await req.db.auditedTransaction(req.auditContext()) { db in
                try await user.update(on: db)
            }
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
