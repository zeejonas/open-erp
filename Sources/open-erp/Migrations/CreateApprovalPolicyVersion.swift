import Fluent
import FluentSQL
import SQLKit

struct CreateApprovalPolicyVersion: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("approval_policy_versions")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("policy_id", .uuid, .required, .references("approval_policies", "id"))
            .field("version", .int, .required)
            .field("definition", .json, .required)
            .field("created_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .unique(on: "policy_id", "version")
            .create()
        try await database.createAuditTrigger(on: "approval_policy_versions")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("approval_policy_versions").delete()
        try await database.dropAuditTriggerFunction(on: "approval_policy_versions")
    }
}
