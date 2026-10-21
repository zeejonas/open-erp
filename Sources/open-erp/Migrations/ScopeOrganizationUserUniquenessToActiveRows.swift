import Fluent

/// A re-invited member gets a new membership row, so the removed row keeps its `deleted_by`
/// and its revoked role assignments stay revoked.
struct ScopeOrganizationUserUniquenessToActiveRows: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("organization_users")
            .deleteUnique(on: "organization_id", "user_id")
            .update()
        try await database.createActiveUniqueIndex(
            "organization_users_active_member",
            on: "organization_users",
            columns: "organization_id", "user_id"
        )
    }

    /// Removed memberships kept as history violate the original full-table constraint,
    /// and restoring it would mean deleting audit records, so revert only drops the index.
    func revert(on database: any Database) async throws {
        try await database.dropIndex("organization_users_active_member")
    }
}
