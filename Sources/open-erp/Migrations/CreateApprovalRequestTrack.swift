import Fluent
import FluentSQL
import SQLKit

struct CreateApprovalRequestTrack: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("approval_request_tracks")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("request_id", .uuid, .required)
            .field("policy_version_id", .uuid, .required)
            .field("current_stage", .int, .required)
            .field("status", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .tenantForeignKey("request_id", references: "approval_requests")
            .tenantForeignKey("policy_version_id", references: "approval_policy_versions")
            .unique(on: "organization_id", "id")
            .create()
        try await database.createAppendOnlyTrigger(
            on: "approval_request_tracks",
            protected: ["organization_id", "request_id", "policy_version_id", "created_at"]
        )
        try await database.createChangeTrigger(on: "approval_request_tracks")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("approval_request_tracks").delete()
        try await database.dropAppendOnlyTriggerFunction(on: "approval_request_tracks")
    }
}
