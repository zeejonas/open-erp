import Fluent
import Vapor

struct RoleController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let roles = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("roles")
        roles.post(use: self.create)
        roles.get(use: self.index)
        roles.group(":roleID") { role in
            role.get(use: self.show)
            role.patch(use: self.patch)
            role.delete(use: self.delete)
        }
    }

    @Sendable
    func create(req: Request) async throws -> GetRoleDTO {
        try req.require(.roleCreate)
        try CreateRoleDTO.validate(content: req)
        let dto = try req.content.decode(CreateRoleDTO.self)
        guard let level = RoleLevel(rawValue: dto.level) else {
            throw Abort(.badRequest, reason: "level must be organization or company")
        }
        let permissions = try permissions(from: dto.permissions, level: level)
        let actorID = try req.userID()

        let role = try await conflictOnDuplicate(Self.duplicateName) {
            try await req.db.transaction { db in
                let role = Role(organizationID: req.organizationID, name: dto.name, level: level, createdByID: actorID)
                try await role.save(on: db)
                try await role.setPermissions(permissions, actorID: actorID, on: db)
                return role
            }
        }
        return role.toGetDTO()
    }

    @Sendable
    func index(req: Request) async throws -> [GetRoleDTO] {
        try req.require(.roleRead)
        return try await Role.query(on: req.db, organizationID: req.organizationID)
            .with(\.$permissionGrants)
            .all()
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
    func patch(req: Request) async throws -> GetRoleDTO {
        try req.require(.roleUpdate)
        try PatchRoleDTO.validate(content: req)
        let dto = try req.content.decode(PatchRoleDTO.self)
        let role = try await findRole(req: req)

        if let level = dto.level, level != role.level {
            throw Abort(.badRequest, reason: "Role level cannot change")
        }
        if let name = dto.name {
            role.name = name
        }

        let updatedPermissions: [Permission]?
        if let rawPermissions = dto.permissions {
            guard let level = role.roleLevel else {
                throw Abort(.badRequest, reason: "Role level is invalid")
            }
            updatedPermissions = try permissions(from: rawPermissions, level: level)
        } else {
            updatedPermissions = nil
        }
        let actorID = try req.userID()

        let saved = try await conflictOnDuplicate(Self.duplicateName) {
            try await req.db.transaction { db in
                if let updatedPermissions {
                    try await role.setPermissions(updatedPermissions, actorID: actorID, on: db)
                } else {
                    try await role.$permissionGrants.load(on: db)
                }
                role.$updatedBy.id = actorID
                try await role.update(on: db)
                return role
            }
        }
        return saved.toGetDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        try req.require(.roleDelete)
        let role = try await findRole(req: req)
        if try await role.isInUse(on: req.db) {
            throw Abort(.conflict, reason: "Role is assigned or used by a pending invitation")
        }
        try await role.softDelete(by: req.userID(), \.$deletedBy, on: req.db)
        return .noContent
    }

    private static let duplicateName = "A role with this name already exists"

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
