import Fluent
import FluentSQL
import SQLKit

struct CreateApprovalPolicy: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("approval_policies")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("name", .string, .required)
            .field("permission", .string, .required)
            .field("fields", .array(of: .string), .required)
            .field("company_id", .uuid)
            .field("current_version", .int, .required)
            .field("created_by", .uuid, .references("users", "id"))
            .field("updated_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .tenantForeignKey("company_id", references: "companies")
            .unique(on: "organization_id", "id")
            .create()
        try await database.createActiveUniqueIndex(
            "approval_policies_active_name",
            on: "approval_policies",
            columns: "organization_id", "name"
        )
        try await database.createChangeTrigger(on: "approval_policies")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("approval_policies").delete()
    }
}
