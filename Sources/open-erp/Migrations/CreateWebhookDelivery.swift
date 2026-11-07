import Fluent
import FluentSQL
import SQLKit

struct CreateWebhookDelivery: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WebhookDelivery.schema)
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("event_id", .uuid, .required)
            .field("subscription_id", .uuid, .required)
            .field("revision_id", .uuid, .required)
            .field("state", .string, .required)
            .field("next_attempt_at", .datetime, .required)
            .field("first_attempt_at", .datetime)
            .field("lease_token", .uuid)
            .field("lease_expires_at", .datetime)
            .field("attempt_count", .int, .required)
            .field("cancellation_reason", .string)
            .field("created_at", .datetime, .required, .sql(.default(SQLFunction("transaction_timestamp"))))
            .tenantForeignKey("event_id", references: BusinessEvent.schema)
            .foreignKey(["organization_id", "subscription_id", "revision_id"],
                references: WebhookSubscriptionRevision.schema, ["organization_id", "subscription_id", "id"])
            .unique(on: "organization_id", "event_id", "subscription_id", name: "webhook_delivery_event_unique")
            .unique(on: "organization_id", "id", "revision_id", name: "webhook_delivery_revision_unique")
            .unique(on: "organization_id", "id", name: "webhook_delivery_tenant_unique")
            .create()
        let sql = try database.requireSQL()
        try await sql.raw("""
            ALTER TABLE webhook_deliveries
                ADD CHECK (state IN ('pending', 'in_flight', 'retrying', 'acknowledged', 'exhausted', 'cancelled')),
                ADD CHECK (attempt_count >= 0),
                ADD CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL)),
                ADD CHECK ((state = 'in_flight') = (lease_token IS NOT NULL)),
                ADD CHECK ((state = 'cancelled') = (cancellation_reason IS NOT NULL))
            """).run()
        try await sql.raw("CREATE INDEX webhook_deliveries_due ON webhook_deliveries (next_attempt_at, organization_id, subscription_id, id) WHERE state IN ('pending', 'retrying')").run()
        try await sql.raw("CREATE INDEX webhook_deliveries_leases ON webhook_deliveries (organization_id, subscription_id, lease_expires_at) WHERE state = 'in_flight'").run()
        try await sql.raw("CREATE INDEX webhook_deliveries_history ON webhook_deliveries (organization_id, created_at DESC, id)").run()
        try await database.createChangeTrigger(on: WebhookDelivery.schema, operations: [.insert, .delete])
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WebhookDelivery.schema).delete()
    }
}
