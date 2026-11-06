import Fluent
import FluentSQL
import SQLKit

struct CreateGroupRole: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("group_roles")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("group_id", .uuid, .required)
            .field("role_id", .uuid, .required)
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .tenantForeignKey("group_id", references: "groups")
            .tenantForeignKey("role_id", references: "roles")
            .create()
        try await database.createActiveUniqueIndex(
            "group_roles_active_role",
            on: "group_roles",
            columns: "group_id", "role_id"
        )
        try await database.createChangeTrigger(on: "group_roles")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("group_roles").delete()
    }
}
