import Fluent
import Foundation

enum WebhookDeliveryState: String, Codable, CaseIterable, Sendable {
    case pending, inFlight = "in_flight", retrying, acknowledged, exhausted, cancelled
}

enum WebhookEntryKind: String, Codable, Sendable { case started, result, cancellation }
enum WebhookAttemptOutcome: String, Codable, CaseIterable, Sendable {
    case started, acknowledged, retryable, exhausted, unknown
}
enum WebhookCancellationReason: String, Codable, Sendable {
    case subscriptionDisabled = "subscription_disabled"
    case subscriptionAutoPaused = "subscription_auto_paused"
    case subscriptionDeleted = "subscription_deleted"
    case authorityRevoked = "authority_revoked"
    case organizationDeleted = "organization_deleted"
    case unsafeDestination = "unsafe_destination"
}

final class WebhookDelivery: Model, @unchecked Sendable {
    static let schema = "webhook_deliveries"
    @ID(key: .id) var id: UUID?
    @Parent(key: "organization_id") var organization: Organization
    @Parent(key: "event_id") var event: BusinessEvent
    @Parent(key: "subscription_id") var subscription: WebhookSubscription
    @Parent(key: "revision_id") var revision: WebhookSubscriptionRevision
    @Field(key: "state") var state: WebhookDeliveryState
    @Field(key: "next_attempt_at") var nextAttemptAt: Date
    @OptionalField(key: "first_attempt_at") var firstAttemptAt: Date?
    @OptionalField(key: "lease_token") var leaseToken: UUID?
    @OptionalField(key: "lease_expires_at") var leaseExpiresAt: Date?
    @Field(key: "attempt_count") var attemptCount: Int
    @OptionalField(key: "cancellation_reason") var cancellationReason: WebhookCancellationReason?
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

final class WebhookDeliveryEntry: Model, @unchecked Sendable {
    static let schema = "webhook_delivery_entries"
    @ID(key: .id) var id: UUID?
    @Parent(key: "organization_id") var organization: Organization
    @Parent(key: "delivery_id") var delivery: WebhookDelivery
    @Parent(key: "revision_id") var revision: WebhookSubscriptionRevision
    @Field(key: "kind") var kind: WebhookEntryKind
    @OptionalField(key: "attempt_id") var attemptID: UUID?
    @OptionalField(key: "secret_id") var secretID: UUID?
    @Field(key: "payload_digest") var payloadDigest: String
    @OptionalField(key: "started_at") var startedAt: Date?
    @OptionalField(key: "finished_at") var finishedAt: Date?
    @OptionalField(key: "http_status") var httpStatus: Int?
    @OptionalField(key: "outcome") var outcome: WebhookAttemptOutcome?
    @OptionalField(key: "reason") var reason: String?
    @OptionalField(key: "next_attempt_at") var nextAttemptAt: Date?
    @Field(key: "created_at") var createdAt: Date
    init() {}
}
