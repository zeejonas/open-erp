import Fluent
import FluentSQL
import SQLKit

struct CreateBusinessEventDispatch: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BusinessEventDispatch.schema)
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("event_id", .uuid, .required)
            .field("created_at", .datetime, .required, .sql(.default(SQLFunction("transaction_timestamp"))))
            .unique(on: "organization_id", "event_id")
            .tenantForeignKey("event_id", references: BusinessEvent.schema)
            .create()
        try await database.requireSQL().raw("CREATE INDEX business_event_dispatches_pending ON business_event_dispatches (created_at, id)").run()
        // Operational fan-out queue: intentionally no audit capture; the event is the evidence.
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BusinessEventDispatch.schema).delete()
    }
}
