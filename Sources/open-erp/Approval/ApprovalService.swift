import Fluent
import FluentSQL
import SQLKit
import Vapor

extension Request {
    var approvals: ApprovalService {
        ApprovalService(request: self)
    }
}

struct ApprovalService {
    var request: Request

    func submit<T: AsyncResponseEncodable & Sendable>(_ change: ProposedChange) async throws -> ApprovalOutcome<T> {
        let requesterID = try request.userID()
        let organizationID = request.organizationID
        return try await request.db.transaction { db in
            try await change.check(on: db, organizationID: organizationID)
            let (result, held) = try await submitOrHold(
                change,
                requesterID: requesterID,
                organizationID: organizationID,
                on: db
            )
            if let held {
                return .held(held)
            }
            return .applied(try result.cast())
        }
    }

    func approve(_ requestID: UUID) async throws -> GetApprovalRequestDTO {
        let userID = try request.userID()
        let organizationID = request.organizationID
        return try await ApprovalActions.approve(
            requestID: requestID,
            organizationID: organizationID,
            userID: userID,
            on: request.db
        )
    }

    func reject(_ requestID: UUID, comment: String?) async throws -> GetApprovalRequestDTO {
        let userID = try request.userID()
        return try await ApprovalActions.reject(
            requestID: requestID,
            organizationID: request.organizationID,
            userID: userID,
            comment: comment,
            on: request.db
        )
    }

    func withdraw(_ requestID: UUID) async throws -> GetApprovalRequestDTO {
        let userID = try request.userID()
        return try await ApprovalActions.withdraw(
            requestID: requestID,
            organizationID: request.organizationID,
            userID: userID,
            on: request.db
        )
    }

    func override(_ requestID: UUID, reason: String?) async throws -> GetApprovalRequestDTO {
        let userID = try request.userID()
        return try await ApprovalActions.override(
            requestID: requestID,
            organizationID: request.organizationID,
            reason: reason,
            operatorName: nil,
            actorID: userID,
            on: request.db
        )
    }
}

enum ApprovalActions {
    static func approve(
        requestID: UUID,
        organizationID: UUID,
        userID: UUID,
        on db: any Database
    ) async throws -> GetApprovalRequestDTO {
        do {
            return try await db.transaction { database in
                let approval = try await lockApprovalRequest(requestID, organizationID: organizationID, on: database)
                try requirePending(approval)
                let decisions = try await recordApprovals(
                    approval,
                    userID: userID,
                    organizationID: organizationID,
                    on: database
                )
                guard !decisions.isEmpty else {
                    throw Abort(.forbidden, reason: "Not eligible to approve this request")
                }
                if try await pendingTrackCount(approval, on: database) == 0 {
                    try await applyApproved(approval, decisions: decisions, actorID: userID, on: database)
                }
                return try await approval.detailedDTO(on: database)
            }
        } catch let failure as ApprovalApplyFailure {
            return try await recordFailure(failure, requestID: requestID, organizationID: organizationID, on: db)
        }
    }

    static func reject(
        requestID: UUID,
        organizationID: UUID,
        userID: UUID,
        comment: String?,
        on db: any Database
    ) async throws -> GetApprovalRequestDTO {
        let comment = try requiredText(comment, reason: "A comment is required")
        return try await db.transaction { database in
            let approval = try await lockApprovalRequest(requestID, organizationID: organizationID, on: database)
            try requirePending(approval)
            let tracks = try await eligibleTracks(
                approval,
                userID: userID,
                organizationID: organizationID,
                approving: false,
                on: database
            )
            guard !tracks.isEmpty else {
                throw Abort(.forbidden, reason: "Not eligible to reject this request")
            }
            for item in tracks {
                try await NewDecision(
                    trackID: item.trackID,
                    stage: item.stage,
                    kind: .reject,
                    decidedByID: userID,
                    operatorName: nil,
                    qualifyingGroupIDs: item.qualifyingGroupIDs,
                    comment: comment
                ).insert(requestID: requestID, on: database)
            }
            approval.status = ApprovalRequestStatus.rejected.rawValue
            try await approval.save(on: database)
            try await revokeHeldInvitation(requestID: requestID, actorID: userID, on: database)
            return try await approval.detailedDTO(on: database)
        }
    }

