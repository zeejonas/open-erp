@testable import open_erp
import Fluent
import SQLKit
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Subscription API creates disabled, records disclosure, rotates and redacts secrets")
    func webhookSubscriptionLifecycle() async throws {
        try await withApp { app in
            let tenant = try await webhookTenant(app)
            let create = try await webhookRequest(app, .POST, "webhook-subscriptions", tenant: tenant,
                body: CreateWebhookSubscriptionDTO(name: "Receiver", url: "https://receiver.example/events", eventTypes: [.groupCreated], companyIds: []))
            #expect(create.status == .ok)
            let subscription = try create.content.decode(WebhookSubscriptionDTO.self)
            #expect(!subscription.enabled)
            #expect(subscription.configuration.schemaVersion == 1)
            #expect(!create.body.string.contains("secretCiphertext") && !create.body.string.contains("whsec_"))
            let id = subscription.id
            let reveal = try await webhookRequest(app, .POST, "webhook-subscriptions/\(id)/secret", tenant: tenant)
            #expect(reveal.status == .ok)
            #expect(reveal.headers[.cacheControl] == ["no-store"])
            let first = try reveal.content.decode(WebhookSecretDTO.self)
            let evidence = try #require(try await WebhookSecretReveal.query(on: app.db).first())
            #expect(evidence.actorID == tenant.userID && evidence.secretID == first.secretId)
            let rotate = try await webhookRequest(app, .PATCH, "webhook-subscriptions/\(id)", tenant: tenant,
                body: PatchWebhookSubscriptionDTO(expectedRevisionId: subscription.currentRevisionId, rotateSecret: true))
            #expect(rotate.status == .ok)
            let rotated = try rotate.content.decode(WebhookSubscriptionDTO.self)
            #expect(rotated.configuration.secretId != first.secretId)
            #expect(rotated.configuration.version == 2)
            let next = try await webhookRequest(app, .POST, "webhook-subscriptions/\(id)/secret", tenant: tenant)
            let second = try next.content.decode(WebhookSecretDTO.self)
            #expect(second.secret != first.secret)
            let versions = try await webhookRequest(app, .GET, "webhook-subscriptions/\(id)/versions", tenant: tenant)
            #expect(try versions.content.decode(Page<WebhookRevisionDTO>.self).metadata.total == 2)
            #expect(!versions.body.string.contains(first.secret) && !versions.body.string.contains(second.secret))
            let audit = try await AuditEvent.query(on: app.db).filter(\.$tableName == WebhookSubscriptionRevision.schema).all()
            #expect(audit.count == 2)
            #expect(audit.allSatisfy { $0.newValues?.values["secret_ciphertext"] == nil })
            let sql = try app.db.requireSQL()
            try await sql.raw("ALTER TABLE webhook_secret_reveals ADD CONSTRAINT test_reveal_failure CHECK (false) NOT VALID").run()
            let failed = try await webhookRequest(app, .POST, "webhook-subscriptions/\(id)/secret", tenant: tenant)
            #expect(failed.status == .internalServerError)
            #expect(!failed.body.string.contains(second.secret))
            try await sql.raw("ALTER TABLE webhook_secret_reveals DROP CONSTRAINT test_reveal_failure").run()
            let deleted = try await webhookRequest(app, .DELETE, "webhook-subscriptions/\(id)", tenant: tenant)
            #expect(deleted.status == .noContent)
            #expect(try await webhookRequest(app, .POST, "webhook-subscriptions/\(id)/secret", tenant: tenant).status == .notFound)
        }
    }

    @Test("Webhook scopes, missing grants, tenant isolation and list parameters are strict")
    func webhookSubscriptionValidation() async throws {
        try await withApp { app in
            let tenant = try await webhookTenant(app), other = try await webhookTenant(app, code: "OTHER")
            let valid = CreateWebhookSubscriptionDTO(name: "Receiver", url: "https://receiver.example/events", eventTypes: [.companyCreated], companyIds: [])
            for missing: Permission in [.webhookSubscriptionCreate, .webhookPayloadRead, .companyRead] {
                let user = try await createMember(on: app.db, organizationID: tenant.organizationID, email: "\(missing.rawValue)@example.com",
                    subject: missing.rawValue, permissions: Permission.allCases.filter { $0 != missing })
                let denied = WebhookTestTenant(organizationID: tenant.organizationID, userID: try user.requireID(), token: try await signAccessToken(on: app, subject: missing.rawValue))
                #expect(try await webhookRequest(app, .POST, "webhook-subscriptions", tenant: denied, body: valid).status == .forbidden)
            }
            #expect(try await WebhookSubscription.query(on: app.db).count() == 0)
            for url in ["http://receiver.example", "https://user:password@receiver.example", "https://receiver.example:444", "https://receiver.example?secret=x", "https://receiver.example#fragment", "https://127.0.0.1", "https://[::1]"] {
                var body = valid
                body.url = url
                #expect(try await webhookRequest(app, .POST, "webhook-subscriptions", tenant: tenant, body: body).status == .badRequest)
            }
            let foreignCompany = Company(code: "FOREIGN", name: "Foreign", organizationID: other.organizationID, createdBy: nil, updatedBy: nil, deletedBy: nil)
            try await foreignCompany.save(on: app.db)
            var scope = valid
            scope.companyIds = [try foreignCompany.requireID()]
            #expect(try await webhookRequest(app, .POST, "webhook-subscriptions", tenant: tenant, body: scope).status == .badRequest)
            scope.eventTypes = [.organizationUpdated]
            #expect(try await webhookRequest(app, .POST, "webhook-subscriptions", tenant: tenant, body: scope).status == .badRequest)
            let created = try await webhookRequest(app, .POST, "webhook-subscriptions", tenant: tenant, body: valid)
            let subscription = try created.content.decode(WebhookSubscriptionDTO.self)
            for suffix in ["", "/versions", "/secret", "/disable"] {
                #expect(try await webhookRequest(app, suffix == "/secret" || suffix == "/disable" ? .POST : .GET,
                    "webhook-subscriptions/\(subscription.id)\(suffix)", tenant: other).status == .notFound)
            }
            let outsider = WebhookTestTenant(organizationID: tenant.organizationID, userID: other.userID, token: other.token)
            #expect(try await webhookRequest(app, .GET, "webhook-subscriptions", tenant: outsider).status == .forbidden)
            for query in ["sort=name", "enabled=invalid", "eventType=unknown", "name=x&name=y", "per=101"] {
                #expect(try await webhookRequest(app, .GET, "webhook-subscriptions?\(query)", tenant: tenant).status == .badRequest)
            }
            let listed = try await webhookRequest(app, .GET, "webhook-subscriptions?enabled=false&eventType=company.created", tenant: tenant)
            #expect(listed.status == .ok)
            #expect(try listed.content.decode(Page<WebhookSubscriptionDTO>.self).items.map(\.id) == [subscription.id])
            let noSecretUser = try await createMember(on: app.db, organizationID: tenant.organizationID, email: "metadata@example.com", subject: "metadata",
                permissions: [.webhookSubscriptionRead, .webhookSubscriptionUpdate])
            let metadata = WebhookTestTenant(organizationID: tenant.organizationID, userID: try noSecretUser.requireID(), token: try await signAccessToken(on: app, subject: "metadata"))
            #expect(try await webhookRequest(app, .POST, "webhook-subscriptions/\(subscription.id)/secret", tenant: metadata).status == .forbidden)
            #expect(try await webhookRequest(app, .POST, "webhook-subscriptions/\(subscription.id)/disable", tenant: metadata).status == .forbidden)
            #expect(try await WebhookSecretReveal.query(on: app.db).count() == 0)
        }
    }

    @Test("Concurrent creates cannot exceed the tenant subscription quota")
    func webhookSubscriptionQuota() async throws {
        try await withApp { app in
            let tenant = try await webhookTenant(app), key = try #require(app.webhookEncryptionKey)
            let body = CreateWebhookSubscriptionDTO(name: "Receiver", url: "https://receiver.example", eventTypes: [.groupCreated], companyIds: [])
            try await app.db.auditedTransaction(AuditContext(actorType: .system)) { db in
                for _ in 0..<99 {
                    _ = try await WebhookSubscriptionService.create(body.configuration, organizationID: tenant.organizationID, actorID: tenant.userID, key: key, on: db)
                }
            }
            async let first = webhookRequest(app, .POST, "webhook-subscriptions", tenant: tenant, body: body)
            async let second = webhookRequest(app, .POST, "webhook-subscriptions", tenant: tenant, body: body)
            let responses = try await [first, second]
            #expect(Set(responses.map(\.status)) == [.ok, .conflict])
            #expect(try await WebhookSubscription.query(on: app.db).count() == 100)
        }
    }
}

struct WebhookTestTenant: Sendable {
    let organizationID: UUID
    let userID: UUID
    let token: String
}

func webhookTenant(_ app: Application, code: String = "WEBHOOK") async throws -> WebhookTestTenant {
    let id = try await createOrganization(on: app.db, code: code, name: code).requireID()
    let user = try await createMember(on: app.db, organizationID: id, email: "\(code)@example.com", subject: code, permissions: Permission.allCases)
    return .init(organizationID: id, userID: try user.requireID(), token: try await signAccessToken(on: app, subject: code))
}

func webhookRequest(_ app: Application, _ method: HTTPMethod, _ path: String, tenant: WebhookTestTenant) async throws -> TestingHTTPResponse {
    try await app.testing().sendRequest(method, path, beforeRequest: { authorize(&$0, token: tenant.token, organizationID: tenant.organizationID) })
}

func webhookRequest<T: Encodable>(_ app: Application, _ method: HTTPMethod, _ path: String, tenant: WebhookTestTenant, body: T) async throws -> TestingHTTPResponse {
    try await app.testing().sendRequest(method, path, beforeRequest: {
        authorize(&$0, token: tenant.token, organizationID: tenant.organizationID)
        try $0.content.encode(body, as: .json)
    })
}
