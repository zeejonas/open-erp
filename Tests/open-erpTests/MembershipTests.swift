@testable import open_erp
import Fluent
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Missing or malformed organization header is 400")
    func organizationHeaderValidation() async throws {
        try await withApp { app in
            _ = try await createUser(on: app.db, email: "ada@example.com", subject: "ada")
            let token = try await signAccessToken(on: app, subject: "ada")

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: token)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: token)
                req.headers.replaceOrAdd(name: OrganizationMiddleware.headerName, value: "not-a-uuid")
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Non-member, unknown organization, removed membership, and deleted organization are 403")
    func membershipDenied() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let deleted = try await createOrganization(on: app.db, code: "ORGD", name: "Deleted")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()
            let deletedID = try deleted.requireID()
            try await deleted.delete(on: app.db)

            let user = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "ada@example.com",
                subject: "ada",
                permissions: [.companyRead]
            )
            let removed = try await createMember(
                on: app.db,
                organizationID: orgBID,
                email: "bea@example.com",
                subject: "bea",
                permissions: [.companyRead]
            )
            let removedMembership = try await OrganizationUser.query(on: app.db, organizationID: orgBID)
                .filter(\.$user.$id == removed.requireID())
                .first()
            try await removedMembership?.delete(on: app.db)

            let ada = try await signAccessToken(on: app, subject: "ada")
            let bea = try await signAccessToken(on: app, subject: "bea")

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: ada, organizationID: orgBID)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: ada, organizationID: UUID())
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: bea, organizationID: orgBID)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: ada, organizationID: deletedID)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            _ = user
        }
    }

    @Test("A member with no roles is forbidden on organization routes")
    func memberWithNoRoles() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            _ = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "ada@example.com",
                subject: "ada",
                permissions: []
            )
            let token = try await signAccessToken(on: app, subject: "ada")
            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }
}
