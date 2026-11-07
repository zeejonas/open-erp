@testable import open_erp
import Fluent
import SQLKit
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Snapshot dispatch rejects late commits with earlier transaction timestamps")
    func webhookDispatchVisibility() async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "SNAP", name: "Snapshot").requireID()
            let began = WebhookTestSignal(), release = WebhookTestSignal()
            async let late = app.db.auditedTransaction(AuditContext(actorType: .system)) { db in
                await began.signal()
                await release.wait()
                return try await webhookSubscriptionFixture(db, organizationID: orgID, enabled: true)
            }
            await began.wait()
            let event = try await emitGroupFixture(app.db, organizationID: orgID)
            await release.signal()
            let (_, revision) = try await late
            #expect(revision.createdAt <= event.createdAt)
            #expect(try await WebhookDispatcher.dispatchBatch(on: app.db) == 1)
            #expect(try await WebhookDelivery.query(on: app.db).count() == 0)
            _ = try await emitGroupFixture(app.db, organizationID: orgID)
            #expect(try await WebhookDispatcher.dispatchBatch(on: app.db) == 1)
            #expect(try await WebhookDelivery.query(on: app.db).count() == 1)
        }
    }

    @Test("Same transaction capture order excludes later revisions; latest visible version wins")
    func webhookDispatchSameTransaction() async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "ORDER", name: "Capture order").requireID()
            let (before, after, subscription, revision) = try await app.db.auditedTransaction(AuditContext(actorType: .system)) { db in
                let before = try await emitGroupFixture(db, organizationID: orgID)
                let (subscription, revision) = try await webhookSubscriptionFixture(db, organizationID: orgID, enabled: true)
                let after = try await emitGroupFixture(db, organizationID: orgID)
                return (before, after, subscription, revision)
            }
            #expect(try await WebhookDispatcher.dispatchBatch(on: app.db) == 2)
            let deliveries = try await WebhookDelivery.query(on: app.db).all()
            #expect(deliveries.map { $0.$event.id } == [try after.requireID()])
            #expect(!deliveries.contains { $0.$event.id == before.id })
            // The later-applied revision can have an earlier transaction timestamp.
            let newID = UUID(), subscriptionID = try subscription.requireID(), revisionID = try revision.requireID()
            try await app.db.auditedTransaction(AuditContext(actorType: .system)) { db in
                let sql = try db.requireSQL()
                try await sql.raw("""
                    INSERT INTO webhook_subscription_revisions
                        (id, organization_id, subscription_id, name, url, event_types, company_ids, enabled,
                         schema_version, version, secret_id, secret_ciphertext, created_at)
                    SELECT \(bind: newID), organization_id, subscription_id, name, url, event_types, company_ids, false,
                        schema_version, 2, secret_id, secret_ciphertext, created_at - interval '1 day'
                    FROM webhook_subscription_revisions WHERE id = \(bind: revisionID)
                    """).run()
                try await sql.raw("UPDATE webhook_subscriptions SET current_revision_id = \(bind: newID) WHERE id = \(bind: subscriptionID)").run()
            }
            _ = try await emitGroupFixture(app.db, organizationID: orgID)
            #expect(try await WebhookDispatcher.dispatchBatch(on: app.db) == 1)
            #expect(try await WebhookDelivery.query(on: app.db).count() == 1)
        }
    }

    @Test("Dispatch honors disable and company scopes and competing replicas stay idempotent")
    func webhookDispatchFanout() async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "FAN", name: "Fanout").requireID()
            let company = Company(code: "CO", name: "Company", organizationID: orgID, createdBy: nil, updatedBy: nil, deletedBy: nil)
            try await company.save(on: app.db)
            let companyID = try company.requireID()
            let (active, _) = try await webhookSubscriptionFixture(app.db, organizationID: orgID, enabled: true)
            let (disabled, _) = try await webhookSubscriptionFixture(app.db, organizationID: orgID, enabled: true)
            let (scoped, _) = try await webhookSubscriptionFixture(app.db, organizationID: orgID, enabled: true,
                eventTypes: [.companyCreated], companyIDs: [companyID])
            try await app.db.auditedTransaction(AuditContext(actorType: .system)) { db in
                try await company.emit(.companyCreated, on: db)
            }
            let event = try await emitGroupFixture(app.db, organizationID: orgID)
            try await app.db.requireSQL().raw("UPDATE webhook_subscriptions SET disabled_reason = 'emergency', disabled_at = now() WHERE id = \(bind: try disabled.requireID())").run()
            async let first = WebhookDispatcher.dispatchBatch(on: app.db, limit: 1)
            async let second = WebhookDispatcher.dispatchBatch(on: app.db, limit: 1)
            _ = try await (first, second)
            _ = try await WebhookDispatcher.dispatchBatch(on: app.db)
            let deliveries = try await WebhookDelivery.query(on: app.db).all()
            #expect(deliveries.count == 2)
            #expect(Set(deliveries.map { $0.$subscription.id }) == [try active.requireID(), try scoped.requireID()])
            #expect(try await BusinessEventDispatch.query(on: app.db).count() == 0)
            // Simulate a committed dispatch being offered again: database uniqueness is authoritative.
            try await app.db.requireSQL().raw("INSERT INTO business_event_dispatches (organization_id, event_id) VALUES (\(bind: orgID), \(bind: try event.requireID()))").run()
            #expect(try await WebhookDispatcher.dispatchBatch(on: app.db) == 1)
            #expect(try await WebhookDelivery.query(on: app.db).count() == 2)
        }
    }
}

func emitGroupFixture(_ db: any Database, organizationID: UUID) async throws -> BusinessEvent {
    try await db.auditedTransaction(AuditContext(actorType: .system)) { db in
        try await BusinessEventWriter.write(.groupCreated, resourceID: UUID(), organizationID: organizationID,
            data: .group(name: "Fixture", deleted: false), on: db)
    }
}

actor WebhookTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
