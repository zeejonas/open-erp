import Fluent
import FluentSQL
import SQLKit

struct CreateGroupMember: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("group_members")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("group_id", .uuid, .required)
            .field("organization_user_id", .uuid, .required)
            .field("created_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .tenantForeignKey("group_id", references: "groups")
            .tenantForeignKey("organization_user_id", references: "organization_users")
            .create()
        try await database.createActiveUniqueIndex(
            "group_members_active_member",
            on: "group_members",
            columns: "group_id", "organization_user_id"
        )
        try await database.createChangeTrigger(on: "group_members")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("group_members").delete()
    }
}
