import Fluent
import FluentSQL
import SQLKit

struct CreateWebhookSubscriptionRevision: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WebhookSubscriptionRevision.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("subscription_id", .uuid, .required)
            .field("name", .string, .required)
            .field("url", .string, .required)
            .field("event_types", .array(of: .string), .required)
            .field("company_ids", .array(of: .uuid), .required)
            .field("enabled", .bool, .required)
            .field("schema_version", .int, .required)
            .field("version", .int, .required)
            .field("transaction_id", .int64, .required, .sql(.default(SQLFunction("txid_current"))))
            .field("capture_order", .int64, .required, .sql(.default(SQLRaw("nextval('webhook_capture_order')"))))
            .field("secret_id", .uuid, .required)
            .field("secret_ciphertext", .data, .required)
            .field("created_by", .uuid, .references("users", "id"))
            .field("approval_request_id", .uuid)
            .field("created_at", .datetime, .required, .sql(.default(SQLFunction("transaction_timestamp"))))
            .tenantForeignKey("subscription_id", references: WebhookSubscription.schema)
            .tenantForeignKey("approval_request_id", references: "approval_requests")
            .unique(on: "organization_id", "id", name: "webhook_revision_tenant_unique")
            .unique(on: "subscription_id", "version", name: "webhook_revision_version_unique")
            .unique(on: "organization_id", "subscription_id", "id", name: "webhook_revision_subscription_unique")
            .unique(on: "organization_id", "subscription_id", "id", "secret_id", name: "webhook_revision_secret_unique")
            .create()
        let sql = try database.requireSQL()
        try await sql.raw("""
            ALTER TABLE webhook_subscription_revisions
                ADD CHECK (schema_version = 1 AND version > 0 AND char_length(name) BETWEEN 1 AND 100
                    AND cardinality(event_types) > 0 AND octet_length(secret_ciphertext) > 0);
            """).run()
        try await sql.raw("""
            ALTER TABLE webhook_subscriptions ADD CONSTRAINT webhook_current_revision_fk
                FOREIGN KEY (organization_id, id, current_revision_id)
                REFERENCES webhook_subscription_revisions (organization_id, subscription_id, id)
                DEFERRABLE INITIALLY DEFERRED
            """).run()
        try await sql.raw("CREATE INDEX webhook_revisions_at_event ON webhook_subscription_revisions (organization_id, subscription_id, created_at DESC, id)").run()
        try await database.createAppendOnlyTrigger(on: WebhookSubscriptionRevision.schema)
        try await database.createChangeTrigger(on: WebhookSubscriptionRevision.schema, redact: ["secret_ciphertext"])
    }

    func revert(on database: any Database) async throws {
        try await database.requireSQL().raw("ALTER TABLE webhook_subscriptions DROP CONSTRAINT webhook_current_revision_fk").run()
        try await database.schema(WebhookSubscriptionRevision.schema).delete()
        try await database.dropAppendOnlyTriggerFunction(on: WebhookSubscriptionRevision.schema)
    }
}
