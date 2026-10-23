@testable import open_erp
import Fluent
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Permissions are granted only through an active group in the organization")
    func groupZeroTrust() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()

            _ = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "empty@example.com",
                subject: "empty",
                permissions: []
            )
            let emptyToken = try await signAccessToken(on: app, subject: "empty")
            try await expectCompanies(app, token: emptyToken, organizationID: orgAID, status: .forbidden)

            let noRoles = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "noroles@example.com",
                subject: "noroles",
                permissions: []
            )
            let noRolesMembership = try #require(try await OrganizationUser.query(on: app.db, organizationID: orgAID)
                .filter(\.$user.$id == noRoles.requireID())
                .first())
            let emptyGroup = AccessGroup(organizationID: orgAID, name: "Empty", createdByID: try noRoles.requireID())
            try await emptyGroup.save(on: app.db)
            try await GroupMember(
                groupID: try emptyGroup.requireID(),
                organizationUserID: try noRolesMembership.requireID(),
                createdByID: try noRoles.requireID()
            ).save(on: app.db)
            let noRolesToken = try await signAccessToken(on: app, subject: "noroles")
            try await expectCompanies(app, token: noRolesToken, organizationID: orgAID, status: .forbidden)

            let deletedGroupUser = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "deleted-group@example.com",
                subject: "deleted-group",
                permissions: [.companyRead]
            )
            let deletedGroupToken = try await signAccessToken(on: app, subject: "deleted-group")
            try await expectCompanies(app, token: deletedGroupToken, organizationID: orgAID, status: .ok)
            let deletedGroup = try #require(
                try await AccessGroup.query(on: app.db, organizationID: orgAID)
                    .filter(\.$name == "permissions-deleted-group@example.com")
                    .first()
            )
            try await deletedGroup.softDelete(by: try deletedGroupUser.requireID(), \.$deletedBy, on: app.db)
            try await expectCompanies(app, token: deletedGroupToken, organizationID: orgAID, status: .forbidden)

            let removedMember = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "removed-member@example.com",
                subject: "removed-member",
                permissions: [.companyRead]
            )
            let removedToken = try await signAccessToken(on: app, subject: "removed-member")
            let removedMembership = try #require(try await GroupMember.query(on: app.db)
                .join(OrganizationUser.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
                .filter(OrganizationUser.self, \.$user.$id == removedMember.requireID())
                .first())
            try await removedMembership.softDelete(by: try removedMember.requireID(), \.$deletedBy, on: app.db)
            try await expectCompanies(app, token: removedToken, organizationID: orgAID, status: .forbidden)

            let detachedUser = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "detached@example.com",
                subject: "detached",
                permissions: [.companyRead]
            )
            let detachedToken = try await signAccessToken(on: app, subject: "detached")
            let detachedRole = try #require(try await GroupRole.query(on: app.db)
                .join(AccessGroup.self, on: \GroupRole.$group.$id == \AccessGroup.$id)
                .filter(AccessGroup.self, \.$name == "permissions-detached@example.com")
                .first())
            try await detachedRole.softDelete(by: try detachedUser.requireID(), \.$deletedBy, on: app.db)
            try await expectCompanies(app, token: detachedToken, organizationID: orgAID, status: .forbidden)

            let crossOrg = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "cross@example.com",
                subject: "cross",
                permissions: [.companyRead]
            )
            try await OrganizationUser(
                organizationID: orgBID,
                userID: try crossOrg.requireID(),
                createdByID: try crossOrg.requireID()
            ).save(on: app.db)
            let crossToken = try await signAccessToken(on: app, subject: "cross")
            try await expectCompanies(app, token: crossToken, organizationID: orgAID, status: .ok)
            try await expectCompanies(app, token: crossToken, organizationID: orgBID, status: .forbidden)
        }
    }

    @Test("Groups can be created, renamed, and deleted within the organization")
    func groups() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()
            let admin = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "admin@example.com",
                subject: "admin",
                permissions: Permission.allCases
            )
            let clerk = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "clerk@example.com",
                subject: "clerk",
                permissions: []
            )
            _ = try await createMember(
                on: app.db,
                organizationID: orgBID,
                email: "other@example.com",
                subject: "other",
                permissions: Permission.allCases
            )
            let adminID = try admin.requireID()
            let adminToken = try await signAccessToken(on: app, subject: "admin")
            let otherToken = try await signAccessToken(on: app, subject: "other")

            var clerksID: UUID?
            try await app.testing().test(.POST, "groups", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateGroupDTO(name: "AP Clerks"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(GetGroupDTO.self)
                #expect(body.name == "AP Clerks")
                #expect(body.createdById == adminID)
                #expect(body.roleIds.isEmpty)
                #expect(body.companyIds.isEmpty)
                clerksID = body.id
            })
            try await app.testing().test(.POST, "groups", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateGroupDTO(name: "AP Clerks"))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            var payrollID: UUID?
            try await app.testing().test(.POST, "groups", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateGroupDTO(name: "Payroll"))
            }, afterResponse: { res async throws in
                payrollID = try res.content.decode(GetGroupDTO.self).id
            })
            try await app.testing().test(.PATCH, "groups/\(try #require(payrollID))", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(PatchGroupDTO(name: "AP Clerks"))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            try await app.testing().test(.POST, "groups/\(try #require(clerksID))/members", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(AddGroupMemberDTO(userId: try clerk.requireID()))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.DELETE, "groups/\(try #require(clerksID))", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            _ = try await OrganizationInvitation.issue(
                organizationID: orgAID,
                email: "pending@example.com",
                firstName: "Pen",
                lastName: "Ding",
                groupID: payrollID,
                createdByID: adminID,
                on: app.db
            )
            try await app.testing().test(.DELETE, "groups/\(try #require(payrollID))", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            try await app.testing().test(.GET, "groups/\(try #require(clerksID))", beforeRequest: { req in
                authorize(&req, token: otherToken, organizationID: orgBID)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
            try await app.testing().test(.PATCH, "groups/\(try #require(clerksID))", beforeRequest: { req in
                authorize(&req, token: otherToken, organizationID: orgBID)
                try req.content.encode(PatchGroupDTO(name: "Hijacked"))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
            try await app.testing().test(.DELETE, "groups/\(try #require(clerksID))", beforeRequest: { req in
                authorize(&req, token: otherToken, organizationID: orgBID)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
            let unchanged = try await AccessGroup.find(try #require(clerksID), on: app.db)
            #expect(unchanged?.name == "AP Clerks")

            try await app.testing().test(.DELETE, "groups/\(try #require(clerksID))/members/\(try clerk.requireID())", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            let spare = AccessGroup(organizationID: orgAID, name: "Spare", createdByID: adminID)
            try await spare.save(on: app.db)
            try await app.testing().test(.DELETE, "groups/\(try spare.requireID())", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            let deleted = try await AccessGroup.query(on: app.db).withDeleted().filter(\.$id == spare.requireID()).first()
            #expect(deleted?.deletedAt != nil)
            #expect(deleted?.$deletedBy.id == adminID)
            try await app.testing().test(.POST, "groups", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateGroupDTO(name: "Spare"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let orphanGroup = AccessGroup(organizationID: orgAID, name: "Orphan", createdByID: adminID)
            try await orphanGroup.save(on: app.db)
            let orphanMembership = try #require(try await OrganizationUser.query(on: app.db, organizationID: orgAID)
                .filter(\.$user.$id == clerk.requireID())
                .first())
            try await GroupMember(
                groupID: try orphanGroup.requireID(),
                organizationUserID: try orphanMembership.requireID(),
                createdByID: adminID
            ).save(on: app.db)
            try await orphanMembership.softDelete(by: adminID, \.$deletedBy, on: app.db)
            try await app.testing().test(.DELETE, "groups/\(try orphanGroup.requireID())", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
        }
    }

    @Test("Group membership is explicit and revocation is immediate")
    func groupMembership() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            let admin = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "admin@example.com",
                subject: "admin",
                permissions: Permission.allCases
            )
            let clerk = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "clerk@example.com",
                subject: "clerk",
                permissions: []
            )
            let outsider = try await createUser(on: app.db, email: "out@example.com", subject: "outsider")
            let adminID = try admin.requireID()
            let adminToken = try await signAccessToken(on: app, subject: "admin")
            let clerkToken = try await signAccessToken(on: app, subject: "clerk")
            let clerkID = try clerk.requireID()

            var groupID: UUID?
            try await app.testing().test(.POST, "groups", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
                try req.content.encode(CreateGroupDTO(name: "AP Clerks"))
            }, afterResponse: { res async throws in
                groupID = try res.content.decode(GetGroupDTO.self).id
            })
            let group = try #require(groupID)
            var roleID: UUID?
            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
                try req.content.encode(CreateRoleDTO(name: "Organization Viewer", level: "organization", permissions: ["company:read"]))
            }, afterResponse: { res async throws in
                roleID = try res.content.decode(GetRoleDTO.self).id
            })
            try await app.testing().test(.POST, "groups/\(group)/roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
                try req.content.encode(AddGroupRoleDTO(roleId: try #require(roleID)))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "groups/\(group)/members", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
                try req.content.encode(AddGroupMemberDTO(userId: try outsider.requireID()))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
            try await app.testing().test(.POST, "groups/\(group)/members", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
                try req.content.encode(AddGroupMemberDTO(userId: clerkID))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(GetGroupMemberDTO.self)
                #expect(body.userId == clerkID)
                #expect(body.createdById == adminID)
            })
            try await app.testing().test(.GET, "groups/\(group)/members", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let members = try res.content.decode(Page<GetGroupMemberDTO>.self)
                #expect(members.items.map(\.userId) == [clerkID])
            })
            try await app.testing().test(.POST, "groups/\(group)/members", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
                try req.content.encode(AddGroupMemberDTO(userId: clerkID))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })
            try await expectCompanies(app, token: clerkToken, organizationID: orgID, status: .ok)

            try await app.testing().test(.DELETE, "groups/\(group)/members/\(clerkID)", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            try await expectCompanies(app, token: clerkToken, organizationID: orgID, status: .forbidden)
            let history = try await GroupMember.query(on: app.db)
                .filter(\.$group.$id == group)
                .withDeleted()
                .all()
            #expect(history.count == 1)
            #expect(history.first?.$deletedBy.id == adminID)

            try await app.testing().test(.POST, "groups/\(group)/members", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
                try req.content.encode(AddGroupMemberDTO(userId: clerkID))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            let rewritten = try await GroupMember.query(on: app.db)
                .filter(\.$group.$id == group)
                .withDeleted()
                .all()
            #expect(rewritten.count == 2)
            #expect(rewritten.contains { $0.deletedAt == nil })
        }
    }

    @Test("Group roles and company eligibility")
    func groupRolesAndCompanies() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()
            let admin = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "admin@example.com",
                subject: "admin",
                permissions: Permission.allCases
            )
            let clerk = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "clerk@example.com",
                subject: "clerk",
                permissions: []
            )
            let adminID = try admin.requireID()
            let adminToken = try await signAccessToken(on: app, subject: "admin")
            let clerkToken = try await signAccessToken(on: app, subject: "clerk")

            var groupID: UUID?
            try await app.testing().test(.POST, "groups", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateGroupDTO(name: "AP Clerks"))
            }, afterResponse: { res async throws in
                groupID = try res.content.decode(GetGroupDTO.self).id
            })
            let group = try #require(groupID)
            try await app.testing().test(.POST, "groups/\(group)/members", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(AddGroupMemberDTO(userId: try clerk.requireID()))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await expectCompanies(app, token: clerkToken, organizationID: orgAID, status: .forbidden)

            var viewerRoleID: UUID?
            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateRoleDTO(name: "Organization Viewer", level: "organization", permissions: ["company:read"]))
            }, afterResponse: { res async throws in
                viewerRoleID = try res.content.decode(GetRoleDTO.self).id
            })
            let viewerRole = try #require(viewerRoleID)
            try await app.testing().test(.POST, "groups/\(group)/roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(AddGroupRoleDTO(roleId: viewerRole))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(GetGroupRoleDTO.self).createdById == adminID)
            })
            try await expectCompanies(app, token: clerkToken, organizationID: orgAID, status: .ok)

            var companyRoleID: UUID?
            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateRoleDTO(name: "Plant", level: "company", permissions: []))
            }, afterResponse: { res async throws in
                companyRoleID = try res.content.decode(GetRoleDTO.self).id
            })
            try await app.testing().test(.POST, "groups/\(group)/roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(AddGroupRoleDTO(roleId: try #require(companyRoleID)))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.GET, "groups/\(group)", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async throws in
                let body = try res.content.decode(GetGroupDTO.self)
                #expect(Set(body.roleIds) == [viewerRole, try #require(companyRoleID)])
            })

            let foreignRole = Role(organizationID: orgBID, name: "Foreign", level: .organization, createdByID: nil)
            try await foreignRole.save(on: app.db)
            let linksBefore = try await GroupRole.query(on: app.db).filter(\.$group.$id == group).count()
            try await app.testing().test(.POST, "groups/\(group)/roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(AddGroupRoleDTO(roleId: try foreignRole.requireID()))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
            #expect(try await GroupRole.query(on: app.db).filter(\.$group.$id == group).count() == linksBefore)
            try await app.testing().test(.POST, "groups/\(group)/roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(AddGroupRoleDTO(roleId: viewerRole))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            var companyID: UUID?
            try await app.testing().test(.POST, "companies", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateCompanyDTO(code: "EAST", name: "Acme East"))
            }, afterResponse: { res async throws in
                companyID = try res.content.decode(GetCompanyDTO.self).id
            })
            let company = try #require(companyID)
            #expect(try await GroupCompany.query(on: app.db).filter(\.$company.$id == company).count() == 0)
            try await app.testing().test(.POST, "groups/\(group)/companies", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(AddGroupCompanyDTO(companyId: company))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(GetGroupCompanyDTO.self).createdById == adminID)
            })
            try await app.testing().test(.GET, "groups", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async throws in
                let listed = try res.content.decode(Page<GetGroupDTO>.self)
                let clerks = try #require(listed.items.first { $0.name == "AP Clerks" })
                #expect(clerks.companyIds == [company])
            })
            try await app.testing().test(.POST, "groups/\(group)/companies", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(AddGroupCompanyDTO(companyId: company))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            let foreignCompany = Company(
                code: "WEST",
                name: "Acme West",
                organizationID: orgBID,
                createdBy: nil,
                updatedBy: nil,
                deletedBy: nil
            )
            try await foreignCompany.save(on: app.db)
            let eligibilityBefore = try await GroupCompany.query(on: app.db).filter(\.$group.$id == group).count()
            try await app.testing().test(.POST, "groups/\(group)/companies", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(AddGroupCompanyDTO(companyId: try foreignCompany.requireID()))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
            let deletedCompany = Company(
                code: "GONE",
                name: "Gone",
                organizationID: orgAID,
                createdBy: admin,
                updatedBy: nil,
                deletedBy: nil
            )
            try await deletedCompany.save(on: app.db)
            try await deletedCompany.softDelete(by: adminID, \.$deletedBy, on: app.db)
            try await app.testing().test(.POST, "groups/\(group)/companies", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(AddGroupCompanyDTO(companyId: try deletedCompany.requireID()))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
            #expect(try await GroupCompany.query(on: app.db).filter(\.$group.$id == group).count() == eligibilityBefore)

            try await app.testing().test(.DELETE, "groups/\(group)/companies/\(company)", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            try await expectCompanies(app, token: clerkToken, organizationID: orgAID, status: .ok)
            let removedEligibility = try await GroupCompany.query(on: app.db)
                .filter(\.$group.$id == group)
                .withDeleted()
                .first()
            #expect(removedEligibility?.$deletedBy.id == adminID)

            try await app.testing().test(.DELETE, "groups/\(group)/roles/\(viewerRole)", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            try await expectCompanies(app, token: clerkToken, organizationID: orgAID, status: .forbidden)
            let detached = try await GroupRole.query(on: app.db)
                .filter(\.$group.$id == group)
                .filter(\.$role.$id == viewerRole)
                .withDeleted()
                .first()
            #expect(detached?.$deletedBy.id == adminID)
        }
    }
}

private func expectCompanies(
    _ app: Application,
    token: String,
    organizationID: UUID,
    status: HTTPStatus
) async throws {
    try await app.testing().test(.GET, "companies", beforeRequest: { req in
        authorize(&req, token: token, organizationID: organizationID)
    }, afterResponse: { res async in
        #expect(res.status == status)
    })
}
