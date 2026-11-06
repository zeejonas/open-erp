@testable import open_erp
import Fluent
import Testing
import VaporTesting

extension OpenERPTests {
    @Test func accessDiscovery() async throws {
        try await withApp { app in
            let first = try await createOrganization(on: app.db, code: "FIRST", name: "First").requireID()
            let second = try await createOrganization(on: app.db, code: "SECOND", name: "Second").requireID()
            let user = try await createMember(on: app.db, organizationID: first, email: "admin@example.com",
                subject: "admin", permissions: Permission.allCases)
            try await OrganizationUser(organizationID: second, userID: user.requireID(), createdByID: user.id).create(on: app.db)
            let token = try await signAccessToken(on: app, subject: "admin")
            let expected = Permission.allCases.map(\.rawValue).sorted()
            for (organization, permissions) in [(first, expected), (second, [])] {
                try await authorizedGet(app, "me/access", token: token, organizationID: organization) { res async throws in
                    #expect(res.status == .ok)
                    let access = try res.content.decode(CallerAccessDTO.self)
                    #expect(access.organizationId == organization)
                    #expect(access.permissions == permissions)
                }
            }
            try await authorizedGet(app, "me/access", token: token, organizationID: UUID()) { res async throws in
                #expect(res.status == .forbidden)
            }
            try await authorizedGet(app, "me/access", token: token) { res async throws in
                #expect(res.status == .badRequest)
            }

            for page in 1...3 {
                try await authorizedGet(app, "permissions", query: "level=organization&per=20&page=\(page)",
                    token: token, organizationID: first) { res async throws in
                    #expect(res.status == .ok)
                    let result = try res.content.decode(Page<PermissionDTO>.self)
                    #expect(result.metadata.total == expected.count)
                    #expect(result.items.map(\.permission) == Array(expected.dropFirst((page - 1) * 20).prefix(20)))
                    #expect(result.items.allSatisfy { $0.level == .organization })
                }
            }
            for (query, key) in [("name=x", "name"), ("level=invalid", "level"), ("per=0", "per"), ("page=1&page=2", "page")] {
                try await authorizedGet(app, "permissions", query: query, token: token, organizationID: first) { res async throws in
                    try expectBadRequest(res, naming: key)
                }
            }
            try await authorizedGet(app, "permissions", token: token, organizationID: second) { res async throws in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func organizationRestoration() async throws {
        try await withApp { app in
            let organization = try await createOrganization(on: app.db, code: "ORG", name: "Restorable")
            let id = try organization.requireID()
            let member = try await createMember(on: app.db, organizationID: id, email: "member@example.com",
                subject: "member", permissions: Permission.allCases)
            let platform = try await createUser(on: app.db, email: "ops@example.com", subject: "ops", isPlatformAdmin: true)
            let platformToken = try await signAccessToken(on: app, subject: "ops")
            let memberToken = try await signAccessToken(on: app, subject: "member")
            try await organization.softDelete(by: member.requireID(), \.$deletedBy, on: app.db)
            let deleted = try #require(try await Organization.query(on: app.db).withDeleted().filter(\.$id == id).first())
            let path = "platform/organizations/\(id)"
            for (query, ids) in [("", []), ("deleted=false", []), ("deleted=true", [id])] {
                try await authorizedGet(app, "platform/organizations", query: query, token: platformToken) { res async throws in
                    #expect(res.status == .ok)
                    let result = try res.content.decode(Page<PlatformOrganizationDTO>.self)
                    #expect(result.items.map(\.id) == ids)
                    #expect(result.metadata.total == ids.count)
                    #expect(result.items.allSatisfy { $0.deletedAt != nil && $0.deletedById == member.id })
                }
            }
            try await authorizedGet(app, path, token: platformToken) { res async throws in
                #expect(res.status == .notFound)
            }
            try await authorizedGet(app, "me/access", token: memberToken, organizationID: id) { res async throws in
                #expect(res.status == .forbidden)
            }

            func restore(_ target: String, token: String, body: [String: String]?, status: HTTPResponseStatus) async throws {
                try await app.testing().test(.POST, "platform/organizations/\(target)/restore", beforeRequest: { req in
                    authorize(&req, token: token)
                    if let body { try req.content.encode(body) }
                }, afterResponse: { res async throws in
                    #expect(res.status == status)
                    if status == .ok {
                        let restored = try res.content.decode(PlatformOrganizationDTO.self)
                        #expect(restored.id == id)
                        #expect(restored.deletedAt == nil && restored.deletedById == nil)
                        #expect(restored.updatedById == platform.id)
                    }
                })
            }

            let reason = ["reason": "Reversed accidental deletion"]
            try await restore(id.uuidString, token: memberToken, body: reason, status: .forbidden)
            try await restore(id.uuidString, token: platformToken, body: nil, status: .badRequest)
            try await restore(id.uuidString, token: platformToken, body: [:], status: .badRequest)
            try await restore(id.uuidString, token: platformToken, body: ["reason": " "], status: .badRequest)
            try await restore("invalid", token: platformToken, body: reason, status: .notFound)
            try await restore(UUID().uuidString, token: platformToken, body: reason, status: .notFound)
            try await restore(id.uuidString, token: platformToken, body: reason, status: .ok)
            let restoreEvent = try #require(try await AuditEvent.query(on: app.db)
                .filter(\.$recordID == id).filter(\.$operation == .restore).first())
            #expect(restoreEvent.actorType == .platformAdmin)
            #expect(restoreEvent.actorID == platform.id)
            try await restore(id.uuidString, token: platformToken, body: reason, status: .conflict)

            try await authorizedGet(app, "me/access", token: memberToken, organizationID: id) { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(CallerAccessDTO.self).permissions.count == Permission.allCases.count)
            }
            try await authorizedGet(app, "companies", token: platformToken, organizationID: id) { res async throws in
                #expect(res.status == .forbidden)
            }
            let records = try await OrganizationRestoration.query(on: app.db).all()
            #expect(records.count == 1)
            let evidence = try #require(records.first)
            #expect(evidence.$organization.id == id)
            #expect(evidence.deletedAt == deleted.deletedAt)
            #expect(evidence.$deletedBy.id == member.id)
            #expect(evidence.$restoredBy.id == platform.id)
            #expect(evidence.reason == reason["reason"])
            evidence.reason = "Changed"
            await #expect(throws: (any Error).self) { try await evidence.update(on: app.db) }
            await #expect(throws: (any Error).self) { try await evidence.delete(on: app.db) }
        }
    }
}
