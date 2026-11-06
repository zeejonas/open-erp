import Fluent
import Foundation
import Vapor
import VaporToOpenAPI

enum AuditOperation: String, Codable, CaseIterable, Sendable {
    case create, update, delete, softDelete = "soft_delete", restore
}

final class AuditEvent: Model, @unchecked Sendable {
    static let schema = "audit_events"
    static let space: String? = "audit"

    @ID(custom: .id, generatedBy: .database) var id: UUID?
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "organization_id") var organizationID: UUID?
    @Field(key: "table_name") var tableName: String
    @OptionalField(key: "record_id") var recordID: UUID?
    @Field(key: "operation") var operation: AuditOperation
    @Field(key: "changed_fields") var changedFields: [String]
    @OptionalField(key: "old_values") var oldValues: AuditValues?
    @OptionalField(key: "new_values") var newValues: AuditValues?
    @Field(key: "actor_type") var actorType: AuditActorType
    @OptionalField(key: "actor_id") var actorID: UUID?
    @OptionalField(key: "actor_name") var actorName: String?
    @OptionalField(key: "ip_address") var ipAddress: String?
    @OptionalField(key: "request_id") var requestID: String?
    @OptionalField(key: "approval_request_id") var approvalRequestID: UUID?
    @Field(key: "database_user") var databaseUser: String
    @Field(key: "transaction_id") var transactionID: Int64

    init() {}
}

/// AnyValue's recursive cases contain only Swift value types.
struct AuditValues: Codable, Equatable, @unchecked Sendable, OpenAPIType {
    let values: [String: AnyValue]

    init(from decoder: any Decoder) throws {
        values = try [String: AnyValue](from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
    }

    static var openAPISchema: SchemaObject { .dictionary(of: .any) }
}

struct AuditEventDTO: Content {
    let id: UUID
    let createdAt: Date
    let organizationId: UUID?
    let table: String
    let recordId: UUID?
    let operation: AuditOperation
    let changedFields: [String]
    let oldValues: AuditValues?
    let newValues: AuditValues?
    let actorType: AuditActorType
    let actorId: UUID?
    let actorName: String?
    let ipAddress: String?
    let requestId: String?
    let approvalRequestId: UUID?
    let databaseUser: String?
    let transactionId: Int64

    init(_ event: AuditEvent, platform: Bool) throws {
        id = try event.requireID()
        createdAt = event.createdAt
        organizationId = event.organizationID
        table = event.tableName
        recordId = event.recordID
        operation = event.operation
        changedFields = event.changedFields
        oldValues = event.oldValues
        newValues = event.newValues
        actorType = event.actorType
        actorId = event.actorID
        actorName = (platform || event.actorType == .operator || event.actorType == .system) ? event.actorName : nil
        ipAddress = (platform || event.actorType == .user) ? event.ipAddress : nil
        requestId = event.requestID
        approvalRequestId = event.approvalRequestID
        databaseUser = platform ? event.databaseUser : nil
        transactionId = event.transactionID
    }
}
