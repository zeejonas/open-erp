@testable import open_erp
import Fluent
import SQLKit
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Queue-age attention and cancellation reasons remain visible without payloads")
    func webhookQueueHealth() async throws {
        try await withApp { app in
            let fixture = try await webhookDeliveryFixture(app)
            let tenant = fixture.tenant
            let path = "webhook-subscriptions/\(fixture.subscription.id)/health"
            let initial = try await webhookRequest(app, .GET, path, tenant: tenant)
            #expect(try initial.content.decode(WebhookHealthDTO.self).needsAttention == false)
            try await app.db.requireSQL().raw("UPDATE webhook_deliveries SET created_at = now() - interval '10 minutes' WHERE subscription_id = \(bind: fixture.subscription.id)").run()
            let aged = try await webhookRequest(app, .GET, path, tenant: tenant)
            #expect(try aged.content.decode(WebhookHealthDTO.self).needsAttention)
            let logs = CapturingLogHandler()
            let logger = Logger(label: "webhook-summary") { _ in logs }
            let worker = WebhookWorker(database: app.db, logger: logger, sender: fixture.sender, transport: { _, _, _ in .init(status: 200, retryAfter: nil) })
            await worker.metrics.recordClaim(0.01)
            await worker.metrics.recordClaim(0.03)
            try await worker.logSummary()
            #expect(logs.lines.contains { $0.contains("Webhook worker summary") && $0.contains("median_claim_ms") && $0.contains("max_claim_ms") })
            #expect(logs.lines.contains { $0.contains("backlog age exceeds five minutes") })
            #expect(try await webhookRequest(app, .POST, "webhook-subscriptions/\(fixture.subscription.id)/disable", tenant: tenant).status == .noContent)
            let cancelled = try await webhookRequest(app, .GET, "webhook-deliveries?state=cancelled", tenant: tenant)
            let page = try cancelled.content.decode(Page<WebhookDeliveryDTO>.self)
            #expect(page.items.count == 1 && page.items[0].cancellationReason == .subscriptionDisabled)
            let health = try await webhookRequest(app, .GET, path, tenant: tenant)
            #expect(try health.content.decode(WebhookHealthDTO.self).counts["cancelled"] == 1)
            #expect(!cancelled.body.string.contains("\"data\"") && !cancelled.body.string.contains("secretCiphertext"))
        }
    }
    @Test("Event catalog and history paginate stably, isolate tenants and gate retained bodies")
    func webhookEventHistory() async throws {
        try await withApp { app in
            let fixture = try await webhookDeliveryFixture(app, events: 3)
            let tenant = fixture.tenant, other = try await webhookTenant(app, code: "HISTORY-OTHER")
            let catalog = try await webhookRequest(app, .GET, "webhook-event-types?per=100", tenant: tenant)
            #expect(catalog.status == .ok)
            let catalogPage = try catalog.content.decode(Page<WebhookEventTypeDTO>.self)
            #expect(catalogPage.items.count == 35 && catalogPage.metadata.total == 35)
            #expect(catalogPage.items.map { $0.type.rawValue } == BusinessEventType.allCases.map(\.rawValue).sorted())
            for query in ["sort=type", "type=company.created", "per=1&per=2"] {
                #expect(try await webhookRequest(app, .GET, "webhook-event-types?\(query)", tenant: tenant).status == .badRequest)
            }
            let events = try await BusinessEvent.query(on: app.db).filter(\.$organization.$id == tenant.organizationID).all()
            let event = try #require(events.first), id = try event.requireID()
            let metadata = try await webhookRequest(app, .GET, "webhook-events/\(id)", tenant: tenant)
            #expect(metadata.status == .ok)
            #expect(!metadata.body.string.contains("\"data\"") && !metadata.body.string.contains("transactionId") && !metadata.body.string.contains("captureSnapshot"))
            let payload = try await webhookRequest(app, .GET, "webhook-events/\(id)/payload", tenant: tenant)
            #expect(Data(payload.body.string.utf8) == event.payload)
            let deniedUser = try await createMember(on: app.db, organizationID: tenant.organizationID, email: "event-reader@example.com", subject: "event-reader", permissions: [.webhookEventRead])
            let reader = WebhookTestTenant(organizationID: tenant.organizationID, userID: try deniedUser.requireID(), token: try await signAccessToken(on: app, subject: "event-reader"))
            #expect(try await webhookRequest(app, .GET, "webhook-events/\(id)/payload", tenant: reader).status == .forbidden)
            #expect(try await webhookRequest(app, .GET, "webhook-events/\(id)", tenant: other).status == .notFound)
            let foreign = try await webhookRequest(app, .GET, "webhook-events?resourceId=\(event.resourceID)", tenant: other)
            #expect(try foreign.content.decode(Page<WebhookEventDTO>.self).metadata.total == 0)
            for query in ["type=unknown", "resourceType=unknown", "from=invalid", "sort=id", "type=group.created&type=group.created", "resourceId=invalid"] {
                #expect(try await webhookRequest(app, .GET, "webhook-events?\(query)", tenant: tenant).status == .badRequest)
            }
            let filter = "type=group.created&resourceId=\(event.resourceID)"
            let filtered = try await webhookRequest(app, .GET, "webhook-events?\(filter)", tenant: tenant)
            #expect(try filtered.content.decode(Page<WebhookEventDTO>.self).items.map(\.id) == [id])
            var ids: [UUID] = []
            for page in 1...3 {
                let result = try await webhookRequest(app, .GET, "webhook-events?per=1&page=\(page)", tenant: tenant)
                ids += try result.content.decode(Page<WebhookEventDTO>.self).items.map(\.id)
            }
            #expect(Set(ids).count == 3)
        }
    }

    @Test("Delivery histories join start/results, restrict payloads and expose operational health")
    func webhookDeliveryHistory() async throws {
        try await withApp { app in
            let fixture = try await webhookDeliveryFixture(app)
            let tenant = fixture.tenant, other = try await webhookTenant(app, code: "DELIVERY-OTHER")
            let claim = try #require(try await fixture.sender.claim(on: app.db))
            let path = "webhook-deliveries/\(claim.deliveryID)"
            let started = try await webhookRequest(app, .GET, "\(path)/attempts?outcome=started", tenant: tenant)
            #expect(try started.content.decode(Page<WebhookAttemptDTO>.self).items.first?.outcome == .started)
            fixture.clock.withLockedValue { $0 = $0.addingTimeInterval(2) }
            try await fixture.sender.finish(claim, outcome: .exhausted, status: 400, on: app.db)
            let attempts = try await webhookRequest(app, .GET, "\(path)/attempts?outcome=exhausted", tenant: tenant)
            let history = try attempts.content.decode(Page<WebhookAttemptDTO>.self)
            #expect(history.items.count == 1 && history.items[0].id == claim.id && history.items[0].httpStatus == 400)
            #expect(!attempts.body.string.contains("whsec_") && !attempts.body.string.contains("secretCiphertext"))
            let health = try await webhookRequest(app, .GET, "webhook-subscriptions/\(claim.subscriptionID)/health", tenant: tenant)
            #expect(health.status == .ok)
            let state = try health.content.decode(WebhookHealthDTO.self)
            #expect(state.needsAttention && state.counts["exhausted"] == 1)
            #expect(state.medianAttemptDurationSeconds == 2)
            #expect(state.lastFailureAt != nil && state.failingSince != nil)
            let missingSource = try await createMember(on: app.db, organizationID: tenant.organizationID, email: "payload-reader@example.com", subject: "payload-reader", permissions: [.webhookDeliveryRead, .webhookPayloadRead])
            let reader = WebhookTestTenant(organizationID: tenant.organizationID, userID: try missingSource.requireID(), token: try await signAccessToken(on: app, subject: "payload-reader"))
            #expect(try await webhookRequest(app, .GET, "\(path)/payload", tenant: reader).status == .forbidden)
            #expect(try await webhookRequest(app, .GET, "\(path)/attempts", tenant: other).status == .notFound)
            #expect(try await webhookRequest(app, .GET, "webhook-subscriptions/\(claim.subscriptionID)/health", tenant: other).status == .notFound)
            let payload = try await webhookRequest(app, .GET, "\(path)/payload", tenant: tenant)
            #expect(Data(payload.body.string.utf8) == claim.body)
            let foreign = try await webhookRequest(app, .GET, "webhook-deliveries?eventId=\(claim.eventID)", tenant: other)
            #expect(try foreign.content.decode(Page<WebhookDeliveryDTO>.self).metadata.total == 0)
            for suffix in ["outcome=invalid", "sort=createdAt", "from=invalid", "outcome=started&outcome=unknown"] {
                #expect(try await webhookRequest(app, .GET, "\(path)/attempts?\(suffix)", tenant: tenant).status == .badRequest)
            }
            for query in ["state=invalid", "eventId=invalid", "from=invalid", "sort=id", "state=pending&state=retrying"] {
                #expect(try await webhookRequest(app, .GET, "webhook-deliveries?\(query)", tenant: tenant).status == .badRequest)
            }
        }
    }
}
