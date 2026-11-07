@testable import open_erp
import Fluent
import SQLKit
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Subscription history is tenant-bound, immutable, and redacted in audit")
    func webhookSubscriptionSchema() async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "SUB", name: "Subscriptions").requireID()
            let otherID = try await createOrganization(on: app.db, code: "OUT", name: "Other").requireID()
            let userID = try await createUser(on: app.db, email: "integrator@example.com").requireID()
            let (subscription, revision) = try await webhookSubscriptionFixture(app.db, organizationID: orgID)
            let subscriptionID = try subscription.requireID()
            let revisionID = try revision.requireID()
            let sql = try app.db.requireSQL()
            let audit = try #require(try await AuditEvent.query(on: app.db).filter(\.$recordID == revisionID).first())
            #expect(audit.changedFields.contains("secret_ciphertext"))
            #expect(audit.newValues?.values["secret_ciphertext"] == nil)
            #expect(audit.newValues?.values["secret_id"] != nil)
            try await expectForeignKeyViolation {
                try await sql.raw("INSERT INTO webhook_subscription_revisions (id, organization_id, subscription_id, name, url, event_types, company_ids, enabled, schema_version, version, secret_id, secret_ciphertext) SELECT gen_random_uuid(), \(bind: otherID), subscription_id, name, url, event_types, company_ids, enabled, schema_version, version + 1, secret_id, secret_ciphertext FROM webhook_subscription_revisions WHERE id = \(bind: revisionID)").run()
            }
            try await expectForeignKeyViolation {
                try await sql.raw("INSERT INTO webhook_secret_reveals (organization_id, subscription_id, revision_id, secret_id, actor_id, request_id) VALUES (\(bind: orgID), \(bind: subscriptionID), \(bind: revisionID), \(bind: UUID()), \(bind: userID), 'reveal')").run()
            }
            try await sql.raw("INSERT INTO webhook_secret_reveals (organization_id, subscription_id, revision_id, secret_id, actor_id, request_id) VALUES (\(bind: orgID), \(bind: subscriptionID), \(bind: revisionID), \(bind: revision.secretID), \(bind: userID), 'reveal')").run()
            let runtime = try webhookRuntimeDatabase(app)
            for table in [WebhookSubscriptionRevision.schema, WebhookSecretReveal.schema] {
                for statement: SQLQueryString in [
                    "UPDATE \(ident: table) SET id = id", "DELETE FROM \(ident: table)", "TRUNCATE \(ident: table) CASCADE",
                ] {
                    await #expect(throws: (any Error).self) { try await runtime.requireSQL().raw(statement).run() }
                }
            }
            let (_, otherRevision) = try await webhookSubscriptionFixture(app.db, organizationID: otherID)
            try await expectForeignKeyViolation {
                try await app.db.transaction { db in
                    try await db.requireSQL().raw("UPDATE webhook_subscriptions SET current_revision_id = \(bind: try otherRevision.requireID()) WHERE id = \(bind: subscriptionID)").run()
                }
            }
            #expect(try await auditCoverageProblems(on: app.db) == [])
        }
    }

    @Test("Delivery uniqueness, pinned ownership and immutable attempt entries are enforced")
    func webhookDeliverySchema() async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "DEL", name: "Deliveries").requireID()
            let (subscription, revision) = try await webhookSubscriptionFixture(app.db, organizationID: orgID)
            let (otherSubscription, _) = try await webhookSubscriptionFixture(app.db, organizationID: orgID)
            let event = try await app.db.auditedTransaction(AuditContext(actorType: .system)) { db in
                try await BusinessEventWriter.write(.groupCreated, resourceID: UUID(), organizationID: orgID,
                    data: .group(name: "Group", deleted: false), on: db)
            }
            let subscriptionID = try subscription.requireID(), revisionID = try revision.requireID(), eventID = try event.requireID()
            let sql = try app.db.requireSQL()
            let delivery = try #require(try await sql.raw("INSERT INTO webhook_deliveries (organization_id, event_id, subscription_id, revision_id, state, next_attempt_at, attempt_count) VALUES (\(bind: orgID), \(bind: eventID), \(bind: subscriptionID), \(bind: revisionID), 'pending', now(), 0) RETURNING id").first())
            let deliveryID = try delivery.decode(column: "id", as: UUID.self)
            await #expect(throws: (any Error).self) {
                try await sql.raw("INSERT INTO webhook_deliveries (organization_id, event_id, subscription_id, revision_id, state, next_attempt_at, attempt_count) VALUES (\(bind: orgID), \(bind: eventID), \(bind: subscriptionID), \(bind: revisionID), 'pending', now(), 0)").run()
            }
            try await expectForeignKeyViolation {
                try await sql.raw("INSERT INTO webhook_deliveries (organization_id, event_id, subscription_id, revision_id, state, next_attempt_at, attempt_count) VALUES (\(bind: orgID), \(bind: eventID), \(bind: try otherSubscription.requireID()), \(bind: revisionID), 'pending', now(), 0)").run()
            }
            let attemptID = UUID()
            for kind in ["started", "result"] {
                let insert: SQLQueryString = """
                    INSERT INTO webhook_delivery_entries
                        (organization_id, delivery_id, revision_id, kind, attempt_id, secret_id, payload_digest,
                         started_at, finished_at, outcome)
                    VALUES (\(bind: orgID), \(bind: deliveryID), \(bind: revisionID), \(bind: kind), \(bind: attemptID),
                        \(bind: revision.secretID), \(bind: event.payloadDigest), transaction_timestamp(),
                        CASE WHEN \(bind: kind) = 'result' THEN transaction_timestamp() END,
                        CASE WHEN \(bind: kind) = 'result' THEN 'unknown' ELSE 'started' END)
                    """
                try await sql.raw(insert).run()
                await #expect(throws: (any Error).self) { try await sql.raw(insert).run() }
            }
            let runtime = try webhookRuntimeDatabase(app)
            for statement: SQLQueryString in [
                "UPDATE webhook_delivery_entries SET outcome = 'acknowledged'",
                "DELETE FROM webhook_delivery_entries", "TRUNCATE webhook_delivery_entries",
            ] {
                await #expect(throws: (any Error).self) { try await runtime.requireSQL().raw(statement).run() }
            }
            #expect(try await WebhookDeliveryEntry.query(on: app.db).count() == 2)
            try await sql.raw("UPDATE webhook_deliveries SET next_attempt_at = now() + interval '1 hour' WHERE id = \(bind: deliveryID)").run()
            #expect(try await AuditEvent.query(on: app.db).filter(\.$recordID == deliveryID).count() == 1)
            #expect(try await auditCoverageProblems(on: app.db) == [])
            let indexes = try await sql.raw("SELECT indexdef FROM pg_indexes WHERE tablename = 'webhook_deliveries' AND indexname IN ('webhook_deliveries_due', 'webhook_deliveries_leases')").all()
            #expect(indexes.count == 2)
            #expect(try indexes.allSatisfy { try $0.decode(column: "indexdef", as: String.self).contains("WHERE") })
        }
    }

    @Test("Audit verification rejects extra queue capture and update capture on deliveries")
    func webhookQueueAuditScope() async throws {
        try await withApp { app in
            let sql = try app.db.requireSQL()
            #expect(try await auditCoverageProblems(on: app.db) == [])
            try await app.db.createChangeTrigger(on: BusinessEventDispatch.schema)
            #expect(try await auditCoverageProblems(on: app.db).contains { $0.contains(BusinessEventDispatch.schema) })
            try await sql.raw("DROP TRIGGER capture_audit_change ON business_event_dispatches").run()
            try await sql.raw("DROP TRIGGER capture_audit_change ON webhook_deliveries").run()
            try await app.db.createChangeTrigger(on: WebhookDelivery.schema)
            #expect(try await auditCoverageProblems(on: app.db).contains { $0.contains(WebhookDelivery.schema) })
            try await sql.raw("DROP TRIGGER capture_audit_change ON webhook_deliveries").run()
            try await app.db.createChangeTrigger(on: WebhookDelivery.schema, operations: [.insert, .delete])
            #expect(try await auditCoverageProblems(on: app.db) == [])
        }
    }

    @Test("The event writer needs no subscription read grants")
    func businessEventWriterIndependentOfSubscriptions() async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "OUTBOX", name: "Outbox").requireID()
            let sql = try app.db.requireSQL()
            let runtime = try webhookRuntimeDatabase(app)
            try await sql.raw("REVOKE SELECT ON webhook_subscriptions, webhook_subscription_revisions FROM open_erp_runtime").run()
            // withApp reverts these tables even when the assertion fails, restoring grants on recreation.
            let event = try await runtime.auditedTransaction(AuditContext(actorType: .system)) { db in
                try await BusinessEventWriter.write(.groupCreated, resourceID: UUID(), organizationID: orgID,
                    data: .group(name: "No subscribers needed", deleted: false), on: db)
            }
            #expect(try await BusinessEvent.find(try event.requireID(), on: app.db) != nil)
            #expect(try await WebhookDelivery.query(on: app.db).count() == 0)
        }
    }
}

