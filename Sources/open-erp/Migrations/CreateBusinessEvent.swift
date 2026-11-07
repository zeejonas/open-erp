import Fluent
import FluentSQL
import SQLKit

struct CreateBusinessEvent: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BusinessEvent.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("type", .string, .required)
            .field("schema_version", .int, .required)
            .field("resource_type", .string, .required)
            .field("resource_id", .uuid, .required)
            .field("revision", .int64, .required)
            .field("company_id", .uuid)
            .field("actor_type", .string, .required)
            .field("actor_id", .uuid)
            .field("requested_by_id", .uuid)
            .field("request_id", .string)
            .field("approval_request_id", .uuid)
            .field("changed_fields", .array(of: .string), .required)
            .field("payload", .data, .required)
            .field("payload_digest", .string, .required)
            .field("transaction_id", .int64, .required)
            .field("capture_snapshot", .string, .required)
            .field("capture_order", .int64, .required)
            .field("created_at", .datetime, .required, .sql(.default(SQLFunction("transaction_timestamp"))))
            .unique(on: "organization_id", "id")
            .unique(on: "organization_id", "resource_type", "resource_id", "revision")
            .tenantForeignKey("company_id", references: "companies")
            .tenantForeignKey("approval_request_id", references: "approval_requests")
            .create()
        let sql = try database.requireSQL()
        try await sql.raw("""
            ALTER TABLE business_events
            ADD CHECK (schema_version = 1 AND revision > 0 AND octet_length(payload) > 0
                AND payload_digest ~ '^[0-9a-f]{64}$'),
            ADD FOREIGN KEY (organization_id, resource_type, resource_id)
                REFERENCES business_event_streams (organization_id, resource_type, resource_id)
            """).run()
        try await sql.raw("CREATE INDEX business_events_history ON business_events (organization_id, created_at DESC, id)").run()
        try await database.createAppendOnlyTrigger(on: BusinessEvent.schema)
        try await database.createChangeTrigger(on: BusinessEvent.schema, redact: ["payload"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BusinessEvent.schema).delete()
        try await database.dropAppendOnlyTriggerFunction(on: BusinessEvent.schema)
    }
}
