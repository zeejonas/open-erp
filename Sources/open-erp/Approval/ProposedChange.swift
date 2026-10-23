import Fluent
import Vapor

enum ProposedChange: Codable, Equatable, Sendable {
    case organizationUpdate(id: UUID, before: CodeNameSnapshot, after: CodeNameSnapshot)
    case organizationDelete(id: UUID, before: CodeNameSnapshot)
    case companyCreate(CodeNameSnapshot)
    case companyUpdate(id: UUID, before: CodeNameSnapshot, after: CodeNameSnapshot)
    case companyDelete(id: UUID, before: CodeNameSnapshot)
    case organizationUserDelete(userID: UUID)
    case organizationInvitationCreate(InvitationDraft)
    case organizationInvitationDelete(id: UUID)
    case roleCreate(RoleDraft)
    case roleUpdate(id: UUID, before: RoleSnapshot, after: RoleSnapshot)
    case roleDelete(id: UUID, before: RoleSnapshot)
    case groupCreate(name: String)
    case groupUpdate(id: UUID, before: GroupSnapshot, after: GroupSnapshot)
    case groupDelete(id: UUID, before: GroupSnapshot)
    case groupMemberCreate(GroupMemberDraft)
    case groupMemberDelete(GroupMemberDraft)
    case groupRoleCreate(GroupRoleDraft)
    case groupRoleDelete(GroupRoleDraft)
    case groupCompanyCreate(GroupCompanyDraft)
    case groupCompanyDelete(GroupCompanyDraft)
    case approvalPolicyCreate(ApprovalPolicyDefinition)
    case approvalPolicyUpdate(id: UUID, before: ApprovalPolicyDefinition, after: ApprovalPolicyDefinition)
    case approvalPolicyDelete(id: UUID, before: ApprovalPolicyDefinition)

    var permission: Permission {
        switch self {
        case .organizationUpdate: .organizationUpdate
        case .organizationDelete: .organizationDelete
        case .companyCreate: .companyCreate
        case .companyUpdate: .companyUpdate
        case .companyDelete: .companyDelete
        case .organizationUserDelete: .organizationUserDelete
        case .organizationInvitationCreate: .organizationInvitationCreate
        case .organizationInvitationDelete: .organizationInvitationDelete
        case .roleCreate: .roleCreate
        case .roleUpdate: .roleUpdate
        case .roleDelete: .roleDelete
        case .groupCreate: .groupCreate
        case .groupUpdate: .groupUpdate
        case .groupDelete: .groupDelete
        case .groupMemberCreate: .groupMemberCreate
        case .groupMemberDelete: .groupMemberDelete
        case .groupRoleCreate: .groupRoleCreate
        case .groupRoleDelete: .groupRoleDelete
        case .groupCompanyCreate: .groupCompanyCreate
        case .groupCompanyDelete: .groupCompanyDelete
        case .approvalPolicyCreate: .approvalPolicyCreate
        case .approvalPolicyUpdate: .approvalPolicyUpdate
        case .approvalPolicyDelete: .approvalPolicyDelete
        }
    }

    /// Permissions whose policies govern this change. An invitation into a group adds a group member on acceptance.
    var gatingPermissions: Set<Permission> {
        if case .organizationInvitationCreate(let draft) = self, draft.groupId != nil {
            return [.organizationInvitationCreate, .groupMemberCreate]
        }
        return [permission]
    }

    var targetID: UUID? {
        switch self {
        case .organizationUpdate(let id, _, _), .organizationDelete(let id, _): id
        case .companyUpdate(let id, _, _), .companyDelete(let id, _): id
        case .organizationUserDelete(let userID): userID
        case .organizationInvitationDelete(let id): id
        case .roleUpdate(let id, _, _), .roleDelete(let id, _): id
        case .groupUpdate(let id, _, _), .groupDelete(let id, _): id
        case .groupMemberCreate(let draft), .groupMemberDelete(let draft): draft.groupId
        case .groupRoleCreate(let draft), .groupRoleDelete(let draft): draft.groupId
        case .groupCompanyCreate(let draft), .groupCompanyDelete(let draft): draft.groupId
        case .approvalPolicyUpdate(let id, _, _), .approvalPolicyDelete(let id, _): id
        case .companyCreate, .organizationInvitationCreate, .roleCreate, .groupCreate, .approvalPolicyCreate:
            nil
        }
    }

