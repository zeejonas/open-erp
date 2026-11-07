@testable import open_erp
import Fluent
import Foundation
import NIOConcurrencyHelpers
import SQLKit
import Testing
import VaporTesting

@Suite("Webhook retry and worker configuration")
struct WebhookRetryTests {
    @Test("Worker limits are positive and correctly ordered")
    func limits() throws {
        let defaults = try WebhookWorkerSettings { _ in nil }
        #expect(defaults.concurrency == 16 && defaults.perOrganization == 8 && defaults.perSubscription == 4 && defaults.pollIntervalMilliseconds == 1000)
        for value in ["0", "-1", "invalid"] {
            #expect(throws: WebhookWorkerSettings.InvalidValue.self) { try WebhookWorkerSettings { $0 == "WEBHOOK_WORKER_CONCURRENCY" ? value : nil } }
        }
        #expect(throws: WebhookWorkerSettings.InvalidValue.self) {
            try WebhookWorkerSettings { $0 == "WEBHOOK_MAX_IN_FLIGHT_PER_SUBSCRIPTION" ? "9" : nil }
        }
    }

    @Test("HTTP outcomes distinguish acknowledgment, retryable and terminal rejection", arguments: [
        (200, WebhookAttemptOutcome.acknowledged), (299, .acknowledged), (307, .exhausted), (400, .exhausted), (404, .exhausted),
        (408, .retryable), (425, .retryable), (429, .retryable), (500, .retryable), (599, .retryable),
    ])
    func status(status: Int, expected: WebhookAttemptOutcome) {
        #expect(WebhookRetryPolicy.outcome(status: status) == expected)
    }

    @Test("Full jitter, retry-after and the 72-hour boundary are bounded")
    func scheduling() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(WebhookRetryPolicy.nextAttempt(count: 1, firstAttempt: start, now: start, status: 500, retryAfter: nil, jitter: 1) == start.addingTimeInterval(5))
        #expect(WebhookRetryPolicy.nextAttempt(count: 100, firstAttempt: start, now: start, status: 500, retryAfter: nil, jitter: 1) == start.addingTimeInterval(21_600))
        #expect(WebhookRetryPolicy.nextAttempt(count: 1, firstAttempt: start, now: start, status: 429, retryAfter: "120", jitter: 0.5) == start.addingTimeInterval(120))
        #expect(WebhookRetryPolicy.nextAttempt(count: 1, firstAttempt: start, now: start, status: 503, retryAfter: "Tue, 14 Nov 2023 22:15:20 GMT", jitter: 0.5) == start.addingTimeInterval(120))
        let late = start.addingTimeInterval(WebhookRetryPolicy.window - 1)
        #expect(WebhookRetryPolicy.nextAttempt(count: 1, firstAttempt: start, now: late, status: 429, retryAfter: "999999999", jitter: 1) == nil)
        #expect(WebhookRetryPolicy.nextAttempt(count: 1, firstAttempt: start, now: start.addingTimeInterval(WebhookRetryPolicy.window), status: 500, retryAfter: nil, jitter: 1) == nil)
    }
}

