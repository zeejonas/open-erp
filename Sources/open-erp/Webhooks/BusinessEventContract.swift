import Foundation

/// Version 1 is an explicit allowlist, independent of database models and API DTOs.
enum BusinessEventType: String, Codable, CaseIterable, Sendable {
    case organizationCreated = "organization.created"
    case organizationUpdated = "organization.updated"
    case organizationDeleted = "organization.deleted"
    case organizationRestored = "organization.restored"
    case companyCreated = "company.created"
    case companyUpdated = "company.updated"
    case companyDeleted = "company.deleted"
    case roleCreated = "role.created"
    case roleUpdated = "role.updated"
    case roleDeleted = "role.deleted"
    case groupCreated = "group.created"
    case groupUpdated = "group.updated"
    case groupDeleted = "group.deleted"
    case groupMemberCreated = "group_member.created"
    case groupMemberDeleted = "group_member.deleted"
    case groupRoleCreated = "group_role.created"
    case groupRoleDeleted = "group_role.deleted"
    case groupCompanyCreated = "group_company.created"
    case groupCompanyDeleted = "group_company.deleted"
    case organizationUserCreated = "organization_user.created"
    case organizationUserDeleted = "organization_user.deleted"
    case invitationIssued = "organization_invitation.issued"
    case invitationReissued = "organization_invitation.reissued"
    case invitationAccepted = "organization_invitation.accepted"
    case invitationRevoked = "organization_invitation.revoked"
    case approvalPolicyCreated = "approval_policy.created"
    case approvalPolicyUpdated = "approval_policy.updated"
    case approvalPolicyDeleted = "approval_policy.deleted"
    case approvalRequestCreated = "approval_request.created"
    case approvalDecisionRecorded = "approval_request.decision_recorded"
    case approvalRequestApplied = "approval_request.applied"
    case approvalRequestFailed = "approval_request.failed"
    case approvalRequestRejected = "approval_request.rejected"
    case approvalRequestWithdrawn = "approval_request.withdrawn"
    case approvalRequestOverridden = "approval_request.overridden"

    var resourceType: BusinessResourceType {
        // All cases above have a code-owned resource prefix.
        BusinessResourceType(rawValue: String(rawValue.split(separator: ".")[0]))!
    }

    var schemaVersion: Int { 1 }
    var sourceReadPermission: Permission { resourceType.sourceReadPermission }
    var supportsCompanyFilter: Bool { resourceType == .company || resourceType == .groupCompany }

    /// Semantic operation names for catalog discovery; storage callbacks are not producers.
    var emittingOperation: String {
        switch self {
        case .organizationCreated: "PlatformController.provision"
        case .organizationRestored: "PlatformController.restore"
        case .organizationUserCreated: "InvitationController.accept"
        case .groupMemberCreated: "ProposedChange.apply / InvitationController.accept"
        case .invitationIssued: "ProposedChange.apply / PlatformController.provision"
        case .invitationReissued: "PlatformController.reissue"
        case .invitationAccepted: "InvitationController.accept"
        case .approvalRequestCreated: "ApprovalService.submit"
        case .approvalDecisionRecorded, .approvalRequestApplied, .approvalRequestFailed,
             .approvalRequestRejected, .approvalRequestWithdrawn, .approvalRequestOverridden: "ApprovalActions"
        default: "ProposedChange.apply: \(rawValue)"
        }
    }
}

enum BusinessResourceType: String, Codable, CaseIterable, Sendable {
    case organization, company, role, group
    case groupMember = "group_member", groupRole = "group_role", groupCompany = "group_company"
    case organizationUser = "organization_user", invitation = "organization_invitation"
    case approvalPolicy = "approval_policy", approvalRequest = "approval_request"

    var sourceReadPermission: Permission {
        switch self {
        case .organization: .organizationRead
        case .company: .companyRead
        case .role: .roleRead
        case .group, .groupRole, .groupCompany: .groupRead
        case .groupMember: .groupMemberRead
        case .organizationUser: .organizationUserRead
        case .invitation: .organizationInvitationRead
        case .approvalPolicy: .approvalPolicyRead
        case .approvalRequest: .approvalRequestRead
        }
    }

    var summaryFields: [String] {
        switch self {
        case .organization, .company: ["code", "name", "deleted"]
        case .role: ["name", "level", "deleted"]
        case .group: ["name", "deleted"]
        case .groupMember: ["groupId", "userId"]
        case .groupRole: ["groupId", "roleId"]
        case .groupCompany: ["groupId", "companyId"]
        case .organizationUser: ["userId"]
        case .invitation: ["groupId", "status", "expiresAt"]
        case .approvalPolicy: ["name", "permission", "currentVersion", "deleted"]
        case .approvalRequest: ["permission", "targetId", "status", "decisionId", "decisionKind"]
        }
    }
}

