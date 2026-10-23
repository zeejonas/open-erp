import Fluent
import FluentSQL
import SQLKit

struct CreateApprovalPolicySlot: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("approval_policy_slots")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("policy_id", .uuid, .required, .references("approval_policies", "id"))
            .field("stage", .int, .required)
            .field("group_id", .uuid, .required, .references("groups", "id"))
            .field("required", .int, .required)
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .create()
        try await database.createActiveUniqueIndex(
            "approval_policy_slots_active_slot",
            on: "approval_policy_slots",
            columns: "policy_id", "stage", "group_id"
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("approval_policy_slots").delete()
    }
}