extension OpenERPTests {
    @Test("Two processes add capacity, each remains bounded, and cancellation preserves recoverable starts")
    func webhookWorkerProcesses() async throws {
        try await withApp { app in
            let fixture = try await webhookDeliveryFixture(app, events: 8)
            let settings = try WebhookWorkerSettings { $0 == "WEBHOOK_WORKER_CONCURRENCY" ? "2" : nil }
            let sender = WebhookSender(settings: settings, key: try WebhookEncryptionKey.load())
            let reached = WebhookTestSignal()
            let count = NIOLockedValueBox(0)
            let send: @Sendable (String, Data, HTTPHeaders) async throws -> WebhookHTTPResult = { _, _, _ in
                let total = count.withLockedValue { $0 += 1; return $0 }
                if total == 4 { await reached.signal() }
                try await Task.sleep(for: .seconds(60))
                return .init(status: 200, retryAfter: nil)
            }
            let first = WebhookWorker(database: app.db, logger: app.logger, sender: sender, transport: send)
            let second = WebhookWorker(database: app.db, logger: app.logger, sender: sender, transport: send)
            let one = Task { await first.run() }, two = Task { await second.run() }
            await reached.wait()
            let firstCount = await first.metrics.snapshot().inFlight, secondCount = await second.metrics.snapshot().inFlight
            #expect(firstCount <= 2 && secondCount <= 2 && firstCount + secondCount == 4)
            #expect(try await WebhookDelivery.query(on: app.db).filter(\.$state == .inFlight).count() == 4)
            one.cancel()
            two.cancel()
            await one.value
            await two.value
            #expect(try await WebhookDeliveryEntry.query(on: app.db).filter(\.$kind == .started).count() == 4)
            #expect(try await WebhookDeliveryEntry.query(on: app.db).filter(\.$kind == .result).count() == 0)
            #expect(try await WebhookDelivery.query(on: app.db).filter(\.$state == .pending).count() == 4)
        }
    }

    @Test("A saturated subscription cannot block another tenant's due work")
    func webhookWorkerFairness() async throws {
        try await withApp { app in
            let first = try await webhookDeliveryFixture(app, events: 8, code: "FIRST")
            for _ in 0..<4 { #expect(try await first.sender.claim(on: app.db) != nil) }
            #expect(try await first.sender.claim(on: app.db) == nil)
            let other = try await webhookDeliveryFixture(app, events: 1, code: "SECOND")
            first.clock.withLockedValue { $0 = Date().addingTimeInterval(1) }
            let claim = try #require(try await first.sender.claim(on: app.db, afterOrganizationID: first.tenant.organizationID))
            #expect(claim.organizationID == other.tenant.organizationID)
        }
    }

    @Test("Worker command starts without OIDC or listener and rejects an unsafe production role")
    func webhookWorkerRuntime() async throws {
        try await withApp(serving: false) { app in
            #expect(!app.signingKeysLoaded)
            let task = Task {
                var context = CommandContext(console: app.console, input: CommandInput(arguments: ["webhook-worker"]))
                context.application = app
                try await WebhookWorkerCommand().run(using: &context)
            }
            await Task.yield()
            task.cancel()
            try await task.value
            #expect(!app.signingKeysLoaded)
            app.environment = .production
            var context = CommandContext(console: app.console, input: CommandInput(arguments: ["webhook-worker"]))
            context.application = app
            await #expect(throws: AuditSafetyError.unsafeDatabaseRole) {
                try await WebhookWorkerCommand().run(using: &context)
            }
            app.environment = .testing
        }
    }
    @Test("Claims obey the shared subscription limit and release capacity on completion")
    func webhookWorkerClaims() async throws {
        try await withApp { app in
            let fixture = try await webhookDeliveryFixture(app, events: 8)
            let sender = fixture.sender
            let claims = try await withThrowingTaskGroup(of: ClaimedWebhookAttempt?.self) { group in
                for _ in 0..<12 { group.addTask { try await sender.claim(on: app.db) } }
                var claims: [ClaimedWebhookAttempt] = []
                for try await claim in group { if let claim { claims.append(claim) } }
                return claims
            }
            #expect(!claims.isEmpty && claims.count <= 4)
            // SKIP LOCKED may have skipped the busy subscription; fill the remaining exact slots.
            var filled = claims
            while let claim = try await sender.claim(on: app.db) { filled.append(claim) }
            #expect(filled.count == 4)
            #expect(Set(filled.map(\.deliveryID)).count == 4)
            #expect(try await WebhookDelivery.query(on: app.db).filter(\.$state == .inFlight).count() == 4)
            let first = try #require(filled.first)
            try await sender.finish(first, outcome: .acknowledged, status: 202, on: app.db)
            #expect(try await sender.claim(on: app.db) != nil)
            #expect(try await WebhookDeliveryEntry.query(on: app.db).filter(\.$attemptID == first.id).count() == 2)
        }
    }

