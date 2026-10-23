import Fluent
import FluentSQL
import SQLKit

struct CreateGroupRole: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("group_roles")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("group_id", .uuid, .required, .references("groups", "id"))
            .field("role_id", .uuid, .required, .references("roles", "id"))
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .create()
        try await database.createActiveUniqueIndex(
            "group_roles_active_role",
            on: "group_roles",
            columns: "group_id", "role_id"
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("group_roles").delete()
    }
}