enum BusinessEventSummary: Encodable, Sendable {
    case organization(code: String, name: String, deleted: Bool)
    case company(code: String, name: String, deleted: Bool)
    case role(name: String, level: RoleLevel, deleted: Bool)
    case group(name: String, deleted: Bool)
    case groupMember(groupId: UUID, userId: UUID)
    case groupRole(groupId: UUID, roleId: UUID)
    case groupCompany(groupId: UUID, companyId: UUID)
    case organizationUser(userId: UUID)
    case invitation(groupId: UUID?, status: String, expiresAt: Date)
    case approvalPolicy(name: String, permission: String, currentVersion: Int, deleted: Bool)
    case approvalRequest(permission: String, targetId: UUID?, status: String, decisionId: UUID?, decisionKind: String?)

    var resourceType: BusinessResourceType {
        switch self {
        case .organization: .organization
        case .company: .company
        case .role: .role
        case .group: .group
        case .groupMember: .groupMember
        case .groupRole: .groupRole
        case .groupCompany: .groupCompany
        case .organizationUser: .organizationUser
        case .invitation: .invitation
        case .approvalPolicy: .approvalPolicy
        case .approvalRequest: .approvalRequest
        }
    }

    /// Relationships and company resources are the only company-context events in v1.
    func companyID(resourceID: UUID) -> UUID? {
        switch self {
        case .company: resourceID
        case .groupCompany(_, let companyID): companyID
        default: nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case code, name, deleted, level, groupId, userId, roleId, companyId
        case status, expiresAt, permission, currentVersion, targetId, decisionId, decisionKind
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .organization(let code, let name, let deleted), .company(let code, let name, let deleted):
            try values.encode(code, forKey: .code)
            try values.encode(name, forKey: .name)
            try values.encode(deleted, forKey: .deleted)
        case .role(let name, let level, let deleted):
            try values.encode(name, forKey: .name)
            try values.encode(level, forKey: .level)
            try values.encode(deleted, forKey: .deleted)
        case .group(let name, let deleted):
            try values.encode(name, forKey: .name)
            try values.encode(deleted, forKey: .deleted)
        case .groupMember(let groupID, let userID):
            try values.encode(groupID, forKey: .groupId)
            try values.encode(userID, forKey: .userId)
        case .groupRole(let groupID, let roleID):
            try values.encode(groupID, forKey: .groupId)
            try values.encode(roleID, forKey: .roleId)
        case .groupCompany(let groupID, let companyID):
            try values.encode(groupID, forKey: .groupId)
            try values.encode(companyID, forKey: .companyId)
        case .organizationUser(let userID):
            try values.encode(userID, forKey: .userId)
        case .invitation(let groupID, let status, let expiresAt):
            try values.encode(groupID, forKey: .groupId)
            try values.encode(status, forKey: .status)
            try values.encode(expiresAt, forKey: .expiresAt)
        case .approvalPolicy(let name, let permission, let version, let deleted):
            try values.encode(name, forKey: .name)
            try values.encode(permission, forKey: .permission)
            try values.encode(version, forKey: .currentVersion)
            try values.encode(deleted, forKey: .deleted)
        case .approvalRequest(let permission, let targetID, let status, let decisionID, let kind):
            try values.encode(permission, forKey: .permission)
            try values.encode(targetID, forKey: .targetId)
            try values.encode(status, forKey: .status)
            try values.encode(decisionID, forKey: .decisionId)
            try values.encode(kind, forKey: .decisionKind)
        }
    }
}

struct BusinessEventEnvelope: Encodable, Sendable {
    struct Resource: Codable, Sendable {
        let type: BusinessResourceType
        let id: UUID
        let revision: Int64
    }

    struct Actor: Codable, Sendable {
        let type: AuditActorType
        let id: UUID?

        private enum CodingKeys: String, CodingKey { case type, id }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(type, forKey: .type)
            try values.encode(id, forKey: .id)
        }
    }

    let id: UUID
    let type: BusinessEventType
    let occurredAt: Date
    let organizationId: UUID
    let resource: Resource
    let actor: Actor
    let requestedById: UUID?
    let requestId: String?
    let approvalRequestId: UUID?
    let changedFields: [String]
    let data: BusinessEventSummary

    private enum CodingKeys: String, CodingKey {
        case id, type, schemaVersion, occurredAt, organizationId, companyId, resource, actor
        case requestedById, requestId, approvalRequestId, changedFields, data
    }

    func encode(to encoder: any Encoder) throws {
        guard type.resourceType == resource.type, data.resourceType == resource.type, resource.revision > 0 else {
            throw EncodingError.invalidValue(type, .init(codingPath: encoder.codingPath, debugDescription: "Invalid business event contract"))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(type, forKey: .type)
        try values.encode(type.schemaVersion, forKey: .schemaVersion)
        try values.encode(occurredAt, forKey: .occurredAt)
        try values.encode(organizationId, forKey: .organizationId)
        try values.encode(data.companyID(resourceID: resource.id), forKey: .companyId)
        try values.encode(resource, forKey: .resource)
        try values.encode(actor, forKey: .actor)
        try values.encode(requestedById, forKey: .requestedById)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(approvalRequestId, forKey: .approvalRequestId)
        try values.encode(changedFields, forKey: .changedFields)
        try values.encode(data, forKey: .data)
    }

    func payload() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