    @Test("HTTP I/O holds no row locks and retries preserve bytes with fresh attempt identity")
    func webhookWorkerSendAndRetry() async throws {
        try await withApp { app in
            let fixture = try await webhookDeliveryFixture(app)
            let clock = fixture.clock, sender = fixture.sender
            let first = try #require(try await sender.claim(on: app.db))
            let captures = NIOLockedValueBox([(Data, HTTPHeaders)]())
            try await sender.send(first, on: app.db) { _, body, headers in
                // A second connection can lock both rows while HTTP is in progress.
                try await app.db.transaction { db in
                    try await db.requireSQL().raw("SELECT id FROM webhook_subscriptions WHERE id = \(bind: first.subscriptionID) FOR UPDATE NOWAIT").run()
                    try await db.requireSQL().raw("SELECT id FROM webhook_deliveries WHERE id = \(bind: first.deliveryID) FOR UPDATE NOWAIT").run()
                }
                captures.withLockedValue { $0.append((body, headers)) }
                return .init(status: 503, retryAfter: "5")
            }
            #expect(try await WebhookDelivery.find(first.deliveryID, on: app.db)?.state == .retrying)
            clock.withLockedValue { $0 = $0.addingTimeInterval(10) }
            let retry = try #require(try await sender.claim(on: app.db))
            #expect(retry.id != first.id && retry.eventID == first.eventID && retry.body == first.body)
            try await sender.send(retry, on: app.db) { _, body, headers in
                captures.withLockedValue { $0.append((body, headers)) }
                return .init(status: 202, retryAfter: nil)
            }
            let requests = captures.withLockedValue { $0 }
            #expect(requests.count == 2 && requests[0].0 == requests[1].0)
            #expect(requests[0].1.first(name: "webhook-id") == requests[1].1.first(name: "webhook-id"))
            #expect(requests[0].1.first(name: "webhook-timestamp") != requests[1].1.first(name: "webhook-timestamp"))
            #expect(requests[0].1.first(name: "webhook-signature") != requests[1].1.first(name: "webhook-signature"))
            #expect(requests.allSatisfy { $0.1.first(name: "Authorization") == nil && $0.1.first(name: "Cookie") == nil })
            #expect(try await WebhookDelivery.find(first.deliveryID, on: app.db)?.state == .acknowledged)
            #expect(try await WebhookSubscription.find(first.subscriptionID, on: app.db)?.failingSince == nil)
        }
    }

    @Test("Expired starts become immutable unknown results and late owners are fenced")
    func webhookWorkerRecovery() async throws {
        try await withApp { app in
            let fixture = try await webhookDeliveryFixture(app)
            let sender = fixture.sender
            let first = try #require(try await sender.claim(on: app.db))
            fixture.clock.withLockedValue { $0 = $0.addingTimeInterval(61) }
            try await sender.finish(first, outcome: .acknowledged, status: 200, on: app.db)
            #expect(try await WebhookDeliveryEntry.query(on: app.db).filter(\.$kind == .result).count() == 0)
            #expect(try await sender.claim(on: app.db) == nil) // Recovery, without sending.
            let unknown = try #require(try await WebhookDeliveryEntry.query(on: app.db).filter(\.$kind == .result).first())
            #expect(unknown.outcome == .unknown && unknown.httpStatus == nil)
            fixture.clock.withLockedValue { $0 = $0.addingTimeInterval(10) }
            let replacement = try #require(try await sender.claim(on: app.db))
            #expect(replacement.eventID == first.eventID && replacement.body == first.body && replacement.id != first.id)
            try await sender.finish(first, outcome: .acknowledged, status: 200, on: app.db)
            #expect(try await WebhookDelivery.find(first.deliveryID, on: app.db)?.leaseToken == replacement.id)
            #expect(try await WebhookDeliveryEntry.query(on: app.db).filter(\.$attemptID == first.id).count() == 2)
        }
    }

