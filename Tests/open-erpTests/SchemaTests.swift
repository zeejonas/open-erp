@testable import open_erp
import Fluent
import Foundation
import Testing

extension OpenERPTests {
    @Test("A tenant-owned row without an existing organization is rejected")
    func orphanTenantRowIsRejected() async throws {
        try await withApp { app in
            let user = try await createUser(on: app.db, email: "ada@example.com", subject: "ada")
            do {
                try await AccessGroup(organizationID: UUID(), name: "Orphan", createdByID: try user.requireID())
                    .save(on: app.db)
                Issue.record("Expected a group without an existing organization to be rejected")
            } catch {
                let description = String(reflecting: error).lowercased()
                #expect(description.contains("foreign key") || description.contains("23503"))
            }
        }
    }

    @Test("Duplicate active rows in each group table are rejected")
    func groupTablesRejectDuplicateActiveRows() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let user = try await createUser(on: app.db, email: "ada@example.com", subject: "ada")
            let userID = try user.requireID()
            let membership = OrganizationUser(organizationID: orgAID, userID: userID, createdByID: userID)
            try await membership.save(on: app.db)
            let membershipID = try membership.requireID()
            let role = Role(organizationID: orgAID, name: "Auditor", level: .organization, createdByID: userID)
            try await role.save(on: app.db)
            let roleID = try role.requireID()
            let company = Company(
                code: "EAST",
                name: "Acme East",
                organizationID: orgAID,
                createdBy: user,
                updatedBy: nil,
                deletedBy: nil
            )
            try await company.save(on: app.db)
            let companyID = try company.requireID()

            let group = AccessGroup(organizationID: orgAID, name: "AP Clerks", createdByID: userID)
            try await group.save(on: app.db)
            try await expectUniqueViolation {
                try await AccessGroup(organizationID: orgAID, name: "AP Clerks", createdByID: userID).save(on: app.db)
            }
            try await AccessGroup(organizationID: try orgB.requireID(), name: "AP Clerks", createdByID: userID).save(on: app.db)
            try await group.softDelete(by: userID, \.$deletedBy, on: app.db)
            let reused = AccessGroup(organizationID: orgAID, name: "AP Clerks", createdByID: userID)
            try await reused.save(on: app.db)
            let groupID = try reused.requireID()

            let member = GroupMember(groupID: groupID, organizationUserID: membershipID, createdByID: userID)
            try await member.save(on: app.db)
            try await expectUniqueViolation {
                try await GroupMember(groupID: groupID, organizationUserID: membershipID, createdByID: userID).save(on: app.db)
            }
            try await member.softDelete(by: userID, \.$deletedBy, on: app.db)
            try await GroupMember(groupID: groupID, organizationUserID: membershipID, createdByID: userID).save(on: app.db)

            let groupRole = GroupRole(groupID: groupID, roleID: roleID, createdByID: userID)
            try await groupRole.save(on: app.db)
            try await expectUniqueViolation {
                try await GroupRole(groupID: groupID, roleID: roleID, createdByID: userID).save(on: app.db)
            }
            try await groupRole.softDelete(by: userID, \.$deletedBy, on: app.db)
            try await GroupRole(groupID: groupID, roleID: roleID, createdByID: userID).save(on: app.db)

            let eligibility = GroupCompany(groupID: groupID, companyID: companyID, createdByID: userID)
            try await eligibility.save(on: app.db)
            try await expectUniqueViolation {
                try await GroupCompany(groupID: groupID, companyID: companyID, createdByID: userID).save(on: app.db)
            }
            try await eligibility.softDelete(by: userID, \.$deletedBy, on: app.db)
            try await GroupCompany(groupID: groupID, companyID: companyID, createdByID: userID).save(on: app.db)
        }
    }

    @Test("A soft-deleted membership can be replaced and a second active one is rejected")
    func removedOrganizationMembershipCanBeReplaced() async throws {
        try await withApp { app in
            let organization = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let organizationID = try organization.requireID()
            let user = try await createUser(on: app.db, email: "ada@example.com", subject: "ada")
            let userID = try user.requireID()

            let removed = OrganizationUser(organizationID: organizationID, userID: userID, createdByID: userID)
            try await removed.save(on: app.db)
            let removedID = try removed.requireID()
            try await removed.softDelete(by: userID, \.$deletedBy, on: app.db)

            try await OrganizationUser(organizationID: organizationID, userID: userID, createdByID: userID).save(on: app.db)
            let history = try await OrganizationUser.query(on: app.db)
                .withDeleted()
                .filter(\.$id == removedID)
                .first()
            #expect(history?.$deletedBy.id == userID)

            try await expectUniqueViolation {
                try await OrganizationUser(organizationID: organizationID, userID: userID, createdByID: userID)
                    .save(on: app.db)
            }
        }
    }
}

private func expectUniqueViolation(_ body: () async throws -> Void) async throws {
    do {
        try await body()
        Issue.record("Expected a duplicate active row to be rejected")
    } catch {
        let description = String(reflecting: error).lowercased()
        #expect(description.contains("unique") || description.contains("23505"))
    }
}
