import Fluent
import FluentSQL
import SQLKit

struct CreateWebhookDeliveryEntry: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WebhookDeliveryEntry.schema)
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("delivery_id", .uuid, .required)
            .field("revision_id", .uuid, .required)
            .field("kind", .string, .required)
            .field("attempt_id", .uuid)
            .field("secret_id", .uuid)
            .field("payload_digest", .string, .required)
            .field("started_at", .datetime)
            .field("finished_at", .datetime)
            .field("http_status", .int)
            .field("outcome", .string)
            .field("reason", .string)
            .field("next_attempt_at", .datetime)
            .field("created_at", .datetime, .required, .sql(.default(SQLFunction("transaction_timestamp"))))
            .foreignKey(["organization_id", "delivery_id", "revision_id"],
                references: WebhookDelivery.schema, ["organization_id", "id", "revision_id"])
            .create()
        let sql = try database.requireSQL()
        try await sql.raw("""
            ALTER TABLE webhook_delivery_entries
                ADD CHECK (payload_digest ~ '^[0-9a-f]{64}$'),
                ADD CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599),
                ADD CHECK (
                    (kind = 'cancellation' AND attempt_id IS NULL AND outcome IS NULL AND reason IS NOT NULL)
                    OR (kind = 'started' AND attempt_id IS NOT NULL AND secret_id IS NOT NULL
                        AND started_at IS NOT NULL AND finished_at IS NULL AND outcome = 'started')
                    OR (kind = 'result' AND attempt_id IS NOT NULL AND secret_id IS NOT NULL
                        AND started_at IS NOT NULL AND finished_at IS NOT NULL AND finished_at >= started_at
                        AND outcome IN ('acknowledged', 'retryable', 'exhausted', 'unknown')))
            """).run()
        try await sql.raw("CREATE UNIQUE INDEX webhook_attempt_entry_unique ON webhook_delivery_entries (organization_id, attempt_id, kind) WHERE attempt_id IS NOT NULL").run()
        try await sql.raw("CREATE UNIQUE INDEX webhook_cancellation_unique ON webhook_delivery_entries (organization_id, delivery_id) WHERE kind = 'cancellation'").run()
        try await sql.raw("CREATE INDEX webhook_attempt_history ON webhook_delivery_entries (organization_id, delivery_id, created_at DESC, id)").run()
        try await database.createAppendOnlyTrigger(on: WebhookDeliveryEntry.schema)
        try await database.createChangeTrigger(on: WebhookDeliveryEntry.schema)
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WebhookDeliveryEntry.schema).delete()
        try await database.dropAppendOnlyTriggerFunction(on: WebhookDeliveryEntry.schema)
    }
}
