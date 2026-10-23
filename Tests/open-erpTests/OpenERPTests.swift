@testable import open_erp
import Fluent
import Testing
import VaporTesting

@Suite("App Tests with DB", .serialized)
struct OpenERPTests {
    @Test("POST /companies assigns organization from header and records created_by")
    func createCompanyUsesHeaderOrganization() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            let user = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "ada@example.com",
                subject: "ada",
                permissions: Permission.allCases
            )
            let userID = try user.requireID()
            let token = try await signAccessToken(on: app, subject: "ada")

            var createdCompanyID: UUID?
            try await app.testing().test(.POST, "companies", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgID)
                try req.content.encode(CreateCompanyDTO(code: "COMPA", name: "Company A"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let dto = try res.content.decode(GetCompanyDTO.self)
                #expect(dto.code == "COMPA")
                #expect(dto.organizationId == orgID)
                #expect(dto.createdById == userID)
                createdCompanyID = dto.id
            })

            let companyID = try #require(createdCompanyID)
            let group = AccessGroup(organizationID: orgID, name: "Plant", createdByID: userID)
            try await group.save(on: app.db)
            try await GroupCompany(
                groupID: try group.requireID(),
                companyID: companyID,
                createdByID: userID
            ).save(on: app.db)
            try await app.testing().test(.DELETE, "companies/\(companyID)", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })

            let deleted = try await Company.query(on: app.db).withDeleted().filter(\.$id == companyID).first()
            #expect(deleted?.deletedAt != nil)
            #expect(deleted?.$deletedBy.id == userID)
            let eligibility = try await GroupCompany.query(on: app.db)
                .filter(\.$company.$id == companyID)
                .withDeleted()
                .first()
            #expect(eligibility?.deletedAt != nil)
            #expect(eligibility?.$deletedBy.id == userID)
        }
    }

    @Test("Company in org A is invisible to org B")
    func companyTenantIsolation() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()
            _ = try await createMember(
                on: app.db,
                organizationID: orgBID,
                email: "bea@example.com",
                subject: "bea",
                permissions: Permission.allCases
            )
            let token = try await signAccessToken(on: app, subject: "bea")

            let company = Company(
                code: "COMPA",
                name: "Company A",
                organizationID: orgAID,
                createdBy: nil,
                updatedBy: nil,
                deletedBy: nil
            )
            try await company.save(on: app.db)
            let companyID = try company.requireID()

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgBID)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let companies = try res.content.decode(Page<GetCompanyDTO>.self)
                #expect(companies.items.isEmpty)
            })

            try await app.testing().test(.GET, "companies/\(companyID)", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgBID)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.PATCH, "companies/\(companyID)", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgBID)
                try req.content.encode(PatchCompanyDTO(code: nil, name: "Hijacked"))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.DELETE, "companies/\(companyID)", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgBID)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            let stillThere = try await Company.query(on: app.db, organizationID: orgAID)
                .filter(\.$id == companyID)
                .first()
            #expect(stillThere?.name == "Company A")
        }
    }

    @Test("GET /users returns only users linked to the organization")
    func usersScopedToOrganization() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()
            _ = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "ann@example.com",
                subject: "ann",
                permissions: [.organizationUserRead],
                firstName: "Ann",
                lastName: "A"
            )
            _ = try await createMember(
                on: app.db,
                organizationID: orgBID,
                email: "bob@example.com",
                subject: "bob",
                permissions: [.organizationUserRead],
                firstName: "Bob",
                lastName: "B"
            )
            let token = try await signAccessToken(on: app, subject: "ann")

            try await app.testing().test(.GET, "users", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgAID)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let users = try res.content.decode(Page<GetUserDTO>.self)
                #expect(users.items.map(\.email) == ["ann@example.com"])
            })
        }
    }

    @Test("Deleting an organization-user link hides that user and records deleted_by")
    func deleteOrganizationUserHidesUser() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            let admin = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "admin@example.com",
                subject: "admin",
                permissions: [.organizationUserRead, .organizationUserDelete, .organizationInvitationCreate]
            )
            let other = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "ann@example.com",
                subject: "ann",
                permissions: [.companyRead],
                firstName: "Ann",
                lastName: "A"
            )
            let adminID = try admin.requireID()
            let otherID = try other.requireID()
            let adminToken = try await signAccessToken(on: app, subject: "admin")
            let annToken = try await signAccessToken(on: app, subject: "ann")

            try await app.testing().test(.DELETE, "organization-users/\(otherID)", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })

            let membership = try await OrganizationUser.query(on: app.db, organizationID: orgID)
                .filter(\.$user.$id == otherID)
                .withDeleted()
                .first()
            #expect(membership?.deletedAt != nil)
            #expect(membership?.$deletedBy.id == adminID)

            try await app.testing().test(.GET, "users", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let users = try res.content.decode(Page<GetUserDTO>.self)
                #expect(users.items.map(\.email) == ["admin@example.com"])
            })

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: annToken, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            let revoked = try await GroupMember.query(on: app.db)
                .filter(\.$organizationUser.$id == membership!.requireID())
                .withDeleted()
                .first()
            #expect(revoked?.deletedAt != nil)
            #expect(revoked?.$deletedBy.id == adminID)

            var inviteToken = ""
            try await app.testing().test(.POST, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
                try req.content.encode(CreateInvitationDTO(email: "ann@example.com", firstName: "Ann", lastName: "A", groupId: nil))
            }, afterResponse: { res async throws in
                inviteToken = try res.content.decode(CreateInvitationResponse.self).token
            })
            stubUserInfo(app, email: "ann@example.com", emailVerified: true)
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: annToken)
                try req.content.encode(AcceptInvitationDTO(token: inviteToken))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: annToken, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden, "Re-joining must not restore revoked roles")
            })
            let memberships = try await OrganizationUser.query(on: app.db, organizationID: orgID)
                .filter(\.$user.$id == otherID)
                .withDeleted()
                .all()
            #expect(memberships.count == 2)
            #expect(memberships.contains { $0.$deletedBy.id == adminID })
        }
    }
}
