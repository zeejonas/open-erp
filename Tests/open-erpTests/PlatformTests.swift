@testable import open_erp
import Fluent
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Platform provisioning copies templates and does not grant tenant access")
    func platformProvisioning() async throws {
        try await withApp { app in
            let admin = try await createUser(
                on: app.db,
                firstName: "Ops",
                lastName: "Admin",
                email: "ops@example.com",
                subject: "ops",
                isPlatformAdmin: true
            )
            let stranger = try await createUser(on: app.db, email: "stranger@example.com", subject: "stranger")
            let adminToken = try await signAccessToken(on: app, subject: "ops")
            let strangerToken = try await signAccessToken(on: app, subject: "stranger")

            try await app.testing().test(.POST, "platform/organizations", beforeRequest: { req in
                authorize(&req, token: strangerToken)
                try req.content.encode(ProvisionOrganizationDTO(
                    code: "ACME",
                    name: "Acme LLC",
                    adminEmail: "cfo@acme.com",
                    adminFirstName: "Cara",
                    adminLastName: "Finance"
                ))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
            #expect(try await Organization.query(on: app.db).count() == 0)

            var organizationID: UUID?
            var token = ""
            try await app.testing().test(.POST, "platform/organizations", beforeRequest: { req in
                authorize(&req, token: adminToken)
                try req.content.encode(ProvisionOrganizationDTO(
                    code: "ACME",
                    name: "Acme LLC",
                    adminEmail: "cfo@acme.com",
                    adminFirstName: "Cara",
                    adminLastName: "Finance"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(ProvisionOrganizationResponse.self)
                let adminID = try admin.requireID()
                #expect(body.organization.name == "Acme LLC")
                #expect(body.organization.createdById == adminID)
                organizationID = body.organization.id
                token = body.invitationToken
            })

            let orgID = try #require(organizationID)
            let roles = try await Role.query(on: app.db, organizationID: orgID).with(\.$permissionGrants).all()
            let adminRole = try #require(roles.first { $0.templateKey == "org_admin" })
            let viewerRole = try #require(roles.first { $0.templateKey == "org_viewer" })
            #expect(adminRole.name == "Organization Administrator")
            let adminPermissions = Set(adminRole.permissionGrants.map(\.permission))
            #expect(adminPermissions == Set(Permission.allCases.map(\.rawValue)))
            #expect(adminPermissions.contains(Permission.approvalOverrideCreate.rawValue))
            #expect(viewerRole.name == "Organization Viewer")
            let viewerPermissions = Set(viewerRole.permissionGrants.map(\.permission))
            #expect(viewerPermissions == Set(Permission.allCases.filter(\.isRead).map(\.rawValue)))
            #expect(viewerPermissions.isSuperset(of: [
                Permission.approvalPolicyRead.rawValue,
                Permission.approvalRequestRead.rawValue,
            ]))
            #expect(!viewerPermissions.contains(Permission.approvalOverrideCreate.rawValue))

            let groups = try await AccessGroup.query(on: app.db, organizationID: orgID)
                .with(\.$roles)
                .with(\.$companies)
                .all()
            let adminGroup = try #require(groups.first { $0.templateKey == GroupTemplate.organizationAdministrators.key })
            let viewerGroup = try #require(groups.first { $0.templateKey == GroupTemplate.organizationViewers.key })
            #expect(adminGroup.name == "Organization Administrators")
            #expect(Set(adminGroup.roles.map { $0.$role.id }) == [try adminRole.requireID()])
            #expect(viewerGroup.name == "Organization Viewers")
            #expect(Set(viewerGroup.roles.map { $0.$role.id }) == [try viewerRole.requireID()])
            #expect(groups.allSatisfy { $0.companies.isEmpty })
            #expect(try await GroupMember.query(on: app.db).count() == 0)

            let invitation = try await OrganizationInvitation.query(on: app.db)
                .filter(\.$tokenHash == InvitationToken.hash(token))
                .first()
            #expect(invitation?.email == "cfo@acme.com")
            #expect(invitation?.$group.id == adminGroup.id)

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            _ = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "ops-member@example.com",
                subject: "ops-member",
                permissions: [],
                isPlatformAdmin: true
            )
            let memberToken = try await signAccessToken(on: app, subject: "ops-member")
            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: memberToken, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            stubUserInfo(app, email: "cfo@acme.com", emailVerified: true)
            let cfoToken = try await signAccessToken(on: app, subject: "cfo")
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: cfoToken)
                try req.content.encode(AcceptInvitationDTO(token: token))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: cfoToken, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.POST, "companies", beforeRequest: { req in
                authorize(&req, token: cfoToken, organizationID: orgID)
                try req.content.encode(CreateCompanyDTO(code: "EAST", name: "Acme East"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            let cfo = try await User.find(email: "cfo@acme.com", on: app.db)
            let cfoID = try #require(cfo).requireID()
            let cfoMembership = try await OrganizationUser.query(on: app.db, organizationID: orgID)
                .filter(\.$user.$id == cfoID)
                .first()
            let cfoGroup = try await GroupMember.query(on: app.db)
                .filter(\.$organizationUser.$id == cfoMembership!.requireID())
                .first()
            #expect(cfoGroup?.$group.id == adminGroup.id)
            #expect(cfoGroup?.$createdBy.id == cfoID)

            var betaID: UUID?
            try await app.testing().test(.POST, "platform/organizations", beforeRequest: { req in
                authorize(&req, token: adminToken)
                try req.content.encode(ProvisionOrganizationDTO(
                    code: "BETA",
                    name: "Beta LLC",
                    adminEmail: "cfo@beta.com",
                    adminFirstName: "Bea",
                    adminLastName: "Beta"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                betaID = try res.content.decode(ProvisionOrganizationResponse.self).organization.id
            })
            try await app.testing().test(.DELETE, "groups/\(try viewerGroup.requireID())/roles/\(try viewerRole.requireID())", beforeRequest: { req in
                authorize(&req, token: cfoToken, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            let betaViewers = try await AccessGroup.query(on: app.db, organizationID: try #require(betaID))
                .filter(\.$templateKey == GroupTemplate.organizationViewers.key)
                .with(\.$roles)
                .first()
            #expect(betaViewers?.roles.isEmpty == false)
            let detached = try await GroupRole.query(on: app.db)
                .filter(\.$group.$id == viewerGroup.requireID())
                .withDeleted()
                .first()
            #expect(detached?.deletedAt != nil)
            #expect(detached?.$deletedBy.id == cfoID)

            try await app.testing().test(.POST, "platform/organizations", beforeRequest: { req in
                authorize(&req, token: adminToken)
                try req.content.encode(ProvisionOrganizationDTO(
                    code: "ACME",
                    name: "Acme Again",
                    adminEmail: "second@acme.com",
                    adminFirstName: "Sam",
                    adminLastName: "Second"
                ))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })
            #expect(try await Organization.query(on: app.db).filter(\.$code == "ACME").count() == 1)
            #expect(try await OrganizationInvitation.query(on: app.db).filter(\.$email == "second@acme.com").count() == 0)
            #expect(try await AccessGroup.query(on: app.db).filter(\.$templateKey == GroupTemplate.organizationAdministrators.key).count() == 2)
            _ = stranger
        }
    }
}
