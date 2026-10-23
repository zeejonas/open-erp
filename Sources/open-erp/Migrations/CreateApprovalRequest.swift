import Fluent
import FluentSQL
import SQLKit

struct CreateApprovalRequest: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("approval_requests")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("permission", .string, .required)
            .field("target_id", .uuid)
            .field("change", .json, .required)
            .field("status", .string, .required)
            .field("failure_reason", .string)
            .field("requested_by", .uuid, .required, .references("users", "id"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
        try await database.createAuditTrigger(
            on: "approval_requests",
            protected: ["organization_id", "permission", "target_id", "change", "requested_by", "created_at"]
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema("approval_requests").delete()
        try await database.dropAuditTriggerFunction(on: "approval_requests")
    }
}
