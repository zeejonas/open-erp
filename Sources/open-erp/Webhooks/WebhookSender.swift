import Fluent
import Foundation
import SQLKit
import Vapor

struct ClaimedWebhookAttempt: Sendable {
    let id: UUID
    let deliveryID: UUID
    let organizationID: UUID
    let subscriptionID: UUID
    let revisionID: UUID
    let secretID: UUID
    let eventID: UUID
    let url: String
    let body: Data
    let digest: String
    let secretCiphertext: Data
    let startedAt: Date
}

struct WebhookSender: Sendable {
    let settings: WebhookWorkerSettings
    let key: WebhookEncryptionKey
    var now: @Sendable () -> Date = Date.init
    var jitter: @Sendable () -> Double = { Double.random(in: 0...1) }

    /// All claim paths take the subscription lock first; no lock survives this method.
    func claim(on db: any Database, afterOrganizationID: UUID? = nil) async throws -> ClaimedWebhookAttempt? {
        let time = now()
        return try await db.auditedTransaction(Self.context) { db in
            let sql = try db.requireSQL()
            let candidate = try await sql.raw("""
                SELECT subscription.id, subscription.organization_id
                FROM webhook_subscriptions AS subscription
                WHERE EXISTS (
                    SELECT FROM webhook_deliveries AS delivery WHERE delivery.subscription_id = subscription.id
                        AND ((delivery.state IN ('pending', 'retrying') AND delivery.next_attempt_at <= \(bind: time))
                            OR (delivery.state = 'in_flight' AND delivery.lease_expires_at <= \(bind: time)))
                ) AND (SELECT count(*) FROM webhook_deliveries AS lease
                    WHERE lease.subscription_id = subscription.id AND lease.state = 'in_flight'
                        AND lease.lease_expires_at > \(bind: time)) < \(bind: settings.perSubscription)
                  AND (SELECT count(*) FROM webhook_deliveries AS lease
                    WHERE lease.organization_id = subscription.organization_id AND lease.state = 'in_flight'
                        AND lease.lease_expires_at > \(bind: time)) < \(bind: settings.perOrganization)
                ORDER BY (subscription.organization_id > \(bind: afterOrganizationID ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))) DESC,
                    subscription.organization_id, subscription.id
                LIMIT 1 FOR NO KEY UPDATE OF subscription SKIP LOCKED
                """).first()
            guard let candidate else { return nil }
            let subscriptionID = try candidate.decode(column: "id", as: UUID.self)
            guard let subscription = try await WebhookSubscription.query(on: db).withDeleted().filter(\.$id == subscriptionID).first(),
                let current = try await WebhookSubscriptionRevision.find(subscription.currentRevisionID, on: db) else {
                throw BusinessEventWriter.InvalidTransaction()
            }
            let activeSubscriptionLeases = try await WebhookDelivery.query(on: db).filter(\.$subscription.$id == subscriptionID)
                .filter(\.$state == .inFlight).filter(\.$leaseExpiresAt > time).count()
            let activeOrganizationLeases = try await WebhookDelivery.query(on: db).filter(\.$organization.$id == subscription.$organization.id)
                .filter(\.$state == .inFlight).filter(\.$leaseExpiresAt > time).count()
            guard activeSubscriptionLeases < settings.perSubscription, activeOrganizationLeases < settings.perOrganization else { return nil }
            let row = try await sql.raw("""
                SELECT id FROM webhook_deliveries WHERE subscription_id = \(bind: subscriptionID)
                    AND ((state IN ('pending', 'retrying') AND next_attempt_at <= \(bind: time))
                        OR (state = 'in_flight' AND lease_expires_at <= \(bind: time)))
                ORDER BY next_attempt_at, id LIMIT 1 FOR UPDATE SKIP LOCKED
                """).first()
            guard let row, let delivery = try await WebhookDelivery.find(row.decode(column: "id", as: UUID.self), on: db),
                let event = try await BusinessEvent.find(delivery.$event.id, on: db),
                let pinned = try await WebhookSubscriptionRevision.find(delivery.$revision.id, on: db) else { return nil }
            if delivery.state == .inFlight {
                try await recover(delivery, subscription: subscription, current: current, event: event, at: time, on: db)
                return nil
            }
            guard try await authorized(subscription: subscription, current: current, pinned: pinned, event: event, on: db) else {
                try await WebhookRevocation.cancel(delivery, reason: .authorityRevoked, on: db)
                return nil
            }
            let attemptID = UUID()
            delivery.state = .inFlight
            delivery.leaseToken = attemptID
            delivery.leaseExpiresAt = time.addingTimeInterval(WebhookRetryPolicy.lease)
            delivery.firstAttemptAt = delivery.firstAttemptAt ?? time
            delivery.attemptCount += 1
            try await delivery.update(on: db)
            let entry = Self.entry(delivery, event: event, attemptID: attemptID, secretID: current.secretID, startedAt: time, at: time)
            entry.kind = .started
            entry.outcome = .started
            try await entry.create(on: db)
            if let first = delivery.firstAttemptAt, time >= first.addingTimeInterval(WebhookRetryPolicy.window) {
                try await recordResult(delivery, subscription: subscription, current: current, event: event, attemptID: attemptID,
                    secretID: current.secretID, startedAt: time, at: time, outcome: .exhausted, status: nil,
                    retryAfter: nil, reason: "retry_window_exhausted", on: db)
                return nil
            }
            return try ClaimedWebhookAttempt(id: attemptID, deliveryID: delivery.requireID(), organizationID: event.$organization.id,
                subscriptionID: subscriptionID, revisionID: pinned.requireID(), secretID: current.secretID, eventID: event.requireID(),
                url: pinned.url, body: event.payload, digest: event.payloadDigest, secretCiphertext: current.secretCiphertext, startedAt: time)
        }
    }

