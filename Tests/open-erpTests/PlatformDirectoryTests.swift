@testable import open_erp
import Fluent
import SQLKit
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Platform directory validates filters and pages literal matches in stable order")
    func platformDirectoryList() async throws {
        try await withApp { app in
            let admin = try await createUser(on: app.db, email: "ops@example.com", subject: "ops", isPlatformAdmin: true)
            let token = try await signAccessToken(on: app, subject: "ops")
            var ids: [UUID] = []
            for index in 0..<4 {
                let org = try await createOrganization(on: app.db, code: "ACM\(index)", name: "Acme %_\\ literal")
                org.$createdBy.id = admin.id
                org.$updatedBy.id = admin.id
                if index == 3 { org.onboardedAt = Date() }
                try await org.save(on: app.db)
                ids.append(try org.requireID())
            }
            let deleted = try await createOrganization(on: app.db, code: "DEAD", name: "Acme %_\\ literal")
            try await deleted.delete(on: app.db)
            _ = try await createOrganization(on: app.db, code: "OTHER", name: "Acme ordinary")
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("UPDATE organizations SET updated_at = '2026-01-01T00:00:00Z'").run()
            let expected = Array(ids.prefix(3)).sorted { $0.uuidString < $1.uuidString }
            let filter = "code=acm&name=%25%5F%5C&onboarded=false&per=1"
            for page in 1...4 {
                try await authorizedGet(app, "platform/organizations", query: "\(filter)&page=\(page)", token: token) { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(Page<PlatformOrganizationDTO>.self)
                    #expect(body.metadata.total == 3)
                    #expect(body.metadata.page == page)
                    #expect(body.metadata.per == 1)
                    #expect(body.items.map(\.id) == (page <= 3 ? [expected[page - 1]] : []))
                    #expect(body.items.allSatisfy { $0.createdById == admin.id && $0.updatedById == admin.id })
                }
            }
            for (value, total) in [("true", 1), ("false", 4)] {
                try await authorizedGet(app, "platform/organizations", query: "onboarded=\(value)", token: token) { res async throws in
                    #expect(res.status == .ok)
                    #expect(try res.content.decode(Page<PlatformOrganizationDTO>.self).metadata.total == total)
                }
            }
            for (query, key) in [
                ("onboarded=yes", "onboarded"), ("onboarded=", "onboarded"),
                ("onboarded=true&onboarded=false", "onboarded"), ("onboardedStatus=pending", "onboardedStatus"),
                ("onboardingStatus=expired", "onboardingStatus"), ("name=", "name"), ("code=", "code"),
                ("name=a&name=b", "name"), ("page=0", "page"), ("page=abc", "page"),
                ("per=101", "per"), ("per=0", "per"), ("sort=name", "sort"), ("code[x]=a", "code[x]")
            ] {
                try await authorizedGet(app, "platform/organizations", query: query, token: token) { res async throws in
                    try expectBadRequest(res, naming: key)
                }
            }
        }
    }

    @Test("Platform detail separates completion, invitation history and diagnostics without writes")
    func platformDirectoryDetail() async throws {
        try await withApp { app in
            let admin = try await createUser(on: app.db, email: "ops@example.com", subject: "ops", isPlatformAdmin: true)
            let token = try await signAccessToken(on: app, subject: "ops")
            let org = try await createOrganization(on: app.db, code: "ACME", name: "Acme")
            let id = try org.requireID()
            let path = "platform/organizations/\(id)"
            func check(_ issue: PlatformOnboardingIssue?, invitationID: UUID? = nil) async throws {
                let before = try await Organization.find(id, on: app.db)
                let history = try await OrganizationInvitation.query(on: app.db, organizationID: id).withDeleted().sort(\.$id).all()
                try await authorizedGet(app, path, token: token) { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(PlatformOrganizationDetailDTO.self)
                    #expect(body.organization.id == id)
                    #expect(body.onboardingIssue == issue)
                    #expect(body.onboardingInvitation?.id == invitationID)
                    let selected = history.first { $0.id == invitationID }
                    #expect((body.onboardingInvitation?.revokedAt != nil) == (selected?.deletedAt != nil))
                }
                // Reads never repair or alter onboarding evidence.
                let after = try await Organization.find(id, on: app.db)
                #expect(after?.updatedAt == before?.updatedAt)
                let savedHistory = try await OrganizationInvitation.query(on: app.db, organizationID: id).withDeleted().sort(\.$id).all()
                #expect(savedHistory.map(\.acceptedAt) == history.map(\.acceptedAt))
                #expect(savedHistory.map(\.deletedAt) == history.map(\.deletedAt))
            }
            try await check(.missingOnboardingInvitation)
            // Ordinary invitations do not constitute onboarding lineage.
            _ = try await OrganizationInvitation.issue(organizationID: id, email: "other@example.com", firstName: "O", lastName: "T", groupID: nil, createdByID: admin.id, on: app.db)
            try await check(.missingOnboardingInvitation)
            let group = AccessGroup(organizationID: id, name: "Original", createdByID: admin.id)
            try await group.save(on: app.db)
            let (invitation, secret) = try await OrganizationInvitation.issue(organizationID: id,
                email: "admin@example.com", firstName: "Ada", lastName: "Admin", groupID: group.requireID(),
                createdByID: admin.id, isOnboarding: true, on: app.db)
            let invitationID = try invitation.requireID()
            try await check(nil, invitationID: invitationID)
            invitation.expiresAt = Date().addingTimeInterval(-60)
            try await invitation.save(on: app.db)
            try await check(nil, invitationID: invitationID)
            try await invitation.softDelete(by: admin.requireID(), \.$deletedBy, on: app.db)
            try await check(nil, invitationID: invitationID)
            let (live, _) = try await OrganizationInvitation.issue(organizationID: id,
                email: "admin@example.com", firstName: "Ada", lastName: "Admin", groupID: group.requireID(),
                createdByID: admin.id, isOnboarding: true, on: app.db)
            let liveID = try live.requireID()
            try await check(nil, invitationID: liveID)
            try await group.delete(on: app.db)
            try await check(.originalGroupUnavailable, invitationID: liveID)
            let foreign = try await createOrganization(on: app.db, code: "OTHR", name: "Other")
            let foreignGroup = AccessGroup(organizationID: try foreign.requireID(), name: "Foreign", createdByID: admin.id)
            try await foreignGroup.save(on: app.db)
            live.$group.id = foreignGroup.id
            try await live.save(on: app.db)
            try await check(.originalGroupUnavailable, invitationID: liveID)
            live.$group.id = nil
            try await live.save(on: app.db)
            try await check(.originalGroupUnavailable, invitationID: liveID)
            // Accepted deleted history takes precedence over group failure.
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("UPDATE organization_invitations SET accepted_at = CURRENT_TIMESTAMP WHERE id = \(bind: invitationID)").run()
            try await check(.acceptedWithoutCompletion, invitationID: liveID)
            org.onboardedAt = Date()
            try await org.save(on: app.db)
            try await check(nil, invitationID: liveID)
            try await authorizedGet(app, path, token: token) { res async throws in
                let body = try res.content.decode(PlatformOrganizationDetailDTO.self)
                #expect(body.organization.onboardedAt != nil)
                #expect(body.onboardingInvitation?.createdById == admin.id)
                #expect(body.onboardingInvitation?.email == "admin@example.com")
                #expect(!res.body.string.contains(secret))
            }
        }
    }

    @Test("Directory access is platform-only and grants no tenant authority")
    func platformDirectoryAuthorization() async throws {
        try await withApp { app in
            _ = try await createUser(on: app.db, email: "ops@example.com", subject: "ops", isPlatformAdmin: true)
            _ = try await createUser(on: app.db, email: "user@example.com", subject: "user")
            let token = try await signAccessToken(on: app, subject: "ops")
            let denied = try await signAccessToken(on: app, subject: "user")
            let org = try await createOrganization(on: app.db, code: "ACME", name: "Protected")
            let id = try org.requireID()
            for path in ["platform/organizations", "platform/organizations/\(id)", "platform/organizations/invalid"] {
                try await app.testing().test(.GET, path, afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                    #expect(!res.body.string.contains("Protected"))
                })
                try await authorizedGet(app, path, token: denied) { res async throws in
                    #expect(res.status == .forbidden)
                    #expect(!res.body.string.contains("Protected"))
                }
            }
            try await authorizedGet(app, "platform/organizations/invalid", token: token) { res async throws in
                #expect(res.status == .badRequest)
            }
            try await authorizedGet(app, "platform/organizations/\(UUID())", token: token) { res async throws in
                #expect(res.status == .notFound)
            }
            try await authorizedGet(app, "companies", token: token, organizationID: id) { res async throws in
                #expect(res.status == .forbidden)
            }
            try await org.delete(on: app.db)
            try await authorizedGet(app, "platform/organizations/\(id)", token: token) { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }
}
