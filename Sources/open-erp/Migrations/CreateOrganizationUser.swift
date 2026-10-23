import Fluent
import FluentSQL
import SQLKit

struct CreateOrganizationUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("organization_users")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("user_id", .uuid, .required, .references("users", "id"))
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .create()
        try await database.createActiveUniqueIndex(
            "organization_users_active_member",
            on: "organization_users",
            columns: "organization_id", "user_id"
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("organization_users").delete()
    }
}
