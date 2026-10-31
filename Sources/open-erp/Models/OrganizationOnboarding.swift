import Fluent
import FluentSQL
import SQLKit
import Vapor

/// Organization locking always precedes the definitive invitation lookup.
/// NO KEY UPDATE still serializes onboarding writers, but unlike FOR UPDATE it does not block the
/// FOR KEY SHARE that foreign-key checks take, so tenant writes holding other row locks cannot deadlock with it.
func lockOrganization(_ id: UUID, on db: any Database) async throws -> Organization {
    guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
    let rows = try await sql.select().column("id").from(Organization.schema)
        .where("id", .equal, SQLBind(id)).lockingClause(SQLRaw("FOR NO KEY UPDATE")).all()
    guard !rows.isEmpty, let organization = try await Organization.find(id, on: db) else {
        throw Abort(.notFound)
    }
    return organization
}

/// Locks an active group so its deletion and new invitations into it serialize.
/// A waiting lock re-checks `deleted_at` after the other transaction commits, so a group deleted meanwhile is nil.
func lockGroup(_ id: UUID, organizationID: UUID, on db: any Database) async throws -> AccessGroup? {
    guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
    let rows = try await sql.select().column("id").from(AccessGroup.schema)
        .where("id", .equal, SQLBind(id))
        .where("organization_id", .equal, SQLBind(organizationID))
        .where("deleted_at", .is, SQLLiteral.null)
        .for(.update).all()
    guard !rows.isEmpty else { return nil }
    return try await AccessGroup.find(id, on: db)
}

extension OrganizationInvitation {
    /// The live onboarding invitation, else the newest revoked one.
    static func onboarding(organizationID: UUID, on db: any Database) async throws -> OrganizationInvitation? {
        try await query(on: db, organizationID: organizationID).withDeleted()
            .filter(\.$isOnboarding == true)
            .sort(.sql(unsafeRaw: "(deleted_at IS NULL) DESC"))
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .first()
    }

    /// Any accepted onboarding invitation, including revoked history.
    static func hasAcceptedOnboarding(organizationID: UUID, on db: any Database) async throws -> Bool {
        try await query(on: db, organizationID: organizationID).withDeleted()
            .filter(\.$isOnboarding == true)
            .filter(\.$acceptedAt != nil)
            .first() != nil
    }
}
