import Fluent
import FluentSQL
import SQLKit

struct CreateOrganizationRestoration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(OrganizationRestoration.schema)
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("deleted_at", .datetime, .required)
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("restored_by", .uuid, .required, .references("users", "id"))
            .field("reason", .string, .required)
            .field("created_at", .datetime, .required)
            .create()
        try await database.createAppendOnlyTrigger(on: OrganizationRestoration.schema)
        try await database.createChangeTrigger(on: OrganizationRestoration.schema)
    }

    func revert(on database: any Database) async throws {
        try await database.schema(OrganizationRestoration.schema).delete()
        try await database.dropAppendOnlyTriggerFunction(on: OrganizationRestoration.schema)
    }
}
