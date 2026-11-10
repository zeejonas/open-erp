import Fluent
import FluentSQL
import SQLKit

/// Shares its primary key with the service account's `users` row.
struct CreateServiceAccount: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ServiceAccount.schema)
            .field("id", .uuid, .identifier(auto: false), .references("users", "id"))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("owner_id", .uuid, .required, .references("users", "id"))
            .field("description", .string)
            .field("disabled_at", .datetime)
            .field("disabled_by", .uuid, .references("users", "id"))
            .field("last_used_at", .datetime)
            .field("created_by", .uuid, .references("users", "id"))
            .field("updated_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .create()
        try await database.requireSQL().raw("""
            CREATE INDEX service_accounts_organization ON service_accounts (organization_id, created_at DESC, id) WHERE deleted_at IS NULL
            """).run()
        try await database.createChangeTrigger(on: ServiceAccount.schema)
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ServiceAccount.schema).delete()
    }
}