    static func withdraw(
        requestID: UUID,
        organizationID: UUID,
        userID: UUID,
        on db: any Database
    ) async throws -> GetApprovalRequestDTO {
        try await db.transaction { database in
            let approval = try await lockApprovalRequest(requestID, organizationID: organizationID, on: database)
            try requirePending(approval)
            guard approval.$requestedBy.id == userID else {
                throw Abort(.forbidden, reason: "Only the requester can withdraw a request")
            }
            approval.status = ApprovalRequestStatus.withdrawn.rawValue
            try await approval.save(on: database)
            try await revokeHeldInvitation(requestID: requestID, actorID: userID, on: database)
            return try await approval.detailedDTO(on: database)
        }
    }

    static func override(
        requestID: UUID,
        organizationID: UUID?,
        reason: String?,
        operatorName: String?,
        actorID: UUID?,
        on db: any Database
    ) async throws -> GetApprovalRequestDTO {
        let reason = try requiredText(reason, reason: "A reason is required")
        do {
            return try await db.transaction { database in
                let approval = try await lockApprovalRequest(requestID, organizationID: organizationID, on: database)
                try requirePending(approval)
                if let actorID, actorID == approval.$requestedBy.id {
                    throw Abort(.forbidden, reason: "A requester cannot override their own request")
                }
                let decision = NewDecision(
                    trackID: nil,
                    stage: nil,
                    kind: .override,
                    decidedByID: actorID,
                    operatorName: operatorName,
                    qualifyingGroupIDs: [],
                    comment: reason
                )
                try await decision.insert(requestID: requestID, on: database)
                try await applyApproved(approval, decisions: [decision], actorID: actorID, on: database)
                return try await approval.detailedDTO(on: database)
            }
        } catch let failure as ApprovalApplyFailure {
            return try await recordFailure(failure, requestID: requestID, organizationID: organizationID, on: db)
        }
    }
}

private func submitOrHold(
    _ change: ProposedChange,
    requesterID: UUID,
    organizationID: UUID,
    on db: any Database
) async throws -> (ApprovalWriteResult, GetApprovalRequestDTO?) {
    let companyIDs = try await change.companyContext(on: db)
    let changed = change.changedFields()
    let policies = try await ApprovalPolicy.query(on: db, organizationID: organizationID)
        .filter(\.$permission ~~ change.gatingPermissions.map(\.rawValue))
        .all()
    let matches = policies.filter { $0.matches(changedFields: changed, companyIDs: companyIDs) }
    if matches.isEmpty {
        let result = try await change.apply(on: db, actorID: requesterID, organizationID: organizationID)
        return (result, nil)
    }

    var stored = change
    var invitationToken: String?
    var invitationDraft: InvitationDraft?
    if case .organizationInvitationCreate(var draft) = stored {
        draft.invitationId = UUID()
        invitationToken = InvitationToken.generate()
        invitationDraft = draft
        stored = .organizationInvitationCreate(draft)
    }

    let approval = ApprovalRequest(
        organizationID: organizationID,
        permission: stored.permission.rawValue,
        targetID: stored.targetID,
        change: stored,
        status: ApprovalRequestStatus.pending.rawValue,
        requestedByID: requesterID
    )
    try await approval.save(on: db)
    let requestID = try approval.requireID()
    for policy in matches {
        guard let version = try await ApprovalPolicyVersion.query(on: db)
            .filter(\.$policy.$id == policy.requireID())
            .filter(\.$version == policy.currentVersion)
            .first()
        else {
            throw Abort(.internalServerError, reason: "Approval policy is missing its current version")
        }
        try await ApprovalRequestTrack(
            requestID: requestID,
            policyVersionID: try version.requireID(),
            currentStage: 1,
            status: ApprovalTrackStatus.pending.rawValue
        ).save(on: db)
    }

    var invitation: CreateInvitationResponse?
    if let invitationDraft, let invitationToken {
        let (created, token) = try await OrganizationInvitation.issue(
            organizationID: organizationID,
            email: invitationDraft.email,
            firstName: invitationDraft.firstName,
            lastName: invitationDraft.lastName,
            groupID: invitationDraft.groupId,
            createdByID: requesterID,
            id: invitationDraft.invitationId,
            token: invitationToken,
            approvalRequestID: requestID,
            on: db
        )
        invitation = CreateInvitationResponse(invitation: created.toGetDTO(), token: token)
    }
    return (ApprovalWriteResult(HTTPStatus.accepted), try await approval.detailedDTO(on: db, invitation: invitation))
}

