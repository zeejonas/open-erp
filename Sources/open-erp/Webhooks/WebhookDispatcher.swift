import Fluent
import Foundation
import SQLKit

enum WebhookDispatcher {
    /// Fan-out is deliberately outside business writes. A crash rolls back both deliveries and queue removal.
    @discardableResult
    static func dispatchBatch(on db: any Database, limit: Int = 100) async throws -> Int {
        precondition((1...1000).contains(limit))
        return try await db.auditedTransaction(AuditContext(actorType: .system, actorName: "webhook-worker")) { db in
            let sql = try db.requireSQL()
            let rows = try await sql.raw("""
                SELECT id, event_id FROM business_event_dispatches
                ORDER BY created_at, id LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
                """).all()
            for row in rows {
                let dispatchID = try row.decode(column: "id", as: UUID.self)
                let eventID = try row.decode(column: "event_id", as: UUID.self)
                guard let event = try await BusinessEvent.find(eventID, on: db) else { throw BusinessEventWriter.InvalidTransaction() }
                let candidates = try await sql.raw("""
                    SELECT selected.id FROM webhook_subscriptions AS subscription
                    JOIN organizations AS organization ON organization.id = subscription.organization_id
                    JOIN webhook_subscription_revisions AS current_revision ON current_revision.id = subscription.current_revision_id
                    CROSS JOIN LATERAL (
                        SELECT revision.id, revision.enabled, revision.event_types, revision.company_ids
                        FROM webhook_subscription_revisions AS revision
                        WHERE revision.organization_id = subscription.organization_id
                            AND revision.subscription_id = subscription.id
                            AND CASE WHEN revision.transaction_id = \(bind: event.transactionID)
                                THEN revision.capture_order < \(bind: event.captureOrder)
                                ELSE pg_visible_in_snapshot(revision.transaction_id::text::xid8, \(bind: event.captureSnapshot)::pg_snapshot)
                                END
                        ORDER BY revision.version DESC LIMIT 1
                    ) AS selected
                    WHERE subscription.organization_id = \(bind: event.$organization.id)
                        AND subscription.deleted_at IS NULL AND subscription.disabled_reason IS NULL
                        AND organization.deleted_at IS NULL AND current_revision.enabled AND selected.enabled
                        AND \(bind: event.type.rawValue) = ANY(selected.event_types)
                        AND (cardinality(selected.company_ids) = 0 OR \(bind: event.companyID) = ANY(selected.company_ids))
                    FOR NO KEY UPDATE OF subscription
                    """).all()
                for candidate in candidates {
                    let revisionID = try candidate.decode(column: "id", as: UUID.self)
                    guard let revision = try await WebhookSubscriptionRevision.find(revisionID, on: db) else {
                        throw BusinessEventWriter.InvalidTransaction()
                    }
                    try await sql.raw("""
                        INSERT INTO webhook_deliveries
                            (organization_id, event_id, subscription_id, revision_id, state, next_attempt_at, attempt_count)
                        VALUES (\(bind: event.$organization.id), \(bind: eventID), \(bind: revision.$subscription.id),
                            \(bind: revisionID), 'pending', transaction_timestamp(), 0)
                        ON CONFLICT (organization_id, event_id, subscription_id) DO NOTHING
                        """).run()
                }
                try await sql.raw("DELETE FROM business_event_dispatches WHERE id = \(bind: dispatchID)").run()
            }
            return rows.count
        }
    }
}
