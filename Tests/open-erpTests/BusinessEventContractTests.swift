@testable import open_erp
import Foundation
import Testing

@Suite("Business event v1 contract")
struct BusinessEventContractTests {
    @Test("All event summaries have exactly their allowlisted fields", arguments: BusinessEventType.allCases)
    func summaries(type: BusinessEventType) throws {
        let resourceID = UUID()
        let summary = fixtureSummary(type.resourceType)
        let envelope = BusinessEventEnvelope(
            id: UUID(), type: type, occurredAt: Date(timeIntervalSince1970: 1_700_000_000), organizationId: UUID(),
            resource: .init(type: type.resourceType, id: resourceID, revision: 1),
            actor: .init(type: .system, id: nil), requestedById: nil, requestId: nil, approvalRequestId: nil,
            changedFields: [], data: summary
        )
        let object = try #require(JSONSerialization.jsonObject(with: envelope.payload()) as? [String: Any])
        #expect(Set(object.keys) == Set(["id", "type", "schemaVersion", "occurredAt", "organizationId", "companyId", "resource", "actor", "requestedById", "requestId", "approvalRequestId", "changedFields", "data"]))
        let data = try #require(object["data"] as? [String: Any])
        #expect(Set(data.keys) == Set(type.resourceType.summaryFields))
        #expect(object["requestedById"] is NSNull)
        #expect(object["requestId"] is NSNull)
        #expect(object["approvalRequestId"] is NSNull)
        #expect((object["actor"] as? [String: Any])?["id"] is NSNull)
        if type.supportsCompanyFilter {
            #expect(object["companyId"] as? String == summary.companyID(resourceID: resourceID)?.uuidString)
        } else {
            #expect(object["companyId"] is NSNull)
        }
        if type.resourceType == .approvalRequest {
            #expect(data["targetId"] is NSNull)
            #expect(data["decisionId"] is NSNull)
            #expect(data["decisionKind"] is NSNull)
        }
        if type.resourceType == .invitation { #expect(data["groupId"] is NSNull) }
        let forbidden = ["token", "email", "firstName", "lastName", "authSubject", "ipAddress", "databaseUser", "operator", "comment", "proposedChange", "secret", "error", "transactionId"]
        #expect(Set(data.keys).isDisjoint(with: forbidden))
        #expect(Set(object.keys).isDisjoint(with: forbidden))
    }

    @Test("Mismatched resource summaries fail closed")
    func mismatchedSummary() {
        let envelope = BusinessEventEnvelope(
            id: UUID(), type: .companyCreated, occurredAt: Date(), organizationId: UUID(),
            resource: .init(type: .company, id: UUID(), revision: 1), actor: .init(type: .user, id: UUID()),
            requestedById: nil, requestId: nil, approvalRequestId: nil, changedFields: [], data: .group(name: "Group", deleted: false)
        )
        #expect(throws: EncodingError.self) { try envelope.payload() }
    }
}

func fixtureSummary(_ type: BusinessResourceType) -> BusinessEventSummary {
    switch type {
    case .organization: .organization(code: "ORG", name: "Organization", deleted: false)
    case .company: .company(code: "CO", name: "Company", deleted: false)
    case .role: .role(name: "Role", level: .organization, deleted: false)
    case .group: .group(name: "Group", deleted: false)
    case .groupMember: .groupMember(groupId: UUID(), userId: UUID())
    case .groupRole: .groupRole(groupId: UUID(), roleId: UUID())
    case .groupCompany: .groupCompany(groupId: UUID(), companyId: UUID())
    case .organizationUser: .organizationUser(userId: UUID())
    case .invitation: .invitation(groupId: nil, status: "pending", expiresAt: Date(timeIntervalSince1970: 1_700_000_000))
    case .approvalPolicy: .approvalPolicy(name: "Policy", permission: "company:update", currentVersion: 1, deleted: false)
    case .approvalRequest: .approvalRequest(permission: "company:update", targetId: nil, status: "failed", decisionId: nil, decisionKind: nil)
    }
}
