import Fluent
import Foundation
import SQLKit

enum WebhookRevocation {
    static func cancelQueued(subscriptionID: UUID, reason: WebhookCancellationReason, on db: any Database) async throws {
        let rows = try await db.requireSQL().raw("""
            SELECT id FROM webhook_deliveries WHERE subscription_id = \(bind: subscriptionID)
                AND state IN ('pending', 'retrying') ORDER BY id FOR UPDATE
            """).all()
        for row in rows {
            let id = try row.decode(column: "id", as: UUID.self)
            if let delivery = try await WebhookDelivery.find(id, on: db) { try await cancel(delivery, reason: reason, on: db) }
        }
    }

    static func cancelUnauthorized(subscription: WebhookSubscription, current: WebhookSubscriptionRevision, on db: any Database) async throws {
        let deliveries = try await WebhookDelivery.query(on: db).filter(\.$subscription.$id == subscription.requireID())
            .filter(\.$state ~~ [.pending, .retrying]).all()
        for delivery in deliveries {
            guard let event = try await BusinessEvent.find(delivery.$event.id, on: db),
                let pinned = try await WebhookSubscriptionRevision.find(delivery.$revision.id, on: db) else {
                throw BusinessEventWriter.InvalidTransaction()
            }
            if subscription.disabledReason != nil || !current.enabled || pinned.url != current.url || !current.covers(event) {
                try await cancel(delivery, reason: .authorityRevoked, on: db)
            }
        }
    }

    static func cancel(_ delivery: WebhookDelivery, reason: WebhookCancellationReason, on db: any Database) async throws {
        guard delivery.state == .pending || delivery.state == .retrying else { return }
        guard let event = try await BusinessEvent.find(delivery.$event.id, on: db) else { throw BusinessEventWriter.InvalidTransaction() }
        let now = try await WebhookSubscriptionService.transactionTime(on: db)
        let entry = WebhookDeliveryEntry()
        entry.$organization.id = delivery.$organization.id
        entry.$delivery.id = try delivery.requireID()
        entry.$revision.id = delivery.$revision.id
        entry.kind = .cancellation
        entry.payloadDigest = event.payloadDigest
        entry.reason = reason.rawValue
        entry.createdAt = now
        try await entry.create(on: db)
        delivery.state = .cancelled
        delivery.cancellationReason = reason
        delivery.leaseToken = nil
        delivery.leaseExpiresAt = nil
        try await delivery.update(on: db)
    }

    /// Caller holds the subscription row before taking any delivery locks.
    static func disable(_ subscription: WebhookSubscription, reason: WebhookDisabledReason,
        context: AuditContext, cancellation: WebhookCancellationReason, on db: any Database) async throws {
        subscription.disabledReason = reason
        subscription.disabledBy = context.actorID
        subscription.disabledActorType = context.actorType
        subscription.disabledActorName = context.actorName
        subscription.disabledAt = try await WebhookSubscriptionService.transactionTime(on: db)
        subscription.updatedAt = subscription.disabledAt!
        subscription.updatedBy = context.actorID
        try await subscription.update(on: db)
        try await cancelQueued(subscriptionID: subscription.requireID(), reason: cancellation, on: db)
    }

    static func disableOrganization(_ id: UUID, on db: any Database) async throws {
        _ = try await lockOrganization(id, on: db)
        guard let row = try await db.requireSQL().raw("SELECT NULLIF(current_setting('audit.context', true), '') AS context").first(),
            let json = try row.decode(column: "context", as: String?.self) else { throw BusinessEventWriter.InvalidTransaction() }
        let context = try JSONDecoder().decode(AuditContext.self, from: Data(json.utf8))
        let subscriptions = try await WebhookSubscription.query(on: db).filter(\.$organization.$id == id).sort(\.$id).all()
        for subscription in subscriptions {
            let (locked, _) = try await WebhookSubscriptionService.require(subscription.requireID(), organizationID: id, lock: true, on: db)
            try await disable(locked, reason: .emergency, context: context,
                cancellation: .organizationDeleted, on: db)
        }
    }
}
