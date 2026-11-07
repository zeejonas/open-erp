@testable import open_erp
import Crypto
import Fluent
import FluentPostgresDriver
import SQLKit
import SwiftOpenAPI
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Event and dispatch share the audited transaction, exact bytes and rollback")
    func businessEventAtomicity() async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "EV", name: "Events").requireID()
            let context = AuditContext(actorType: .system, actorName: "private-operator", requestID: "event-test")
            let resourceID = UUID()
            let event = try await app.db.auditedTransaction(context) { db in
                try await BusinessEventWriter.write(.groupCreated, resourceID: resourceID, organizationID: orgID,
                    data: .group(name: "Public group", deleted: false), on: db)
            }
            let id = try event.requireID()
            let stored = try #require(try await BusinessEvent.find(id, on: app.db))
            #expect(stored.payload == event.payload)
            #expect(stored.payloadDigest == SHA256.hash(data: stored.payload).map { String(format: "%02x", $0) }.joined())
            #expect(!String(decoding: stored.payload, as: UTF8.self).contains("private-operator"))
            let dispatch = try #require(try await BusinessEventDispatch.query(on: app.db).first())
            #expect(dispatch.$event.id == id)
            #expect(dispatch.createdAt == stored.createdAt)
            let audit = try #require(try await AuditEvent.query(on: app.db).filter(\.$recordID == id).first())
            #expect(audit.transactionID == stored.transactionID)
            #expect(audit.requestID == "event-test")
            #expect(audit.newValues?.values["payload"] == nil)
            #expect(audit.changedFields.contains("payload"))
            #expect(audit.newValues?.values["payload_digest"] == .string(stored.payloadDigest))
            #expect(try await AuditEvent.query(on: app.db).filter(\.$tableName == BusinessEventDispatch.schema).count() == 0)

            await #expect(throws: EventRollback.self) {
                try await app.db.auditedTransaction(context) { db in
                    try await db.requireSQL().raw("UPDATE organizations SET name = 'Uncommitted' WHERE id = \(bind: orgID)").run()
                    try await BusinessEventWriter.write(.groupUpdated, resourceID: resourceID, organizationID: orgID,
                        data: .group(name: "Uncommitted", deleted: false), on: db)
                    throw EventRollback()
                }
            }
            #expect(try await Organization.find(orgID, on: app.db)?.name == "Events")
            #expect(try await BusinessEvent.query(on: app.db).count() == 1)
            #expect(try await BusinessEventDispatch.query(on: app.db).count() == 1)
            let next = try await app.db.auditedTransaction(context) { db in
                try await BusinessEventWriter.write(.groupUpdated, resourceID: resourceID, organizationID: orgID,
                    data: .group(name: "Committed", deleted: false), on: db)
            }
            #expect(next.revision == 2)

            // An outbox insert failure must also roll back the event and revision allocation.
            let sql = try app.db.requireSQL()
            try await sql.raw("ALTER TABLE business_event_dispatches ADD CONSTRAINT test_reject_dispatch CHECK (false) NOT VALID").run()
            await #expect(throws: (any Error).self) {
                try await app.db.auditedTransaction(context) { db in
                    try await BusinessEventWriter.write(.groupUpdated, resourceID: resourceID, organizationID: orgID,
                        data: .group(name: "Cannot dispatch", deleted: false), on: db)
                }
            }
            try await sql.raw("ALTER TABLE business_event_dispatches DROP CONSTRAINT test_reject_dispatch").run()
            #expect(try await BusinessEvent.query(on: app.db).count() == 2)
            #expect(try await BusinessEventStream.query(on: app.db).first()?.revision == 2)
        }
    }

    @Test("Concurrent event streams allocate unique revisions without committed gaps")
    func businessEventRevisions() async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "REV", name: "Revisions").requireID()
            let resourceID = UUID()
            let revisions = try await withThrowingTaskGroup(of: Int64.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        try await app.db.auditedTransaction(AuditContext(actorType: .system)) { db in
                            try await BusinessEventWriter.write(.groupUpdated, resourceID: resourceID, organizationID: orgID,
                                data: .group(name: "Group", deleted: false), on: db).revision
                        }
                    }
                }
                var values: [Int64] = []
                for try await revision in group { values.append(revision) }
                return values.sorted()
            }
            #expect(revisions == Array(1...8))
            #expect(try await BusinessEventDispatch.query(on: app.db).count() == 8)
        }
    }

    @Test("Runtime cannot rewrite events or cross tenant dispatch references")
    func businessEventEvidence() async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "SAFE", name: "Evidence").requireID()
            let otherID = try await createOrganization(on: app.db, code: "OTHER", name: "Other").requireID()
            let runtime = try webhookRuntimeDatabase(app)
            let event = try await runtime.auditedTransaction(AuditContext(actorType: .system, actorName: "webhook-test")) { db in
                try await BusinessEventWriter.write(.groupCreated, resourceID: UUID(), organizationID: orgID,
                    data: .group(name: "Safe", deleted: false), on: db)
            }
            let id = try event.requireID()
            for statement: SQLQueryString in [
                "UPDATE business_events SET type = type WHERE id = \(bind: id)",
                "DELETE FROM business_events WHERE id = \(bind: id)",
                "TRUNCATE business_events CASCADE",
            ] {
                await #expect(throws: (any Error).self) {
                    try await runtime.auditedTransaction(AuditContext(actorType: .system)) { db in
                        try await db.requireSQL().raw(statement).run()
                    }
                }
            }
            try await expectForeignKeyViolation {
                try await app.db.requireSQL().raw("INSERT INTO business_event_dispatches (organization_id, event_id) VALUES (\(bind: otherID), \(bind: id))").run()
            }
            await #expect(throws: BusinessEventWriter.InvalidTransaction.self) {
                try await BusinessEventWriter.write(.groupCreated, resourceID: UUID(), organizationID: orgID,
                    data: .group(name: "Outside transaction", deleted: false), on: app.db)
            }
            #expect(try await auditCoverageProblems(on: app.db) == [])
        }
    }
}

private struct EventRollback: Error {}

func webhookRuntimeDatabase(_ app: Application) throws -> any Database {
    let settings = try DatabaseSettings(testing: true) { name in
        switch name {
        case "DATABASE_USERNAME": "open_erp_runtime"
        case "DATABASE_PASSWORD": Environment.get("AUDIT_TEST_RUNTIME_PASSWORD") ?? "open_erp_runtime_local"
        default: Environment.get(name)
        }
    }
    let id = DatabaseID(string: "webhook-runtime-test")
    app.databases.use(.postgres(configuration: try settings.postgresConfiguration()), as: id)
    return app.db(id)
}
