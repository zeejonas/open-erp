import Fluent
import FluentSQL
import SQLKit

struct CreateOrganizationInvitation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("organization_invitations")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("email", .string, .required)
            .field("first_name", .string, .required)
            .field("last_name", .string, .required)
            .field("role_id", .uuid, .references("roles", "id"))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("accepted_at", .datetime)
            .field("accepted_by", .uuid, .references("users", "id"))
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("organization_invitations").delete()
    }
}
