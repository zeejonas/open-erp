import Fluent
import FluentSQL
import SQLKit

struct CreateRolePermission: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("role_permissions")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("role_id", .uuid, .required)
            .field("permission", .string, .required)
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .tenantForeignKey("role_id", references: "roles")
            .create()
        try await database.createActiveUniqueIndex(
            "role_permissions_active_permission",
            on: "role_permissions",
            columns: "role_id", "permission"
        )
        try await database.createChangeTrigger(on: "role_permissions")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("role_permissions").delete()
    }
}
