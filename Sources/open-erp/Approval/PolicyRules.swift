import Fluent
import Vapor

func validatePolicy(
    _ definition: ApprovalPolicyDefinition,
    on db: any Database,
    organizationID: UUID
) async throws {
    guard let permission = Permission(rawValue: definition.permission), ApprovalCatalog.isGateable(permission) else {
        throw Abort(.badRequest, reason: "Permission is not gateable")
    }
    if !definition.fields.isEmpty {
        guard permission.rawValue.hasSuffix(":update") else {
            throw Abort(.badRequest, reason: "Fields are only allowed on update permissions")
        }
        let allowed = Set(ApprovalCatalog.fields(for: permission))
        for field in definition.fields where !allowed.contains(field) {
            throw Abort(.badRequest, reason: "Unknown field \(field)")
        }
    }
    if let companyID = definition.companyId {
        guard ApprovalCatalog.supportsCompanyScope(permission) else {
            throw Abort(.badRequest, reason: "Permission does not support company scope")
        }
        guard try await Company.query(on: db, organizationID: organizationID).filter(\.$id == companyID).first() != nil else {
            throw Abort(.badRequest, reason: "Company must be an active company in this organization")
        }
    }
    guard !definition.stages.isEmpty else {
        throw Abort(.badRequest, reason: "A policy needs at least one stage")
    }
    let access = try await AccessSnapshot.load(organizationID: organizationID, on: db)
    for (index, stage) in definition.stages.enumerated() {
        guard !stage.slots.isEmpty else {
            throw Abort(.badRequest, reason: "A stage needs at least one slot")
        }
        var seen: Set<UUID> = []
        for slot in stage.slots {
            guard slot.required >= 1 else {
                throw Abort(.badRequest, reason: "A slot needs at least 1 approval")
            }
            guard seen.insert(slot.groupId).inserted else {
                throw Abort(.badRequest, reason: "A group can appear only once in a stage")
            }
            guard try await AccessGroup.query(on: db, organizationID: organizationID).filter(\.$id == slot.groupId).first() != nil else {
                throw Abort(.badRequest, reason: "Group must be an active group in this organization")
            }
            let members = access.groupsByMember.values.count { $0.contains(slot.groupId) }
            guard slot.required <= members else {
                throw Abort(.badRequest, reason: "Stage \(index + 1) slot requires \(slot.required) approvals but the group has \(members) active members")
            }
        }
        guard access.canComplete(stage, for: permission) else {
            throw Abort(.badRequest, reason: "Stage \(index + 1) cannot be completed by eligible approvers")
        }
    }
}

func checkAccessReduction(
    organizationID: UUID,
    on db: any Database,
    checkPolicies: Bool = false,
    simulate: (inout AccessSnapshot) -> Void
) async throws {
    let before = try await AccessSnapshot.load(organizationID: organizationID, on: db)
    var after = before
    simulate(&after)
    if !before.administrators.isEmpty && after.administrators.isEmpty {
        throw Abort(.conflict, reason: "This change would remove the organization's last administrator")
    }
    guard checkPolicies else { return }
    let policies = try await ApprovalPolicy.query(on: db, organizationID: organizationID).with(\.$slots).all()
    for policy in policies {
        let definition = policy.currentDefinition()
        guard let permission = Permission(rawValue: definition.permission) else { continue }
        if definition.stages.allSatisfy({ before.canComplete($0, for: permission) }),
           let index = definition.stages.firstIndex(where: { !after.canComplete($0, for: permission) }) {
            throw Abort(.conflict, reason: "This change would make stage \(index + 1) of policy \(definition.name) unsatisfiable")
        }
    }
}

extension AccessSnapshot {
    func canComplete(_ stage: ApprovalStageDTO, for permission: Permission) -> Bool {
        let slots = stage.slots.map { (groupID: $0.groupId, required: $0.required) }
        let groupIDs = Set(slots.map(\.groupID))
        let approvers = groupsByMember.filter { !$0.value.isDisjoint(with: groupIDs) }
        // Bound the matcher allocation even for invalid user-supplied counts.
        guard slots.allSatisfy({ $0.required <= approvers.count }),
              stageIsComplete(approvers: Array(approvers.values), slots: slots)
        else { return false }
        return approvers.allSatisfy { userID, _ in
            let grants = permissions(for: userID)
            let canRequest = grants.contains(permission)
                || (permission == .groupMemberCreate && grants.contains(.organizationInvitationCreate))
            return !canRequest || stageIsComplete(
                approvers: approvers.filter { $0.key != userID }.map(\.value),
                slots: slots
            )
        }
    }
}

func requireGateablePermission(_ raw: String?) throws -> Permission? {
    guard let raw else { return nil }
    guard let permission = Permission(rawValue: raw), ApprovalCatalog.isGateable(permission) else {
        throw Abort(.badRequest, reason: "Unknown permission \(raw)")
    }
    return permission
}

func policyUsesGroup(_ groupID: UUID, on db: any Database) async throws -> Bool {
    try await ApprovalPolicySlot.query(on: db)
        .join(ApprovalPolicy.self, on: \ApprovalPolicySlot.$policy.$id == \ApprovalPolicy.$id)
        .filter(\.$group.$id == groupID)
        .filter(ApprovalPolicy.self, \.$deletedAt == nil)
        .first() != nil
}

func replacePolicySlots(
    for policy: ApprovalPolicy,
    stages: [ApprovalStageDTO],
    actorID: UUID,
    on db: any Database
) async throws {
    let policyID = try policy.requireID()
    let existing = try await ApprovalPolicySlot.query(on: db).filter(\.$policy.$id == policyID).all()
    for slot in existing {
        try await slot.softDelete(by: actorID, \.$deletedBy, on: db)
    }
    for (index, stage) in stages.enumerated() {
        for slot in stage.slots {
            try await ApprovalPolicySlot(
                organizationID: policy.$organization.id,
                policyID: policyID,
                stage: index + 1,
                groupID: slot.groupId,
                required: slot.required,
                createdByID: actorID
            ).save(on: db)
        }
    }
}

func revokeHeldInvitation(requestID: UUID, actorID: UUID, on db: any Database) async throws {
    guard let invitation = try await OrganizationInvitation.query(on: db)
        .filter(\.$approvalRequest.$id == requestID)
        .first()
    else {
        return
    }
    try await invitation.softDelete(by: actorID, \.$deletedBy, on: db)
}

private let staleValue = Abort(.conflict, reason: "A value changed after the request was submitted")

func throwIfStale(_ stale: Bool) throws {
    if stale {
        throw staleValue
    }
}