    /// The supplied transport runs after claim commit. Only fresh, outbound headers are constructed here.
    func send(_ attempt: ClaimedWebhookAttempt, on db: any Database,
        transport: @Sendable (String, Data, HTTPHeaders) async throws -> WebhookHTTPResult
    ) async throws {
        let outcome: WebhookAttemptOutcome
        let status: Int?
        let retryAfter: String?
        let reason: String?
        let cancellation: WebhookCancellationReason?
        do {
            let secret = try key.decrypt(attempt.secretCiphertext, organizationID: attempt.organizationID,
                subscriptionID: attempt.subscriptionID, secretID: attempt.secretID)
            let timestamp = Int64(now().timeIntervalSince1970)
            let headers: HTTPHeaders = [
                "Content-Type": "application/json", "webhook-id": attempt.eventID.uuidString,
                "webhook-timestamp": String(timestamp), "X-OpenERP-Attempt-ID": attempt.id.uuidString,
                "webhook-signature": secret.signature(eventID: attempt.eventID.uuidString, timestamp: timestamp, body: attempt.body),
            ]
            let result = try await transport(attempt.url, attempt.body, headers)
            outcome = WebhookRetryPolicy.outcome(status: result.status)
            status = result.status
            retryAfter = result.retryAfter
            reason = nil
            cancellation = nil
        } catch is CancellationError {
            // Shutdown leaves started evidence and a lease; recovery records unknown, never a fabricated rejection.
            throw CancellationError()
        } catch let error as WebhookTransportError where error == .unsafeDestination {
            outcome = .exhausted
            status = nil
            retryAfter = nil
            reason = "unsafe_destination"
            cancellation = .unsafeDestination
        } catch {
            outcome = .retryable
            status = nil
            retryAfter = nil
            reason = "network"
            cancellation = nil
        }
        // Persistence failures leave the lease ambiguous for recovery; they are never reclassified as network failures.
        try await finish(attempt, outcome: outcome, status: status, retryAfter: retryAfter, reason: reason, cancel: cancellation, on: db)
    }

    /// A late owner cannot append a result or alter scheduling, even if nobody has reclaimed yet.
    func finish(_ attempt: ClaimedWebhookAttempt, outcome: WebhookAttemptOutcome, status: Int? = nil,
        retryAfter: String? = nil, reason: String? = nil, cancel: WebhookCancellationReason? = nil, on db: any Database
    ) async throws {
        let time = now()
        try await db.auditedTransaction(Self.context) { db in
            _ = try await db.requireSQL().raw("SELECT id FROM webhook_subscriptions WHERE id = \(bind: attempt.subscriptionID) FOR NO KEY UPDATE").all()
            _ = try await db.requireSQL().raw("SELECT id FROM webhook_deliveries WHERE id = \(bind: attempt.deliveryID) FOR UPDATE").all()
            guard let delivery = try await WebhookDelivery.find(attempt.deliveryID, on: db), delivery.state == .inFlight,
                delivery.leaseToken == attempt.id, let expires = delivery.leaseExpiresAt, expires > time,
                let subscription = try await WebhookSubscription.query(on: db).withDeleted().filter(\.$id == attempt.subscriptionID).first(),
                let current = try await WebhookSubscriptionRevision.find(subscription.currentRevisionID, on: db),
                let event = try await BusinessEvent.find(attempt.eventID, on: db) else { return }
            try await recordResult(delivery, subscription: subscription, current: current, event: event, attemptID: attempt.id,
                secretID: attempt.secretID, startedAt: attempt.startedAt, at: time, outcome: outcome, status: status,
                retryAfter: retryAfter, reason: reason, cancel: cancel, on: db)
        }
    }