private struct EligibleTrack {
    var trackID: UUID
    var stage: Int
    var qualifyingGroupIDs: [UUID]
    var definition: ApprovalPolicyDefinition
}

private func recordApprovals(
    _ approval: ApprovalRequest,
    userID: UUID,
    organizationID: UUID,
    on db: any Database
) async throws -> [NewDecision] {
    let tracks = try await eligibleTracks(
        approval,
        userID: userID,
        organizationID: organizationID,
        approving: true,
        on: db
    )
    var recorded: [NewDecision] = []
    for item in tracks {
        let decision = NewDecision(
            trackID: item.trackID,
            stage: item.stage,
            kind: .approve,
            decidedByID: userID,
            operatorName: nil,
            qualifyingGroupIDs: item.qualifyingGroupIDs,
            comment: nil
        )
        try await decision.insert(requestID: try approval.requireID(), on: db)
        recorded.append(decision)
        let approvals = try await ApprovalDecision.query(on: db)
            .filter(\.$track.$id == item.trackID)
            .filter(\.$stage == item.stage)
            .filter(\.$kind == ApprovalDecisionKind.approve.rawValue)
            .all()
        let stage = try stageSlots(item.definition, stage: item.stage)
        let complete = stageIsComplete(
            approvers: approvals.map { Set($0.qualifyingGroupIDs) },
            slots: stage.map { (groupID: $0.groupId, required: $0.required) }
        )
        if complete {
            guard let track = try await ApprovalRequestTrack.find(item.trackID, on: db) else {
                throw Abort(.internalServerError, reason: "Approval track disappeared")
            }
            if item.stage >= item.definition.stages.count {
                track.status = ApprovalTrackStatus.approved.rawValue
            } else {
                track.currentStage = item.stage + 1
            }
            try await track.save(on: db)
        }
    }
    return recorded
}

private func eligibleTracks(
    _ approval: ApprovalRequest,
    userID: UUID,
    organizationID: UUID,
    approving: Bool,
    on db: any Database
) async throws -> [EligibleTrack] {
    if approval.$requestedBy.id == userID {
        return []
    }
    let groups = try await activeGroupIDs(userID: userID, organizationID: organizationID, on: db)
    let tracks = try await ApprovalRequestTrack.query(on: db)
        .filter(\.$request.$id == approval.requireID())
        .filter(\.$status == ApprovalTrackStatus.pending.rawValue)
        .with(\.$policyVersion)
        .all()
    var eligible: [EligibleTrack] = []
    for track in tracks {
        let definition = track.policyVersion.definition
        let slots = try stageSlots(definition, stage: track.currentStage)
        let qualifying = groups.intersection(Set(slots.map(\.groupId)))
        guard !qualifying.isEmpty else { continue }
        if approving {
            let already = try await ApprovalDecision.query(on: db)
                .filter(\.$track.$id == track.requireID())
                .filter(\.$kind == ApprovalDecisionKind.approve.rawValue)
                .filter(\.$decidedBy.$id == userID)
                .first()
            guard already == nil else { continue }
        }
        eligible.append(EligibleTrack(
            trackID: try track.requireID(),
            stage: track.currentStage,
            qualifyingGroupIDs: qualifying.sorted { $0.uuidString < $1.uuidString },
            definition: definition
        ))
    }
    return eligible
}

func isCurrentApprover(_ approval: ApprovalRequest, userID: UUID, on db: any Database) async throws -> Bool {
    guard approval.status == ApprovalRequestStatus.pending.rawValue else { return false }
    let groups = try await activeGroupIDs(userID: userID, organizationID: approval.$organization.id, on: db)
    let tracks = try await ApprovalRequestTrack.query(on: db)
        .filter(\.$request.$id == approval.requireID())
        .filter(\.$status == ApprovalTrackStatus.pending.rawValue)
        .with(\.$policyVersion)
        .all()
    for track in tracks {
        let slots = (try? stageSlots(track.policyVersion.definition, stage: track.currentStage)) ?? []
        if !groups.isDisjoint(with: Set(slots.map(\.groupId))) {
            return true
        }
    }
    return false
}

