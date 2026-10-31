import Fluent
import FluentSQL
import SQLKit
import Vapor

struct CreateOrganizationInvitation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("organization_invitations")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("email", .string, .required)
            .field("first_name", .string, .required)
            .field("last_name", .string, .required)
            .field("is_onboarding", .bool, .required, .sql(.default(SQLLiteral.boolean(false))))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("accepted_at", .datetime)
            .field("accepted_by", .uuid, .references("users", "id"))
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .field("group_id", .uuid, .references("groups", "id"))
            .field("approval_request_id", .uuid, .references("approval_requests", "id"))
            .unique(on: "token_hash")
            .create()
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("""
            CREATE UNIQUE INDEX organization_invitations_current_onboarding
            ON organization_invitations (organization_id)
            WHERE deleted_at IS NULL AND is_onboarding
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("organization_invitations").delete()
    }
}
