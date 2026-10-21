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
            #expect(Set(adminRole.permissionGrants.map(\.permission)) == Set(Permission.allCases.map(\.rawValue)))
            #expect(viewerRole.name == "Organization Viewer")
            #expect(Set(viewerRole.permissionGrants.map(\.permission)) == Set(Permission.allCases.filter(\.isRead).map(\.rawValue)))

            let invitation = try await OrganizationInvitation.query(on: app.db)
                .filter(\.$tokenHash == InvitationToken.hash(token))
                .first()
            #expect(invitation?.email == "cfo@acme.com")
            #expect(invitation?.$role.id == adminRole.id)

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
            _ = stranger
        }
    }
}
