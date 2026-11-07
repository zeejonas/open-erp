import Fluent
import FluentSQL
import SQLKit

struct CreateWebhookSubscription: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WebhookSubscription.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("current_revision_id", .uuid, .required)
            .field("disabled_reason", .string)
            .field("disabled_by", .uuid, .references("users", "id"))
            .field("disabled_actor_type", .string)
            .field("disabled_actor_name", .string)
            .field("disabled_at", .datetime)
            .field("failing_since", .datetime)
            .field("created_by", .uuid, .references("users", "id"))
            .field("updated_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime, .required, .sql(.default(SQLFunction("transaction_timestamp"))))
            .field("updated_at", .datetime, .required, .sql(.default(SQLFunction("transaction_timestamp"))))
            .field("deleted_at", .datetime)
            .unique(on: "organization_id", "id")
            .create()
        try await database.requireSQL().raw("""
            ALTER TABLE webhook_subscriptions ADD CHECK (disabled_reason IN ('emergency', 'auto_paused')),
                ADD CHECK ((disabled_reason IS NULL) = (disabled_at IS NULL))
            """).run()
        try await database.requireSQL().raw("CREATE INDEX webhook_subscriptions_history ON webhook_subscriptions (organization_id, updated_at DESC, id) WHERE deleted_at IS NULL").run()
        try await database.createChangeTrigger(on: WebhookSubscription.schema)
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WebhookSubscription.schema).delete()
    }
}
