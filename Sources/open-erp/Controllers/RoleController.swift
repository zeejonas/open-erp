import Fluent
import Vapor
import VaporToOpenAPI

struct RoleController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let roles = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("roles")
        roles.post(use: self.create)
            .openAPI(
                summary: "Create role",
                description: "Requires role:create. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                headers: .type(OrganizationHeaders.self),
                body: .type(CreateRoleDTO.self),
                response: .type(GetRoleDTO.self),
                auth: .bearer()
            )
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        roles.get(use: self.index)
            .openAPI(
                summary: "List roles",
                description: "Requires role:read. Newest updatedAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.",
                query: [.type(ListPage.self), .type(RoleListFilters.self)],
                headers: .type(OrganizationHeaders.self),
                response: .type(Page<GetRoleDTO>.self),
                auth: .bearer()
            )
        roles.group(":roleID") { role in
            role.get(use: self.show)
                .openAPI(
                    summary: "Get role",
                    description: "Requires role:read.",
                    headers: .type(OrganizationHeaders.self),
                    response: .type(GetRoleDTO.self),
                    auth: .bearer()
                )
            role.patch(use: self.patch)
                .openAPI(
                    summary: "Update role",
                    description: "Requires role:update. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                    headers: .type(OrganizationHeaders.self),
                    body: .type(PatchRoleDTO.self),
                    response: .type(GetRoleDTO.self),
                    auth: .bearer()
                )
                .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
            role.delete(use: self.delete)
                .openAPI(
                    summary: "Delete role",
                    description: "Requires role:delete. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                    headers: .type(OrganizationHeaders.self),
                    responseDescription: "Deleted",
                    statusCode: 204,
                    auth: .bearer()
                )
                .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        }
    }

    @Sendable
    func create(req: Request) async throws -> ApprovalOutcome<GetRoleDTO> {
        try req.require(.roleCreate)
        try CreateRoleDTO.validate(content: req)
        let dto = try req.content.decode(CreateRoleDTO.self)
        guard let level = RoleLevel(rawValue: dto.level) else {
            throw Abort(.badRequest, reason: "level must be organization or company")
        }
        let permissions = try permissions(from: dto.permissions, level: level)
        return try await req.approvals.submit(.roleCreate(RoleDraft(
            name: dto.name,
            level: level.rawValue,
            permissions: permissions.map(\.rawValue).sorted()
        )))
    }

    @Sendable
    func index(req: Request) async throws -> Page<GetRoleDTO> {
        try req.require(.roleRead)
        let (filters, page) = try req.listParameters(RoleListFilters.self)
        var roles = Role.query(on: req.db, organizationID: req.organizationID)
            .with(\.$permissionGrants)
            .filter(\.$name, contains: filters.name)
        if let level = filters.level {
            roles = roles.filter(\.$level == level.rawValue)
        }
        return try await roles
            .newestFirst(\.$updatedAt)
            .paginate(page)
            .map { $0.toGetDTO() }
    }

    @Sendable
    func show(req: Request) async throws -> GetRoleDTO {
        try req.require(.roleRead)
        let role = try await findRole(req: req)
        try await role.$permissionGrants.load(on: req.db)
        return role.toGetDTO()
    }

    @Sendable
    func patch(req: Request) async throws -> ApprovalOutcome<GetRoleDTO> {
        try req.require(.roleUpdate)
        try PatchRoleDTO.validate(content: req)
        let dto = try req.content.decode(PatchRoleDTO.self)
        let role = try await findRole(req: req)
        if let level = dto.level, level != role.level {
            throw Abort(.badRequest, reason: "Role level cannot change")
        }
        try await role.$permissionGrants.load(on: req.db)
        let before = RoleSnapshot(name: role.name, permissions: role.permissionGrants.map(\.permission).sorted())
        var after = before
        if let name = dto.name {
            after.name = name
        }
        if let rawPermissions = dto.permissions {
            guard let level = role.roleLevel else {
                throw Abort(.badRequest, reason: "Role level is invalid")
            }
            after.permissions = try permissions(from: rawPermissions, level: level).map(\.rawValue).sorted()
        }
        return try await req.approvals.submit(.roleUpdate(id: try role.requireID(), before: before, after: after))
    }

    @Sendable
    func delete(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.roleDelete)
        let role = try await findRole(req: req)
        try await role.$permissionGrants.load(on: req.db)
        return try await req.approvals.submit(.roleDelete(
            id: try role.requireID(),
            before: RoleSnapshot(name: role.name, permissions: role.permissionGrants.map(\.permission).sorted())
        ))
    }

    private func findRole(req: Request) async throws -> Role {
        guard let roleID = req.parameters.get("roleID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid role ID")
        }
        guard let role = try await Role.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$id == roleID)
            .first()
        else {
            throw Abort(.notFound)
        }
        return role
    }
}