    @Test("Full-window failure auto-pauses and cancels queued work; downtime before first attempt is free")
    func webhookWorkerPause() async throws {
        try await withApp { app in
            let fixture = try await webhookDeliveryFixture(app, events: 2)
            fixture.clock.withLockedValue { $0 = $0.addingTimeInterval(10 * 24 * 3600) }
            let first = try #require(try await fixture.sender.claim(on: app.db))
            try await fixture.sender.finish(first, outcome: .exhausted, status: 400, on: app.db)
            #expect(try await WebhookSubscription.find(first.subscriptionID, on: app.db)?.disabledReason == nil)
            fixture.clock.withLockedValue { $0 = $0.addingTimeInterval(WebhookRetryPolicy.window) }
            let next = try #require(try await fixture.sender.claim(on: app.db))
            try await fixture.sender.finish(next, outcome: .retryable, status: 503, on: app.db)
            let subscription = try #require(try await WebhookSubscription.find(first.subscriptionID, on: app.db))
            #expect(subscription.disabledReason == .autoPaused && subscription.disabledActorType == .system)
            #expect(subscription.disabledActorName == "webhook-worker")
            #expect(try await WebhookDelivery.find(next.deliveryID, on: app.db)?.state == .cancelled)
            #expect(try await WebhookDeliveryEntry.query(on: app.db).filter(\.$kind == .cancellation).first()?.reason == "subscription_auto_paused")
            let health = try await webhookRequest(app, .GET, "webhook-subscriptions/\(first.subscriptionID)/health", tenant: fixture.tenant)
            let state = try health.content.decode(WebhookHealthDTO.self)
            #expect(state.needsAttention && state.disabledReason == .autoPaused && state.failingSince != nil)
            let enabled = try await webhookRequest(app, .PATCH, "webhook-subscriptions/\(first.subscriptionID)", tenant: fixture.tenant,
                body: PatchWebhookSubscriptionDTO(expectedRevisionId: subscription.currentRevisionID, enabled: true))
            let reenabled = try enabled.content.decode(WebhookSubscriptionDTO.self)
            #expect(reenabled.enabled && reenabled.failingSince == nil && reenabled.disabledReason == nil)
            #expect(try await WebhookDelivery.find(next.deliveryID, on: app.db)?.state == .cancelled)
        }
    }
}

struct WebhookDeliveryTestFixture: Sendable {
    let tenant: WebhookTestTenant
    let subscription: WebhookSubscriptionDTO
    let sender: WebhookSender
    let clock: NIOLockedValueBox<Date>
}

func webhookDeliveryFixture(_ app: Application, events: Int = 1, code: String = "WORKER") async throws -> WebhookDeliveryTestFixture {
    let tenant = try await webhookTenant(app, code: code)
    let created = try await webhookRequest(app, .POST, "webhook-subscriptions", tenant: tenant,
        body: CreateWebhookSubscriptionDTO(name: "Worker", url: "https://receiver.example/events", eventTypes: [.groupCreated], companyIds: []))
    let subscription = try created.content.decode(WebhookSubscriptionDTO.self)
    let enabled = try await webhookRequest(app, .PATCH, "webhook-subscriptions/\(subscription.id)", tenant: tenant,
        body: PatchWebhookSubscriptionDTO(expectedRevisionId: subscription.currentRevisionId, enabled: true))
    let current = try enabled.content.decode(WebhookSubscriptionDTO.self)
    for _ in 0..<events { _ = try await emitGroupFixture(app.db, organizationID: tenant.organizationID) }
    _ = try await WebhookDispatcher.dispatchBatch(on: app.db)
    let clock = NIOLockedValueBox(Date())
    let settings = try WebhookWorkerSettings { _ in nil }
    let sender = WebhookSender(settings: settings, key: try WebhookEncryptionKey.load(), now: { clock.withLockedValue { $0 } }, jitter: { 1 })
    return .init(tenant: tenant, subscription: current, sender: sender, clock: clock)
}
