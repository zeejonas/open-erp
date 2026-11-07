import Fluent
import Foundation

enum WebhookDisabledReason: String, Codable, Sendable {
    case emergency
    case autoPaused = "auto_paused"
}

final class WebhookSubscription: Model, @unchecked Sendable {
    static let schema = "webhook_subscriptions"
    @ID(key: .id) var id: UUID?
    @Parent(key: "organization_id") var organization: Organization
    @Field(key: "current_revision_id") var currentRevisionID: UUID
    @OptionalField(key: "disabled_reason") var disabledReason: WebhookDisabledReason?
    @OptionalField(key: "disabled_by") var disabledBy: UUID?
    @OptionalField(key: "disabled_actor_type") var disabledActorType: AuditActorType?
    @OptionalField(key: "disabled_actor_name") var disabledActorName: String?
    @OptionalField(key: "disabled_at") var disabledAt: Date?
    @OptionalField(key: "failing_since") var failingSince: Date?
    @OptionalField(key: "created_by") var createdBy: UUID?
    @OptionalField(key: "updated_by") var updatedBy: UUID?
    @OptionalField(key: "deleted_by") var deletedBy: UUID?
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?
    init() {}
}

final class WebhookSubscriptionRevision: Model, @unchecked Sendable {
    static let schema = "webhook_subscription_revisions"
    @ID(key: .id) var id: UUID?
    @Parent(key: "organization_id") var organization: Organization
    @Parent(key: "subscription_id") var subscription: WebhookSubscription
    @Field(key: "name") var name: String
    @Field(key: "url") var url: String
    @Field(key: "event_types") var eventTypes: [BusinessEventType]
    @Field(key: "company_ids") var companyIDs: [UUID]
    @Field(key: "enabled") var enabled: Bool
    @Field(key: "schema_version") var schemaVersion: Int
    @Field(key: "version") var version: Int
    @Field(key: "transaction_id") var transactionID: Int64
    @Field(key: "capture_order") var captureOrder: Int64
    @Field(key: "secret_id") var secretID: UUID
    @Field(key: "secret_ciphertext") var secretCiphertext: Data
    @OptionalField(key: "created_by") var createdBy: UUID?
    @OptionalField(key: "approval_request_id") var approvalRequestID: UUID?
    @Field(key: "created_at") var createdAt: Date
    init() {}

    func covers(_ event: BusinessEvent) -> Bool {
        eventTypes.contains(event.type) && (companyIDs.isEmpty || event.companyID.map(companyIDs.contains) == true)
    }
}

final class WebhookSecretReveal: Model, @unchecked Sendable {
    static let schema = "webhook_secret_reveals"
    @ID(key: .id) var id: UUID?
    @Parent(key: "organization_id") var organization: Organization
    @Parent(key: "subscription_id") var subscription: WebhookSubscription
    @Parent(key: "revision_id") var revision: WebhookSubscriptionRevision
    @Field(key: "secret_id") var secretID: UUID
    @Field(key: "actor_id") var actorID: UUID
    @Field(key: "request_id") var requestID: String
    @Field(key: "created_at") var createdAt: Date
    init() {}
}
