import Fluent
import Vapor
import VaporToOpenAPI

struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let scoped = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("users")
        scoped.get(use: self.index)
            .openAPI(
                summary: "List users",
                description: "Requires organization_user:read. Newest updatedAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.",
                query: [.type(ListPage.self), .type(UserListFilters.self)],
                headers: .type(OrganizationHeaders.self),
                response: .type(Page<GetUserDTO>.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest)
        scoped.group(":userID") { user in
            user.get(use: self.show)
                .openAPI(
                    summary: "Get user",
                    description: "Requires organization_user:read.",
                    headers: .type(OrganizationHeaders.self),
                    response: .type(GetUserDTO.self),
                    auth: .bearer()
                )
                .problemResponses(.badRequest, .notFound)
        }
    }

    @Sendable
    func index(req: Request) async throws -> Page<GetUserDTO> {
        try req.require(.organizationUserRead)
        let (filters, page) = try req.listParameters(UserListFilters.self)
        var users = User.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$firstName, contains: filters.firstName)
            .filter(\.$lastName, contains: filters.lastName)
            .filter(\.$email, contains: filters.email)
        if let groupID = filters.groupId {
            users = users
                .join(GroupMember.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
                .join(AccessGroup.self, on: \GroupMember.$group.$id == \AccessGroup.$id)
                .filter(GroupMember.self, \.$group.$id == groupID)
                .filter(GroupMember.self, \.$deletedAt == nil)
                .filter(AccessGroup.self, \.$deletedAt == nil)
        }
        return try await users
            .newestFirst(\.$updatedAt)
            .paginate(page)
            .map { $0.toGetDTO() }
    }

    @Sendable
    func show(req: Request) async throws -> GetUserDTO {
        try req.require(.organizationUserRead)
        let user = try await self.findUser(req: req)
        return user.toGetDTO()
    }

    private func findUser(req: Request) async throws -> User {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        guard let user = try await User.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$id == userID)
            .first()
        else {
            throw Abort(.notFound)
        }
        return user
    }
}
