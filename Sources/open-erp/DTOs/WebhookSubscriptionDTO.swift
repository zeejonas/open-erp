import Fluent
import Vapor

struct WebhookConfiguration: Content, Equatable {
    var name: String
    var url: String
    var eventTypes: [BusinessEventType]
    var companyIds: [UUID]
    var enabled: Bool

    func changedFields(from before: Self) -> Set<String> {
        var fields: Set<String> = []
        if name != before.name { fields.insert("name") }
        if url != before.url { fields.insert("url") }
        if Set(eventTypes) != Set(before.eventTypes) { fields.insert("eventTypes") }
        if Set(companyIds) != Set(before.companyIds) { fields.insert("companyIds") }
        if enabled != before.enabled { fields.insert("enabled") }
        return fields
    }

    func expandsAuthority(from before: Self) -> Bool {
        (!before.enabled && enabled) || !Set(eventTypes).isSubset(of: Set(before.eventTypes))
            || (!before.companyIds.isEmpty && (companyIds.isEmpty || !Set(companyIds).isSubset(of: Set(before.companyIds))))
    }
}

struct CreateWebhookSubscriptionDTO: Content {
    var name: String
    var url: String
    var eventTypes: [BusinessEventType]
    var companyIds: [UUID]
    var configuration: WebhookConfiguration { .init(name: name, url: url, eventTypes: eventTypes, companyIds: companyIds, enabled: false) }
}

struct PatchWebhookSubscriptionDTO: Content {
    var expectedRevisionId: UUID
    var name: String?
    var url: String?
    var eventTypes: [BusinessEventType]?
    var companyIds: [UUID]?
    var enabled: Bool?
    var rotateSecret: Bool?

    func applying(to before: WebhookConfiguration) -> WebhookConfiguration {
        .init(name: name ?? before.name, url: url ?? before.url, eventTypes: eventTypes ?? before.eventTypes,
            companyIds: companyIds ?? before.companyIds, enabled: enabled ?? before.enabled)
    }
}

struct WebhookRevisionDTO: Content {
    let id: UUID
    let version: Int
    let name: String
    let url: String
    let eventTypes: [BusinessEventType]
    let companyIds: [UUID]
    let enabled: Bool
    let schemaVersion: Int
    let secretId: UUID
    let createdById: UUID?
    let approvalRequestId: UUID?
    let createdAt: Date

    init(_ revision: WebhookSubscriptionRevision) throws {
        id = try revision.requireID()
        version = revision.version
        name = revision.name
        url = revision.url
        eventTypes = revision.eventTypes
        companyIds = revision.companyIDs
        enabled = revision.enabled
        schemaVersion = revision.schemaVersion
        secretId = revision.secretID
        createdById = revision.createdBy
        approvalRequestId = revision.approvalRequestID
        createdAt = revision.createdAt
    }
}

struct WebhookSubscriptionDTO: Content {
    let id: UUID
    let currentRevisionId: UUID
    let configuration: WebhookRevisionDTO
    let enabled: Bool
    let disabledReason: WebhookDisabledReason?
    let disabledById: UUID?
    let disabledActorType: AuditActorType?
    let disabledActorName: String?
    let disabledAt: Date?
    let failingSince: Date?
    let createdAt: Date
    let updatedAt: Date

    init(_ subscription: WebhookSubscription, revision: WebhookSubscriptionRevision) throws {
        id = try subscription.requireID()
        currentRevisionId = subscription.currentRevisionID
        configuration = try .init(revision)
        enabled = revision.enabled && subscription.disabledReason == nil
        disabledReason = subscription.disabledReason
        disabledById = subscription.disabledBy
        disabledActorType = subscription.disabledActorType
        disabledActorName = subscription.disabledActorName
        disabledAt = subscription.disabledAt
        failingSince = subscription.failingSince
        createdAt = subscription.createdAt
        updatedAt = subscription.updatedAt
    }
}

struct WebhookSecretDTO: Content {
    let secretId: UUID
    let secret: String
}

extension WebhookSubscriptionRevision {
    var configuration: WebhookConfiguration {
        .init(name: name, url: url, eventTypes: eventTypes, companyIds: companyIDs, enabled: enabled)
    }
}
