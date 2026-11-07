import Fluent
import FluentSQL
import SQLKit

struct CreateWebhookSecretReveal: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WebhookSecretReveal.schema)
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("subscription_id", .uuid, .required)
            .field("revision_id", .uuid, .required)
            .field("secret_id", .uuid, .required)
            .field("actor_id", .uuid, .required, .references("users", "id"))
            .field("request_id", .string, .required)
            .field("created_at", .datetime, .required, .sql(.default(SQLFunction("transaction_timestamp"))))
            .foreignKey(["organization_id", "subscription_id", "revision_id", "secret_id"],
                references: WebhookSubscriptionRevision.schema, ["organization_id", "subscription_id", "id", "secret_id"])
            .create()
        try await database.createAppendOnlyTrigger(on: WebhookSecretReveal.schema)
        try await database.createChangeTrigger(on: WebhookSecretReveal.schema)
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WebhookSecretReveal.schema).delete()
        try await database.dropAppendOnlyTriggerFunction(on: WebhookSecretReveal.schema)
    }
}