private func stageSlots(_ definition: ApprovalPolicyDefinition, stage: Int) throws -> [ApprovalSlotDTO] {
    let index = stage - 1
    guard definition.stages.indices.contains(index) else {
        throw Abort(.internalServerError, reason: "Approval stage \(stage) is missing")
    }
    return definition.stages[index].slots
}

private func pendingTrackCount(_ approval: ApprovalRequest, on db: any Database) async throws -> Int {
    try await ApprovalRequestTrack.query(on: db)
        .filter(\.$request.$id == approval.requireID())
        .filter(\.$status == ApprovalTrackStatus.pending.rawValue)
        .count()
}

private func applyApproved(
    _ approval: ApprovalRequest,
    decisions: [NewDecision],
    actorID: UUID?,
    on db: any Database
) async throws {
    do {
        let requesterID = approval.$requestedBy.id
        let organizationID = approval.$organization.id
        guard try await isActiveMember(userID: requesterID, organizationID: organizationID, on: db) else {
            throw Abort(.forbidden, reason: "Requester is no longer an active member")
        }
        let permissions = try await loadPermissions(userID: requesterID, organizationID: organizationID, on: db)
        guard let permission = Permission(rawValue: approval.permission), permissions.contains(permission) else {
            throw Abort(.forbidden, reason: "Requester no longer holds \(approval.permission)")
        }
        try await approval.change.check(on: db, organizationID: organizationID)
        _ = try await approval.change.apply(on: db, actorID: requesterID, organizationID: organizationID)
        approval.status = ApprovalRequestStatus.applied.rawValue
        try await approval.save(on: db)
    } catch let abort as any AbortError {
        throw ApprovalApplyFailure(reason: abort.reason, decisions: decisions, actorID: actorID)
    }
}

private func recordFailure(
    _ failure: ApprovalApplyFailure,
    requestID: UUID,
    organizationID: UUID?,
    on db: any Database
) async throws -> GetApprovalRequestDTO {
    try await db.transaction { database in
        let approval = try await lockApprovalRequest(requestID, organizationID: organizationID, on: database)
        guard approval.status == ApprovalRequestStatus.pending.rawValue else {
            throw Abort(.conflict, reason: "Request is not pending")
        }
        for decision in failure.decisions {
            try await decision.insert(requestID: requestID, on: database)
        }
        approval.status = ApprovalRequestStatus.failed.rawValue
        approval.failureReason = failure.reason
        try await approval.save(on: database)
        try await revokeHeldInvitation(
            requestID: requestID,
            actorID: failure.actorID ?? approval.$requestedBy.id,
            on: database
        )
        return try await approval.detailedDTO(on: database)
    }
}

private func requirePending(_ approval: ApprovalRequest) throws {
    guard approval.status == ApprovalRequestStatus.pending.rawValue else {
        throw Abort(.conflict, reason: "Request is not pending")
    }
}

private func requiredText(_ value: String?, reason: String) throws -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else {
        throw Abort(.badRequest, reason: reason)
    }
    return trimmed
}

private func lockApprovalRequest(
    _ id: UUID,
    organizationID: UUID?,
    on db: any Database
) async throws -> ApprovalRequest {
    guard let sql = db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "Approvals require a SQL database")
    }
    let query = sql.select().column("id").from(ApprovalRequest.schema).where("id", .equal, SQLBind(id))
    if let organizationID {
        query.where("organization_id", .equal, SQLBind(organizationID))
    }
    let rows = try await query.for(.update).all()
    guard !rows.isEmpty, let approval = try await ApprovalRequest.find(id, on: db) else {
        throw Abort(.notFound)
    }
    if let organizationID, approval.$organization.id != organizationID {
        throw Abort(.notFound)
    }
    return approval
}

extension ApprovalRequest {
    func detailedDTO(
        on db: any Database,
        invitation: CreateInvitationResponse? = nil
    ) async throws -> GetApprovalRequestDTO {
        let loaded = try await ApprovalRequest.query(on: db)
            .filter(\.$id == requireID())
            .with(\.$tracks) { $0.with(\.$policyVersion) }
            .with(\.$decisions)
            .first()
        guard let loaded else {
            throw Abort(.notFound)
        }
        var dto = loaded.toGetDTO()
        dto.invitation = invitation
        return dto
    }
}
