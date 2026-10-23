import Fluent
import Vapor

final class Role: Model, @unchecked Sendable {
    static let schema = "roles"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "organization_id")
    var organization: Organization

    @Field(key: "name")
    var name: String

    @Field(key: "level")
    var level: String

    @OptionalField(key: "template_key")
    var templateKey: String?

    @Children(for: \.$role)
    var permissionGrants: [RolePermission]

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "updated_by") var updatedBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(
        organizationID: UUID,
        name: String,
        level: RoleLevel,
        templateKey: String? = nil,
        createdByID: UUID? = nil
    ) {
        self.$organization.id = organizationID
        self.name = name
        self.level = level.rawValue
        self.templateKey = templateKey
        self.$createdBy.id = createdByID
    }

    var roleLevel: RoleLevel? { RoleLevel(rawValue: level) }

    func toGetDTO() -> GetRoleDTO {
        .init(
            id: id,
            name: name,
            level: level,
            templateKey: templateKey,
            permissions: permissionGrants.map(\.permission).sorted(),
            createdById: $createdBy.id,
            updatedById: $updatedBy.id,
            deletedById: $deletedBy.id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    static func query(on db: any Database, organizationID: UUID) -> QueryBuilder<Role> {
        query(on: db).filter(\.$organization.$id == organizationID)
    }

    @discardableResult
    static func copyTemplates(
        into organizationID: UUID,
        createdByID: UUID,
        on db: any Database
    ) async throws -> [Role] {
        var created: [Role] = []
        for template in RoleTemplate.all {
            let role = Role(
                organizationID: organizationID,
                name: template.name,
                level: template.level,
                templateKey: template.key,
                createdByID: createdByID
            )
            try await role.save(on: db)
            try await role.setPermissions(template.permissions, actorID: createdByID, on: db)
            created.append(role)
        }
        return created
    }

    /// Soft-deletes removed grants and inserts added ones, so every permission change keeps who made it and when.
    func setPermissions(_ permissions: [Permission], actorID: UUID, on db: any Database) async throws {
        let roleID = try requireID()
        let current = try await $permissionGrants.query(on: db).all()
        let wanted = Set(permissions.map(\.rawValue))
        for grant in current where !wanted.contains(grant.permission) {
            try await grant.softDelete(by: actorID, \.$deletedBy, on: db)
        }
        let held = Set(current.map(\.permission))
        for permission in permissions where !held.contains(permission.rawValue) {
            try await RolePermission(roleID: roleID, permission: permission.rawValue, createdByID: actorID).save(on: db)
        }
        try await $permissionGrants.load(on: db)
    }

    /// A role attached to an active group cannot be deleted. Attachments on a deleted group do not count.
    func isInUse(on db: any Database) async throws -> Bool {
        try await GroupRole.query(on: db)
            .join(AccessGroup.self, on: \GroupRole.$group.$id == \AccessGroup.$id)
            .filter(\.$role.$id == requireID())
            .filter(AccessGroup.self, \.$deletedAt == nil)
            .first() != nil
    }
}

final class RolePermission: Model, @unchecked Sendable {
    static let schema = "role_permissions"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "role_id")
    var role: Role

    @Field(key: "permission")
    var permission: String

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(roleID: UUID, permission: String, createdByID: UUID? = nil) {
        self.$role.id = roleID
        self.permission = permission
        self.$createdBy.id = createdByID
    }
}
