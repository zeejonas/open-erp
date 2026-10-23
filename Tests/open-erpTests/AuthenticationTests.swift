@testable import open_erp
import Fluent
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Missing token is 401")
    func missingToken() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "me", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Token signed by an unknown key is 401")
    func invalidSignature() async throws {
        try await withApp { app in
            let token = try await signAccessToken(on: app, subject: "ada", untrustedKey: true)
            try await app.testing().test(.GET, "me", beforeRequest: { req in
                authorize(&req, token: token)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Wrong issuer or audience is 401")
    func wrongIssuerOrAudience() async throws {
        try await withApp { app in
            let wrongIssuer = try await signAccessToken(on: app, subject: "ada", issuer: "https://evil.example")
            try await app.testing().test(.GET, "me", beforeRequest: { req in
                authorize(&req, token: wrongIssuer)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            let wrongAudience = try await signAccessToken(on: app, subject: "ada", audience: "someone-else")
            try await app.testing().test(.GET, "me", beforeRequest: { req in
                authorize(&req, token: wrongAudience)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Expired token is 401")
    func expiredToken() async throws {
        try await withApp { app in
            let token = try await signAccessToken(
                on: app,
                subject: "ada",
                expiration: Date().addingTimeInterval(-60)
            )
            try await app.testing().test(.GET, "me", beforeRequest: { req in
                authorize(&req, token: token)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Unbound subject is 403 except when accepting an invitation")
    func unboundSubject() async throws {
        try await withApp { app in
            let token = try await signAccessToken(on: app, subject: "nobody")
            try await app.testing().test(.GET, "me", beforeRequest: { req in
                authorize(&req, token: token)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: token)
                try req.content.encode(AcceptInvitationDTO(token: "missing"))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("GET /me returns the caller and PATCH /me updates only the name")
    func currentUserProfile() async throws {
        try await withApp { app in
            let user = try await createUser(
                on: app.db,
                firstName: "Ada",
                lastName: "Lovelace",
                email: "ada@example.com",
                subject: "ada"
            )
            let userID = try user.requireID()
            let token = try await signAccessToken(on: app, subject: "ada")

            try await app.testing().test(.GET, "me", beforeRequest: { req in
                authorize(&req, token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let dto = try res.content.decode(GetUserDTO.self)
                #expect(dto.id == userID)
                #expect(dto.firstName == "Ada")
                #expect(dto.lastName == "Lovelace")
                #expect(dto.email == "ada@example.com")
            })

            struct ProfileProbe: Content {
                var firstName: String
                var email: String
                var isPlatformAdmin: Bool
            }
            try await app.testing().test(.PATCH, "me", beforeRequest: { req in
                authorize(&req, token: token)
                try req.content.encode(ProfileProbe(firstName: "Augusta", email: "other@example.com", isPlatformAdmin: true))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let dto = try res.content.decode(GetUserDTO.self)
                #expect(dto.firstName == "Augusta")
                #expect(dto.email == "ada@example.com")
                #expect(dto.updatedById == userID)
            })

            let reloaded = try await User.find(userID, on: app.db)
            #expect(reloaded?.firstName == "Augusta")
            #expect(reloaded?.email == "ada@example.com")
            #expect(reloaded?.isPlatformAdmin == false)
            #expect(reloaded?.$updatedBy.id == userID)
        }
    }

    @Test("Legacy user, organization, and link routes are gone")
    func legacyRoutesRemoved() async throws {
        try await withApp { app in
            for (method, path) in [
                (HTTPMethod.POST, "users"),
                (HTTPMethod.PATCH, "users/\(UUID())"),
                (HTTPMethod.POST, "organizations"),
                (HTTPMethod.POST, "organization-users"),
            ] {
                try await app.testing().test(method, path, afterResponse: { res async in
                    #expect(res.status == .notFound)
                })
            }
        }
    }

    @Test("GET /me/organizations returns only active memberships")
    func listMyOrganizations() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgC = try await createOrganization(on: app.db, code: "ORGC", name: "Org C")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()
            let orgCID = try orgC.requireID()
            let user = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "ada@example.com",
                subject: "ada",
                permissions: []
            )
            let userID = try user.requireID()
            try await OrganizationUser(organizationID: orgBID, userID: userID).save(on: app.db)
            let removed = OrganizationUser(organizationID: orgCID, userID: userID)
            try await removed.save(on: app.db)
            try await removed.delete(on: app.db)
            let token = try await signAccessToken(on: app, subject: "ada")

            try await app.testing().test(.GET, "me/organizations", beforeRequest: { req in
                authorize(&req, token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let organizations = try res.content.decode(Page<GetOrganizationDTO>.self)
                #expect(Set(organizations.items.compactMap(\.id)) == [orgAID, orgBID])
            })
        }
    }

    @Test("Userinfo accepts a boolean or string email_verified and treats a missing one as unverified")
    func userInfoDecoding() throws {
        func decode(_ json: String) throws -> UserInfo {
            try JSONDecoder().decode(UserInfo.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"email":"a@acme.com","email_verified":true}"#).emailVerified)
        #expect(try decode(#"{"email":"a@acme.com","email_verified":"true"}"#).emailVerified)
        #expect(try !decode(#"{"email":"a@acme.com"}"#).emailVerified)
        #expect(try decode(#"{"sub":"x"}"#).email == nil)
    }
}