func webhookSubscriptionFixture(
    _ db: any Database, organizationID: UUID, enabled: Bool = false,
    eventTypes: [BusinessEventType] = [.groupCreated], companyIDs: [UUID] = []
) async throws -> (WebhookSubscription, WebhookSubscriptionRevision) {
    try await db.auditedTransaction(AuditContext(actorType: .system)) { db in
        let id = UUID(), revisionID = UUID()
        let subscription = WebhookSubscription()
        subscription.id = id
        subscription.$organization.id = organizationID
        subscription.currentRevisionID = revisionID
        subscription.createdAt = Date()
        subscription.updatedAt = Date()
        try await subscription.create(on: db)
        let revision = WebhookSubscriptionRevision()
        revision.id = revisionID
        revision.$organization.id = organizationID
        revision.$subscription.id = id
        revision.name = "Fixture"
        revision.url = "https://receiver.example/webhooks"
        revision.eventTypes = eventTypes
        revision.companyIDs = companyIDs
        revision.enabled = enabled
        revision.schemaVersion = 1
        revision.version = 1
        let metadata = try #require(try await db.requireSQL().raw("SELECT txid_current() AS transaction_id, nextval('webhook_capture_order') AS capture_order, transaction_timestamp() AS created_at").first())
        revision.transactionID = try metadata.decode(column: "transaction_id", as: Int64.self)
        revision.captureOrder = try metadata.decode(column: "capture_order", as: Int64.self)
        revision.secretID = UUID()
        revision.secretCiphertext = Data("ciphertext-fixture".utf8)
        revision.createdAt = try metadata.decode(column: "created_at", as: Date.self)
        try await revision.create(on: db)
        return (subscription, revision)
    }
}
