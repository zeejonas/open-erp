@testable import open_erp
import VaporTesting
import Testing
import Fluent

@Suite("App Tests with DB", .serialized)
struct OpenERPTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func createOrganization(
        on db: any Database,
        code: String,
        name: String
    ) async throws -> Organization {
        let organization = Organization(
            code: code,
            name: name,
            createdBy: nil,
            updatedBy: nil,
            deletedBy: nil
        )
        try await organization.save(on: db)
        return organization
    }

    private func createUser(
        on db: any Database,
        firstName: String,
        lastName: String,
        email: String
    ) async throws -> User {
        let user = User(
            firstName: firstName,
            lastName: lastName,
            email: email,
            createdBy: nil,
            updatedBy: nil,
            deletedBy: nil
        )
        try await user.save(on: db)
        return user
    }

    private func withOrgHeader(_ organizationID: UUID) -> (inout TestingHTTPRequest) -> Void {
        { req in
            req.headers.replaceOrAdd(
                name: OrganizationMiddleware.headerName,
                value: organizationID.uuidString
            )
        }
    }

    // MARK: - Organization middleware

    @Test("Missing organization header returns 400")
    func missingOrganizationHeader() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "companies", afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Malformed organization header returns 400")
    func malformedOrganizationHeader() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                req.headers.replaceOrAdd(name: OrganizationMiddleware.headerName, value: "not-a-uuid")
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Unknown organization header returns 404")
    func unknownOrganizationHeader() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                req.headers.replaceOrAdd(
                    name: OrganizationMiddleware.headerName,
                    value: UUID().uuidString
                )
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    // MARK: - Company tenant isolation

    @Test("POST /companies assigns organization from header")
    func createCompanyUsesHeaderOrganization() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()

            try await app.testing().test(.POST, "companies", beforeRequest: { req in
                req.headers.replaceOrAdd(name: OrganizationMiddleware.headerName, value: orgID.uuidString)
                try req.content.encode(CreateCompanyDTO(code: "COMPA", name: "Company A"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let dto = try res.content.decode(GetCompanyDTO.self)
                #expect(dto.code == "COMPA")
                #expect(dto.organizationId == orgID)
            })
        }
    }

    @Test("Company in org A is invisible to org B")
    func companyTenantIsolation() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()

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

            try await app.testing().test(.GET, "companies", beforeRequest: withOrgHeader(orgBID), afterResponse: { res async throws in
                #expect(res.status == .ok)
                let companies = try res.content.decode([GetCompanyDTO].self)
                #expect(companies.isEmpty)
            })

            try await app.testing().test(.GET, "companies/\(companyID)", beforeRequest: withOrgHeader(orgBID), afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.PATCH, "companies/\(companyID)", beforeRequest: { req in
                req.headers.replaceOrAdd(name: OrganizationMiddleware.headerName, value: orgBID.uuidString)
                try req.content.encode(PatchCompanyDTO(code: nil, name: "Hijacked"))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.DELETE, "companies/\(companyID)", beforeRequest: withOrgHeader(orgBID), afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            let stillThere = try await Company.query(on: app.db, organizationID: orgAID)
                .filter(\.$id == companyID)
                .first()
            #expect(stillThere != nil)
            #expect(stillThere?.name == "Company A")
        }
    }

    // MARK: - Users and organization links

    @Test("GET /users returns only users linked to the organization")
    func usersScopedToOrganization() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()

            let userA = try await createUser(on: app.db, firstName: "Ann", lastName: "A", email: "ann@example.com")
            let userB = try await createUser(on: app.db, firstName: "Bob", lastName: "B", email: "bob@example.com")
            let userAID = try userA.requireID()
            let userBID = try userB.requireID()

            try await OrganizationUser(organizationID: orgAID, userID: userAID).save(on: app.db)
            try await OrganizationUser(organizationID: orgBID, userID: userBID).save(on: app.db)

            try await app.testing().test(.GET, "users", beforeRequest: withOrgHeader(orgAID), afterResponse: { res async throws in
                #expect(res.status == .ok)
                let users = try res.content.decode([GetUserDTO].self)
                #expect(users.count == 1)
                #expect(users[0].email == "ann@example.com")
            })
        }
    }

    @Test("Deleting organization-user link hides user from org")
    func deleteOrganizationUserHidesUser() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            let user = try await createUser(on: app.db, firstName: "Ann", lastName: "A", email: "ann@example.com")
            let userID = try user.requireID()

            try await OrganizationUser(organizationID: orgID, userID: userID).save(on: app.db)

            try await app.testing().test(
                .DELETE,
                "organization-users/\(userID)",
                beforeRequest: withOrgHeader(orgID),
                afterResponse: { res async in
                    #expect(res.status == .noContent)
                }
            )

            try await app.testing().test(.GET, "users", beforeRequest: withOrgHeader(orgID), afterResponse: { res async throws in
                #expect(res.status == .ok)
                let users = try res.content.decode([GetUserDTO].self)
                #expect(users.isEmpty)
            })
        }
    }

    @Test("Duplicate organization-user link returns 409")
    func duplicateOrganizationUserReturnsConflict() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            let user = try await createUser(on: app.db, firstName: "Ann", lastName: "A", email: "ann@example.com")
            let userID = try user.requireID()

            try await app.testing().test(.POST, "organization-users", beforeRequest: { req in
                req.headers.replaceOrAdd(name: OrganizationMiddleware.headerName, value: orgID.uuidString)
                try req.content.encode(CreateOrganizationUserDTO(userId: userID))
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "organization-users", beforeRequest: { req in
                req.headers.replaceOrAdd(name: OrganizationMiddleware.headerName, value: orgID.uuidString)
                try req.content.encode(CreateOrganizationUserDTO(userId: userID))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })
        }
    }
}
