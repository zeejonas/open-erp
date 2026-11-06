import Fluent
import FluentSQL
import SQLKit

struct CreateGroup: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("groups")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("name", .string, .required)
            .field("template_key", .string)
            .field("created_by", .uuid, .references("users", "id"))
            .field("updated_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .unique(on: "organization_id", "id")
            .create()
        try await database.createActiveUniqueIndex(
            "groups_active_name",
            on: "groups",
            columns: "organization_id", "name"
        )
        try await database.createChangeTrigger(on: "groups")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("groups").delete()
    }
}
