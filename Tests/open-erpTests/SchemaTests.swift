@testable import open_erp
import Fluent
import Foundation
import SQLKit
import Testing

extension OpenERPTests {
    @Test("Company role assignment insert without company_id is rejected")
    func companyRoleAssignmentRequiresCompany() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            let user = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "ada@example.com",
                subject: "ada",
                permissions: [.companyRead]
            )
            let membership = try #require(
                try await OrganizationUser.query(on: app.db, organizationID: orgID)
                    .filter(\.$user.$id == user.requireID())
                    .first()
            )
            let role = try #require(try await Role.query(on: app.db, organizationID: orgID).first())
            let sql = try #require(app.db as? any SQLDatabase)

            do {
                try await sql.raw(
                    """
                    INSERT INTO company_role_assignments (id, organization_user_id, role_id)
                    VALUES (\(bind: UUID()), \(bind: try membership.requireID()), \(bind: try role.requireID()))
                    """
                ).run()
                Issue.record("Expected the database to reject a company role assignment without company_id")
            } catch {
                let description = String(reflecting: error).lowercased()
                #expect(description.contains("company_id"))
            }
        }
    }
}
