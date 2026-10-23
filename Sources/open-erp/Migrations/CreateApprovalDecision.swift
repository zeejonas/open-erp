import Fluent
import FluentSQL
import SQLKit

struct CreateApprovalDecision: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("approval_decisions")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("request_id", .uuid, .required, .references("approval_requests", "id"))
            .field("track_id", .uuid, .references("approval_request_tracks", "id"))
            .field("stage", .int)
            .field("kind", .string, .required)
            .field("decided_by", .uuid, .references("users", "id"))
            .field("operator", .string)
            .field("qualifying_group_ids", .array(of: .uuid), .required)
            .field("comment", .string)
            .field("created_at", .datetime)
            .create()
        try await database.createAuditTrigger(on: "approval_decisions")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("approval_decisions").delete()
        try await database.dropAuditTriggerFunction(on: "approval_decisions")
    }
}
