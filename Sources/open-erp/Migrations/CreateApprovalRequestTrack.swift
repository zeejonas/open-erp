import Fluent
import FluentSQL
import SQLKit

struct CreateApprovalRequestTrack: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("approval_request_tracks")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("request_id", .uuid, .required, .references("approval_requests", "id"))
            .field("policy_version_id", .uuid, .required, .references("approval_policy_versions", "id"))
            .field("current_stage", .int, .required)
            .field("status", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
        try await database.createAuditTrigger(
            on: "approval_request_tracks",
            protected: ["request_id", "policy_version_id", "created_at"]
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("approval_request_tracks").delete()
        try await database.dropAuditTriggerFunction(on: "approval_request_tracks")
    }
}
