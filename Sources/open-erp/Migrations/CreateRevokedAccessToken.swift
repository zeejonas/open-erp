import Fluent

struct CreateRevokedAccessToken: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(RevokedAccessToken.schema)
            .field("fingerprint", .string, .identifier(auto: false))
            .field("issuer", .string, .required)
            .field("subject", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("revoked_at", .datetime, .required)
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(RevokedAccessToken.schema).delete()
    }
}
