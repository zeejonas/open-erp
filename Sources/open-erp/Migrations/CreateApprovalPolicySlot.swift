import Fluent
import FluentSQL
import SQLKit

struct CreateApprovalPolicySlot: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("approval_policy_slots")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("policy_id", .uuid, .required)
            .field("stage", .int, .required)
            .field("group_id", .uuid, .required)
            .field("required", .int, .required)
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .tenantForeignKey("policy_id", references: "approval_policies")
            .tenantForeignKey("group_id", references: "groups")
            .create()
        try await database.createActiveUniqueIndex(
            "approval_policy_slots_active_slot",
            on: "approval_policy_slots",
            columns: "policy_id", "stage", "group_id"
        )
        try await database.createChangeTrigger(on: "approval_policy_slots")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("approval_policy_slots").delete()
    }
}