    /// Fields whose value differs. Set-valued fields such as `permissions` compare as sets.
    func changedFields() -> Set<String> {
        switch self {
        case .organizationUpdate(_, let before, let after), .companyUpdate(_, let before, let after):
            return differing(["code": before.code != after.code, "name": before.name != after.name])
        case .roleUpdate(_, let before, let after):
            return differing([
                "name": before.name != after.name,
                "permissions": Set(before.permissions) != Set(after.permissions),
            ])
        case .groupUpdate(_, let before, let after):
            return differing(["name": before.name != after.name])
        case .approvalPolicyUpdate(_, let before, let after):
            return after.changedFields(from: before)
        default:
            return []
        }
    }

    func companyContext(on db: any Database) async throws -> Set<UUID> {
        switch self {
        case .companyUpdate(let id, _, _), .companyDelete(let id, _):
            return [id]
        case .groupCompanyCreate(let draft), .groupCompanyDelete(let draft):
            return [draft.companyId]
        case .groupUpdate(let id, _, _), .groupDelete(let id, _):
            return try await eligibleCompanies(groupID: id, on: db)
        case .groupMemberCreate(let draft), .groupMemberDelete(let draft):
            return try await eligibleCompanies(groupID: draft.groupId, on: db)
        case .groupRoleCreate(let draft), .groupRoleDelete(let draft):
            return try await eligibleCompanies(groupID: draft.groupId, on: db)
        case .organizationInvitationCreate(let draft):
            guard let groupID = draft.groupId else { return [] }
            return try await eligibleCompanies(groupID: groupID, on: db)
        default:
            return []
        }
    }
}

private func differing(_ fields: [String: Bool]) -> Set<String> {
    Set(fields.compactMap { name, changed in changed ? name : nil })
}

private func eligibleCompanies(groupID: UUID, on db: any Database) async throws -> Set<UUID> {
    let links = try await GroupCompany.query(on: db).filter(\.$group.$id == groupID).all()
    return Set(links.map(\.$company.id))
}

