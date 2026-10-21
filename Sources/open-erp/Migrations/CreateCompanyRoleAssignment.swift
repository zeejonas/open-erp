import Fluent
import FluentSQL
import SQLKit

struct CreateCompanyRoleAssignment: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("company_role_assignments")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_user_id", .uuid, .required, .references("organization_users", "id"))
            .field("role_id", .uuid, .required, .references("roles", "id"))
            .field("company_id", .uuid, .required, .references("companies", "id"))
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .create()
        try await database.createActiveUniqueIndex(
            "company_role_assignments_active_role",
            on: "company_role_assignments",
            columns: "organization_user_id", "role_id", "company_id"
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("company_role_assignments").delete()
    }
}
