import Fluent
import FluentSQL
import SQLKit

struct CreateGroupCompany: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("group_companies")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("group_id", .uuid, .required, .references("groups", "id"))
            .field("company_id", .uuid, .required, .references("companies", "id"))
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .create()
        try await database.createActiveUniqueIndex(
            "group_companies_active_company",
            on: "group_companies",
            columns: "group_id", "company_id"
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("group_companies").delete()
    }
}
