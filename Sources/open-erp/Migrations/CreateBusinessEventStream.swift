import Fluent
import FluentSQL
import SQLKit

struct CreateBusinessEventStream: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Used only to order configuration and event capture within the same transaction.
        try await database.requireSQL().raw("CREATE SEQUENCE webhook_capture_order").run()
        try await database.requireSQL().raw("GRANT USAGE ON SEQUENCE webhook_capture_order TO open_erp_runtime").run()
        try await database.schema(BusinessEventStream.schema)
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("resource_type", .string, .required)
            .field("resource_id", .uuid, .required)
            .field("revision", .int64, .required)
            .unique(on: "organization_id", "resource_type", "resource_id")
            .create()
        try await database.requireSQL().raw("ALTER TABLE business_event_streams ADD CHECK (revision > 0)").run()
        try await database.createAppendOnlyTrigger(on: BusinessEventStream.schema, protected: ["id", "organization_id", "resource_type", "resource_id"])
        try await database.createChangeTrigger(on: BusinessEventStream.schema)
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BusinessEventStream.schema).delete()
        try await database.dropAppendOnlyTriggerFunction(on: BusinessEventStream.schema)
        try await database.requireSQL().raw("DROP SEQUENCE webhook_capture_order").run()
    }
}
