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

    @Test("Duplicate active approval rows and version numbers are rejected")
    func approvalTablesRejectDuplicates() async throws {
        try await withApp { app in
            let organization = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let organizationID = try organization.requireID()
            let other = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let user = try await createUser(on: app.db, email: "ada@example.com", subject: "ada")
            let userID = try user.requireID()
            let group = AccessGroup(organizationID: organizationID, name: "Security", createdByID: userID)
            try await group.save(on: app.db)
            let groupID = try group.requireID()
            let definition = ApprovalPolicyDefinition(
                name: "Role changes",
                permission: Permission.roleUpdate.rawValue,
                fields: ["permissions"],
                companyId: nil,
                stages: [ApprovalStageDTO(slots: [ApprovalSlotDTO(groupId: groupID, required: 1)])]
            )

            let policy = ApprovalPolicy(
                organizationID: organizationID,
                name: "Role changes",
                permission: Permission.roleUpdate.rawValue,
                fields: ["permissions"],
                companyID: nil,
                currentVersion: 1,
                createdByID: userID
            )
            try await policy.save(on: app.db)
            let policyID = try policy.requireID()
            try await expectUniqueViolation {
                try await ApprovalPolicy(
                    organizationID: organizationID,
                    name: "Role changes",
                    permission: Permission.roleUpdate.rawValue,
                    fields: [],
                    companyID: nil,
                    currentVersion: 1,
                    createdByID: userID
                ).save(on: app.db)
            }
            try await ApprovalPolicy(
                organizationID: try other.requireID(),
                name: "Role changes",
                permission: Permission.roleUpdate.rawValue,
                fields: [],
                companyID: nil,
                currentVersion: 1,
                createdByID: userID
            ).save(on: app.db)
            try await policy.softDelete(by: userID, \.$deletedBy, on: app.db)
            let reused = ApprovalPolicy(
                organizationID: organizationID,
                name: "Role changes",
                permission: Permission.roleUpdate.rawValue,
                fields: ["permissions"],
                companyID: nil,
                currentVersion: 1,
                createdByID: userID
            )
            try await reused.save(on: app.db)
            let reusedID = try reused.requireID()

            let slot = ApprovalPolicySlot(policyID: reusedID, stage: 1, groupID: groupID, required: 1, createdByID: userID)
            try await slot.save(on: app.db)
            try await expectUniqueViolation {
                try await ApprovalPolicySlot(policyID: reusedID, stage: 1, groupID: groupID, required: 2, createdByID: userID)
                    .save(on: app.db)
            }
            try await slot.softDelete(by: userID, \.$deletedBy, on: app.db)
            try await ApprovalPolicySlot(policyID: reusedID, stage: 1, groupID: groupID, required: 1, createdByID: userID)
                .save(on: app.db)

            try await ApprovalPolicyVersion(policyID: policyID, version: 1, definition: definition, createdByID: userID)
                .save(on: app.db)
            try await expectUniqueViolation {
                try await ApprovalPolicyVersion(policyID: policyID, version: 1, definition: definition, createdByID: userID)
                    .save(on: app.db)
            }
        }
    }

    @Test("Approval evidence triggers reject rewrites and allow a status change")
    func approvalEvidenceIsAppendOnly() async throws {
        try await withApp { app in
            let organization = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let organizationID = try organization.requireID()
            let user = try await createUser(on: app.db, email: "ada@example.com", subject: "ada")
            let userID = try user.requireID()
            let group = AccessGroup(organizationID: organizationID, name: "Security", createdByID: userID)
            try await group.save(on: app.db)
            let definition = ApprovalPolicyDefinition(
                name: "Role changes",
                permission: Permission.roleUpdate.rawValue,
                fields: ["permissions"],
                companyId: nil,
                stages: [ApprovalStageDTO(slots: [ApprovalSlotDTO(groupId: try group.requireID(), required: 1)])]
            )
            let policy = ApprovalPolicy(
                organizationID: organizationID,
                name: "Role changes",
                permission: Permission.roleUpdate.rawValue,
                fields: ["permissions"],
                companyID: nil,
                currentVersion: 1,
                createdByID: userID
            )
            try await policy.save(on: app.db)
            let version = ApprovalPolicyVersion(
                policyID: try policy.requireID(),
                version: 1,
                definition: definition,
                createdByID: userID
            )
            try await version.save(on: app.db)
            let versionID = try version.requireID()

            let change = ProposedChange.companyCreate(CodeNameSnapshot(code: "EAST", name: "East"))
            let request = ApprovalRequest(
                organizationID: organizationID,
                permission: change.permission.rawValue,
                targetID: nil,
                change: change,
                status: ApprovalRequestStatus.pending.rawValue,
                requestedByID: userID
            )
            try await request.save(on: app.db)
            let requestID = try request.requireID()
            let decision = ApprovalDecision(
                requestID: requestID,
                trackID: nil,
                stage: nil,
                kind: ApprovalDecisionKind.approve.rawValue,
                decidedByID: userID,
                operatorName: nil,
                qualifyingGroupIDs: [],
                comment: "ok"
            )
            try await decision.save(on: app.db)

            try await expectDatabaseRejection {
                decision.comment = "changed"
                try await decision.update(on: app.db)
            }
            let unchangedDecision = try await ApprovalDecision.find(try decision.requireID(), on: app.db)
            #expect(unchangedDecision?.comment == "ok")
            try await expectDatabaseRejection {
                try await decision.delete(force: true, on: app.db)
            }

            try await expectDatabaseRejection {
                version.version = 2
                try await version.update(on: app.db)
            }
            let unchangedVersion = try await ApprovalPolicyVersion.find(versionID, on: app.db)
            #expect(unchangedVersion?.version == 1)
            try await expectDatabaseRejection {
                try await version.delete(force: true, on: app.db)
            }

            request.change = .companyCreate(CodeNameSnapshot(code: "WEST", name: "West"))
            try await expectDatabaseRejection {
                try await request.update(on: app.db)
            }
            let stored = try await ApprovalRequest.find(requestID, on: app.db)
            #expect(stored?.change == change)
            request.change = change
            request.$requestedBy.id = UUID()
            try await expectDatabaseRejection {
                try await request.update(on: app.db)
            }
            try await expectDatabaseRejection {
                try await request.delete(force: true, on: app.db)
            }

            let track = ApprovalRequestTrack(
                requestID: requestID,
                policyVersionID: versionID,
                currentStage: 1,
                status: ApprovalTrackStatus.pending.rawValue
            )
            try await track.save(on: app.db)
            track.$policyVersion.id = UUID()
            try await expectDatabaseRejection {
                try await track.update(on: app.db)
            }
            try await expectDatabaseRejection {
                try await track.delete(force: true, on: app.db)
            }
            let advancing = try #require(try await ApprovalRequestTrack.find(try track.requireID(), on: app.db))
            #expect(advancing.$policyVersion.id == versionID)
            advancing.status = ApprovalTrackStatus.approved.rawValue
            try await advancing.update(on: app.db)

            let reloaded = try #require(try await ApprovalRequest.find(requestID, on: app.db))
            reloaded.status = ApprovalRequestStatus.applied.rawValue
            try await reloaded.update(on: app.db)
            let applied = try await ApprovalRequest.find(requestID, on: app.db)
            #expect(applied?.status == ApprovalRequestStatus.applied.rawValue)
            #expect(applied?.change == change)
        }
    }
}

private func expectDatabaseRejection(_ body: () async throws -> Void) async throws {
    do {
        try await body()
        Issue.record("Expected the database to reject the write")
    } catch {
        let description = String(reflecting: error).lowercased()
        #expect(
            description.contains("append-only") || description.contains("cannot be deleted") || description.contains("p0001")
        )
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
