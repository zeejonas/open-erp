import Fluent
import FluentSQL
import SQLKit

struct CreateCompanyUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("company_users")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("company_id", .uuid, .required)
            .field("user_id", .uuid, .required, .references("users", "id"))
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .unique(on: "company_id", "user_id")
            .tenantForeignKey("company_id", references: "companies")
            .create()
        try await database.createChangeTrigger(on: "company_users")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("company_users").delete()
    }
}