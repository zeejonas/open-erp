import Fluent
import Foundation

final class BusinessEventStream: Model, @unchecked Sendable {
    static let schema = "business_event_streams"
    @ID(key: .id) var id: UUID?
    @Parent(key: "organization_id") var organization: Organization
    @Field(key: "resource_type") var resourceType: BusinessResourceType
    @Field(key: "resource_id") var resourceID: UUID
    @Field(key: "revision") var revision: Int64
    init() {}
}

final class BusinessEvent: Model, @unchecked Sendable {
    static let schema = "business_events"
    @ID(key: .id) var id: UUID?
    @Parent(key: "organization_id") var organization: Organization
    @Field(key: "type") var type: BusinessEventType
    @Field(key: "schema_version") var schemaVersion: Int
    @Field(key: "resource_type") var resourceType: BusinessResourceType
    @Field(key: "resource_id") var resourceID: UUID
    @Field(key: "revision") var revision: Int64
    @OptionalField(key: "company_id") var companyID: UUID?
    @Field(key: "actor_type") var actorType: AuditActorType
    @OptionalField(key: "actor_id") var actorID: UUID?
    @OptionalField(key: "requested_by_id") var requestedByID: UUID?
    @OptionalField(key: "request_id") var requestID: String?
    @OptionalField(key: "approval_request_id") var approvalRequestID: UUID?
    @Field(key: "changed_fields") var changedFields: [String]
    @Field(key: "payload") var payload: Data
    @Field(key: "payload_digest") var payloadDigest: String
    @Field(key: "transaction_id") var transactionID: Int64
    @Field(key: "capture_snapshot") var captureSnapshot: String
    @Field(key: "capture_order") var captureOrder: Int64
    @Field(key: "created_at") var createdAt: Date
    init() {}

    static func metadata(on db: any Database, organizationID: UUID) -> QueryBuilder<BusinessEvent> {
        query(on: db).filter(\.$organization.$id == organizationID)
            .field(\.$id).field(\.$organization.$id).field(\.$type).field(\.$schemaVersion).field(\.$createdAt)
            .field(\.$companyID).field(\.$resourceType).field(\.$resourceID).field(\.$revision)
            .field(\.$actorType).field(\.$actorID).field(\.$requestedByID).field(\.$requestID)
            .field(\.$approvalRequestID).field(\.$changedFields)
    }
}

final class BusinessEventDispatch: Model, @unchecked Sendable {
    static let schema = "business_event_dispatches"
    @ID(key: .id) var id: UUID?
    @Parent(key: "organization_id") var organization: Organization
    @Parent(key: "event_id") var event: BusinessEvent
    @Field(key: "created_at") var createdAt: Date
    init() {}
}
