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
    for stage in definition.stages {
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
            let members = try await activeMemberCount(groupID: slot.groupId, on: db)
            if slot.required > members {
                throw Abort(.badRequest, reason: "Slot requires \(slot.required) approvals but the group has \(members) active members")
            }
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
    policyID: UUID,
    stages: [ApprovalStageDTO],
    actorID: UUID,
    on db: any Database
) async throws {
    let existing = try await ApprovalPolicySlot.query(on: db).filter(\.$policy.$id == policyID).all()
    for slot in existing {
        try await slot.softDelete(by: actorID, \.$deletedBy, on: db)
    }
    for (index, stage) in stages.enumerated() {
        for slot in stage.slots {
            try await ApprovalPolicySlot(
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