    private func recover(_ delivery: WebhookDelivery, subscription: WebhookSubscription, current: WebhookSubscriptionRevision,
        event: BusinessEvent, at time: Date, on db: any Database
    ) async throws {
        guard let attemptID = delivery.leaseToken, let start = try await WebhookDeliveryEntry.query(on: db)
            .filter(\.$delivery.$id == delivery.requireID()).filter(\.$attemptID == attemptID).filter(\.$kind == .started).first(),
            let startedAt = start.startedAt, let secretID = start.secretID else { throw BusinessEventWriter.InvalidTransaction() }
        try await recordResult(delivery, subscription: subscription, current: current, event: event, attemptID: attemptID,
            secretID: secretID, startedAt: startedAt, at: time, outcome: .unknown, status: nil, retryAfter: nil, reason: "lease_expired", on: db)
    }

    private func recordResult(_ delivery: WebhookDelivery, subscription: WebhookSubscription, current: WebhookSubscriptionRevision,
        event: BusinessEvent, attemptID: UUID, secretID: UUID, startedAt: Date, at time: Date, outcome: WebhookAttemptOutcome,
        status: Int?, retryAfter: String?, reason: String?, cancel: WebhookCancellationReason? = nil, on db: any Database
    ) async throws {
        var result = outcome
        var next: Date?
        if result == .retryable || result == .unknown {
            next = WebhookRetryPolicy.nextAttempt(count: delivery.attemptCount, firstAttempt: delivery.firstAttemptAt ?? startedAt,
                now: time, status: status, retryAfter: retryAfter, jitter: jitter())
            if next == nil && result != .unknown { result = .exhausted }
        }
        let entry = Self.entry(delivery, event: event, attemptID: attemptID, secretID: secretID, startedAt: startedAt, at: time)
        entry.kind = .result
        entry.outcome = result
        entry.finishedAt = time
        entry.httpStatus = status
        entry.reason = reason
        entry.nextAttemptAt = next
        try await entry.create(on: db)
        delivery.leaseToken = nil
        delivery.leaseExpiresAt = nil
        delivery.state = result == .acknowledged ? .acknowledged : next == nil ? .exhausted : .retrying
        if let next { delivery.nextAttemptAt = next }
        var cancellation = cancel
        if result != .acknowledged, let pinned = try await WebhookSubscriptionRevision.find(delivery.$revision.id, on: db),
            try await !authorized(subscription: subscription, current: current, pinned: pinned, event: event, on: db) {
            cancellation = cancellation ?? .authorityRevoked
        }
        if let cancellation {
            delivery.state = .retrying
            try await WebhookRevocation.cancel(delivery, reason: cancellation, on: db)
        } else {
            try await delivery.update(on: db)
        }
        if result == .acknowledged {
            if subscription.failingSince != nil {
                subscription.failingSince = nil
                try await subscription.update(on: db)
            }
        } else {
            if subscription.failingSince == nil {
                subscription.failingSince = startedAt
                try await subscription.update(on: db)
            }
            if let since = subscription.failingSince, time.timeIntervalSince(since) >= WebhookRetryPolicy.window, subscription.disabledReason == nil {
                try await WebhookRevocation.disable(subscription, reason: .autoPaused, context: Self.context,
                    cancellation: .subscriptionAutoPaused, on: db)
                db.logger.warning("Webhook subscription auto-paused", metadata: ["subscription_id": "\(subscription.id!)"])
            }
        }
        if delivery.state == .exhausted || cancellation == .unsafeDestination {
            db.logger.warning("Webhook delivery requires attention", metadata: ["delivery_id": "\(delivery.id!)", "state": "\(delivery.state.rawValue)"])
        }
    }

    private func authorized(subscription: WebhookSubscription, current: WebhookSubscriptionRevision,
        pinned: WebhookSubscriptionRevision, event: BusinessEvent, on db: any Database
    ) async throws -> Bool {
        guard subscription.deletedAt == nil, subscription.disabledReason == nil, current.enabled,
            current.url == pinned.url, current.covers(event) else { return false }
        return try await Organization.find(subscription.$organization.id, on: db) != nil
    }

    private static func entry(_ delivery: WebhookDelivery, event: BusinessEvent, attemptID: UUID, secretID: UUID,
        startedAt: Date, at time: Date
    ) -> WebhookDeliveryEntry {
        let entry = WebhookDeliveryEntry()
        entry.$organization.id = delivery.$organization.id
        entry.$delivery.id = delivery.id!
        entry.$revision.id = delivery.$revision.id
        entry.attemptID = attemptID
        entry.secretID = secretID
        entry.payloadDigest = event.payloadDigest
        entry.startedAt = startedAt
        entry.createdAt = time
        return entry
    }

    static let context = AuditContext(actorType: .system, actorName: "webhook-worker")
}
