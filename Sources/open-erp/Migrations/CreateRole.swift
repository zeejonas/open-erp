import Fluent
import FluentSQL
import SQLKit

struct CreateRole: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("roles")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("name", .string, .required)
            .field("level", .string, .required)
            .field("template_key", .string)
            .field("created_by", .uuid, .references("users", "id"))
            .field("updated_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .create()
        try await database.createActiveUniqueIndex("roles_active_name", on: "roles", columns: "organization_id", "name")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("roles").delete()
    }
}
