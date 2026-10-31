import Fluent
import FluentSQL
import SQLKit

struct CreateOrganization: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("organizations")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("onboarded_at", .datetime)
            .field("code", .string, .required)
            .field("name", .string, .required)
            .field("created_by", .uuid, .references("users", "id"))
            .field("updated_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .unique(on: "code")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("organizations").delete()
    }
}
