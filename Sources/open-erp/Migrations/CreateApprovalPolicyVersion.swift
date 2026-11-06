import Fluent
import FluentSQL
import SQLKit

struct CreateApprovalPolicyVersion: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("approval_policy_versions")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("policy_id", .uuid, .required)
            .field("version", .int, .required)
            .field("definition", .json, .required)
            .field("created_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .unique(on: "policy_id", "version")
            .tenantForeignKey("policy_id", references: "approval_policies")
            .unique(on: "organization_id", "id")
            .create()
        try await database.createAppendOnlyTrigger(on: "approval_policy_versions")
        try await database.createChangeTrigger(on: "approval_policy_versions")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("approval_policy_versions").delete()
        try await database.dropAppendOnlyTriggerFunction(on: "approval_policy_versions")
    }
}
