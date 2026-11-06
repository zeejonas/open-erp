import Fluent
import FluentSQL
import SQLKit

struct CreateGroupCompany: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("group_companies")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("group_id", .uuid, .required)
            .field("company_id", .uuid, .required)
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .tenantForeignKey("group_id", references: "groups")
            .tenantForeignKey("company_id", references: "companies")
            .create()
        try await database.createActiveUniqueIndex(
            "group_companies_active_company",
            on: "group_companies",
            columns: "group_id", "company_id"
        )
        try await database.createChangeTrigger(on: "group_companies")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("group_companies").delete()
    }
}
