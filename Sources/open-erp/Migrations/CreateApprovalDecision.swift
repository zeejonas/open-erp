import Fluent
import FluentSQL
import SQLKit

struct CreateApprovalDecision: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("approval_decisions")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("request_id", .uuid, .required)
            .field("track_id", .uuid)
            .field("stage", .int)
            .field("kind", .string, .required)
            .field("decided_by", .uuid, .references("users", "id"))
            .field("operator", .string)
            .field("qualifying_group_ids", .array(of: .uuid), .required)
            .field("comment", .string)
            .field("created_at", .datetime)
            .tenantForeignKey("request_id", references: "approval_requests")
            .tenantForeignKey("track_id", references: "approval_request_tracks")
            .create()
        try await database.createAppendOnlyTrigger(on: "approval_decisions")
        try await database.createChangeTrigger(on: "approval_decisions")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("approval_decisions").delete()
        try await database.dropAppendOnlyTriggerFunction(on: "approval_decisions")
    }
}
