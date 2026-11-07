import Crypto
import Fluent
import Foundation
import SQLKit

enum BusinessEventWriter {
    struct InvalidTransaction: Error {}

    /// Must use the database passed to auditedTransaction. No subscription or delivery access belongs here.
    @discardableResult
    static func write(
        _ type: BusinessEventType, resourceID: UUID, organizationID: UUID,
        changedFields: [String] = [], data: BusinessEventSummary, on db: any Database
    ) async throws -> BusinessEvent {
        guard db.inTransaction else { throw InvalidTransaction() }
        let sql = try db.requireSQL()
        let metadata = try await sql.raw("""
            SELECT transaction_timestamp() AS occurred_at, txid_current() AS transaction_id,
                pg_current_snapshot()::text AS capture_snapshot, nextval('webhook_capture_order') AS capture_order,
                NULLIF(current_setting('audit.context', true), '') AS context
            """).first()
        guard let metadata, let json = try metadata.decode(column: "context", as: String?.self) else {
            throw InvalidTransaction()
        }
        let context = try JSONDecoder().decode(AuditContext.self, from: Data(json.utf8))
        let time = try metadata.decode(column: "occurred_at", as: Date.self)
        var requestedByID: UUID?
        if let approvalID = context.approvalRequestID {
            requestedByID = try await ApprovalRequest.query(on: db, organizationID: organizationID)
                .filter(\.$id == approvalID).first()?.$requestedBy.id
        }
        let allocation = try await sql.raw("""
            INSERT INTO business_event_streams (organization_id, resource_type, resource_id, revision)
            VALUES (\(bind: organizationID), \(bind: type.resourceType.rawValue), \(bind: resourceID), 1)
            ON CONFLICT (organization_id, resource_type, resource_id)
            DO UPDATE SET revision = business_event_streams.revision + 1
            RETURNING revision
            """).first()
        guard let allocation else { throw InvalidTransaction() }
        let revision = try allocation.decode(column: "revision", as: Int64.self)
        let id = UUID()
        let fields = Array(Set(changedFields)).sorted()
        let envelope = BusinessEventEnvelope(
            id: id, type: type, occurredAt: time, organizationId: organizationID,
            resource: .init(type: type.resourceType, id: resourceID, revision: revision),
            actor: .init(type: context.actorType, id: context.actorID), requestedById: requestedByID,
            requestId: context.requestID, approvalRequestId: context.approvalRequestID,
            changedFields: fields, data: data
        )
        let payload = try envelope.payload()
        let event = BusinessEvent()
        event.id = id
        event.$organization.id = organizationID
        event.type = type
        event.schemaVersion = 1
        event.resourceType = type.resourceType
        event.resourceID = resourceID
        event.revision = revision
        event.companyID = data.companyID(resourceID: resourceID)
        event.actorType = context.actorType
        event.actorID = context.actorID
        event.requestedByID = requestedByID
        event.requestID = context.requestID
        event.approvalRequestID = context.approvalRequestID
        event.changedFields = fields
        event.payload = payload
        event.payloadDigest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        event.transactionID = try metadata.decode(column: "transaction_id", as: Int64.self)
        event.captureSnapshot = try metadata.decode(column: "capture_snapshot", as: String.self)
        event.captureOrder = try metadata.decode(column: "capture_order", as: Int64.self)
        event.createdAt = time
        try await event.create(on: db)
        let dispatch = BusinessEventDispatch()
        dispatch.$organization.id = organizationID
        dispatch.$event.id = id
        dispatch.createdAt = time
        try await dispatch.create(on: db)
        return event
    }
}