extension ProposedChange {
    private enum CodingKeys: String, CodingKey {
        case permission
        case targetId
        case before
        case after
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(permission.rawValue, forKey: .permission)
        if let targetID {
            try container.encode(targetID, forKey: .targetId)
        }
        switch self {
        case .organizationUpdate(_, let before, let after), .companyUpdate(_, let before, let after):
            try container.encode(before, forKey: .before)
            try container.encode(after, forKey: .after)
        case .organizationDelete(_, let before), .companyDelete(_, let before):
            try container.encode(before, forKey: .before)
        case .companyCreate(let after):
            try container.encode(after, forKey: .after)
        case .organizationUserDelete:
            break
        case .organizationInvitationCreate(let draft):
            try container.encode(draft, forKey: .after)
        case .organizationInvitationDelete:
            break
        case .roleCreate(let draft):
            try container.encode(draft, forKey: .after)
        case .roleUpdate(_, let before, let after):
            try container.encode(before, forKey: .before)
            try container.encode(after, forKey: .after)
        case .roleDelete(_, let before):
            try container.encode(before, forKey: .before)
        case .groupCreate(let name):
            try container.encode(GroupSnapshot(name: name), forKey: .after)
        case .groupUpdate(_, let before, let after):
            try container.encode(before, forKey: .before)
            try container.encode(after, forKey: .after)
        case .groupDelete(_, let before):
            try container.encode(before, forKey: .before)
        case .groupMemberCreate(let draft), .groupMemberDelete(let draft):
            try container.encode(draft, forKey: .after)
        case .groupRoleCreate(let draft), .groupRoleDelete(let draft):
            try container.encode(draft, forKey: .after)
        case .groupCompanyCreate(let draft), .groupCompanyDelete(let draft):
            try container.encode(draft, forKey: .after)
        case .approvalPolicyCreate(let definition):
            try container.encode(definition, forKey: .after)
        case .approvalPolicyUpdate(_, let before, let after):
            try container.encode(before, forKey: .before)
            try container.encode(after, forKey: .after)
        case .approvalPolicyDelete(_, let before):
            try container.encode(before, forKey: .before)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawPermission = try container.decode(String.self, forKey: .permission)
        guard let permission = Permission(rawValue: rawPermission) else {
            throw DecodingError.dataCorruptedError(
                forKey: .permission,
                in: container,
                debugDescription: "Unknown permission \(rawPermission)"
            )
        }
        switch permission {
        case .organizationUpdate:
            self = .organizationUpdate(
                id: try container.decode(UUID.self, forKey: .targetId),
                before: try container.decode(CodeNameSnapshot.self, forKey: .before),
                after: try container.decode(CodeNameSnapshot.self, forKey: .after)
            )
        case .organizationDelete:
            self = .organizationDelete(
                id: try container.decode(UUID.self, forKey: .targetId),
                before: try container.decode(CodeNameSnapshot.self, forKey: .before)
            )
        case .companyCreate:
            self = .companyCreate(try container.decode(CodeNameSnapshot.self, forKey: .after))
        case .companyUpdate:
            self = .companyUpdate(
                id: try container.decode(UUID.self, forKey: .targetId),
                before: try container.decode(CodeNameSnapshot.self, forKey: .before),
                after: try container.decode(CodeNameSnapshot.self, forKey: .after)
            )
        case .companyDelete:
            self = .companyDelete(
                id: try container.decode(UUID.self, forKey: .targetId),
                before: try container.decode(CodeNameSnapshot.self, forKey: .before)
            )
        case .organizationUserDelete:
            self = .organizationUserDelete(userID: try container.decode(UUID.self, forKey: .targetId))
        case .organizationInvitationCreate:
            self = .organizationInvitationCreate(try container.decode(InvitationDraft.self, forKey: .after))
        case .organizationInvitationDelete:
            self = .organizationInvitationDelete(id: try container.decode(UUID.self, forKey: .targetId))
        case .roleCreate:
            self = .roleCreate(try container.decode(RoleDraft.self, forKey: .after))
        case .roleUpdate:
            self = .roleUpdate(
                id: try container.decode(UUID.self, forKey: .targetId),
                before: try container.decode(RoleSnapshot.self, forKey: .before),
                after: try container.decode(RoleSnapshot.self, forKey: .after)
            )
        case .roleDelete:
            self = .roleDelete(
                id: try container.decode(UUID.self, forKey: .targetId),
                before: try container.decode(RoleSnapshot.self, forKey: .before)
            )
        case .groupCreate:
            self = .groupCreate(name: try container.decode(GroupSnapshot.self, forKey: .after).name)
        case .groupUpdate:
            self = .groupUpdate(
                id: try container.decode(UUID.self, forKey: .targetId),
                before: try container.decode(GroupSnapshot.self, forKey: .before),
                after: try container.decode(GroupSnapshot.self, forKey: .after)
            )
        case .groupDelete:
            self = .groupDelete(
                id: try container.decode(UUID.self, forKey: .targetId),
                before: try container.decode(GroupSnapshot.self, forKey: .before)
            )
        case .groupMemberCreate:
            self = .groupMemberCreate(try container.decode(GroupMemberDraft.self, forKey: .after))
        case .groupMemberDelete:
            self = .groupMemberDelete(try container.decode(GroupMemberDraft.self, forKey: .after))
        case .groupRoleCreate:
            self = .groupRoleCreate(try container.decode(GroupRoleDraft.self, forKey: .after))
        case .groupRoleDelete:
            self = .groupRoleDelete(try container.decode(GroupRoleDraft.self, forKey: .after))
        case .groupCompanyCreate:
            self = .groupCompanyCreate(try container.decode(GroupCompanyDraft.self, forKey: .after))
        case .groupCompanyDelete:
            self = .groupCompanyDelete(try container.decode(GroupCompanyDraft.self, forKey: .after))
        case .approvalPolicyCreate:
            self = .approvalPolicyCreate(try container.decode(ApprovalPolicyDefinition.self, forKey: .after))
        case .approvalPolicyUpdate:
            self = .approvalPolicyUpdate(
                id: try container.decode(UUID.self, forKey: .targetId),
                before: try container.decode(ApprovalPolicyDefinition.self, forKey: .before),
                after: try container.decode(ApprovalPolicyDefinition.self, forKey: .after)
            )
        case .approvalPolicyDelete:
            self = .approvalPolicyDelete(
                id: try container.decode(UUID.self, forKey: .targetId),
                before: try container.decode(ApprovalPolicyDefinition.self, forKey: .before)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .permission,
                in: container,
                debugDescription: "Permission \(rawPermission) is not a proposed change"
            )
        }
    }
}
