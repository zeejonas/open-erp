import Fluent
import SQLKit
import Vapor

/// Organization locking always precedes the definitive invitation lookup.
func lockOrganization(_ id: UUID, on db: any Database) async throws -> Organization {
    guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
    let rows = try await sql.select().column("id").from(Organization.schema)
        .where("id", .equal, SQLBind(id)).for(.update).all()
    guard !rows.isEmpty, let organization = try await Organization.find(id, on: db) else {
        throw Abort(.notFound)
    }
    return organization
}

extension OrganizationInvitation {
    static func onboarding(organizationID: UUID, on db: any Database) async throws -> OrganizationInvitation? {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        let row = try await sql.raw("""
            SELECT id FROM organization_invitations
            WHERE organization_id = \(bind: organizationID) AND is_onboarding
            ORDER BY (deleted_at IS NULL) DESC, created_at DESC, id DESC LIMIT 1
            """).first()
        guard let row else { return nil }
        let id = try row.decode(column: "id", as: UUID.self)
        return try await query(on: db).withDeleted().filter(\.$id == id).first()
    }
}
