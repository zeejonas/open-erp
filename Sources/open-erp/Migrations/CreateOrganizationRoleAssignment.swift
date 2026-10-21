import Fluent
import FluentSQL
import SQLKit

struct CreateOrganizationRoleAssignment: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("organization_role_assignments")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_user_id", .uuid, .required, .references("organization_users", "id"))
            .field("role_id", .uuid, .required, .references("roles", "id"))
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .create()
        try await database.createActiveUniqueIndex(
            "organization_role_assignments_active_role",
            on: "organization_role_assignments",
            columns: "organization_user_id", "role_id"
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("organization_role_assignments").delete()
    }
}
