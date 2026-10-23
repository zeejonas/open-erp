import Fluent
import Vapor

final class ApprovalPolicy: Model, @unchecked Sendable {
    static let schema = "approval_policies"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "organization_id")
    var organization: Organization

    @Field(key: "name")
    var name: String

    @Field(key: "permission")
    var permission: String

    @Field(key: "fields")
    var fields: [String]

    @OptionalParent(key: "company_id")
    var company: Company?

    @Field(key: "current_version")
    var currentVersion: Int

    @Children(for: \.$policy)
    var slots: [ApprovalPolicySlot]

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "updated_by") var updatedBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(
        organizationID: UUID,
        name: String,
        permission: String,
        fields: [String],
        companyID: UUID?,
        currentVersion: Int,
        createdByID: UUID?
    ) {
        self.$organization.id = organizationID
        self.name = name
        self.permission = permission
        self.fields = fields
        self.$company.id = companyID
        self.currentVersion = currentVersion
        self.$createdBy.id = createdByID
    }

    static func query(on db: any Database, organizationID: UUID) -> QueryBuilder<ApprovalPolicy> {
        query(on: db).filter(\.$organization.$id == organizationID)
    }

    func matches(changedFields: Set<String>, companyIDs: Set<UUID>) -> Bool {
        if !fields.isEmpty && Set(fields).isDisjoint(with: changedFields) {
            return false
        }
        if let companyID = $company.id, !companyIDs.contains(companyID) {
            return false
        }
        return true
    }

    func currentDefinition() -> ApprovalPolicyDefinition {
        let grouped = Dictionary(grouping: slots, by: \.stage)
        let stages = grouped.keys.sorted().map { stage in
            ApprovalStageDTO(slots: grouped[stage, default: []].map { slot in
                ApprovalSlotDTO(groupId: slot.$group.id, required: slot.required)
            }.sorted { $0.groupId.uuidString < $1.groupId.uuidString })
        }
        return ApprovalPolicyDefinition(
            name: name,
            permission: permission,
            fields: fields.sorted(),
            companyId: $company.id,
            stages: stages
        ).normalized()
    }

    func toGetDTO() -> GetApprovalPolicyDTO {
        let definition = currentDefinition()
        return GetApprovalPolicyDTO(
            id: id,
            name: definition.name,
            permission: definition.permission,
            fields: definition.fields,
            companyId: definition.companyId,
            currentVersion: currentVersion,
            stages: definition.stages,
            createdById: $createdBy.id,
            updatedById: $updatedBy.id,
            deletedById: $deletedBy.id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}

final class ApprovalPolicySlot: Model, @unchecked Sendable {
    static let schema = "approval_policy_slots"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "policy_id")
    var policy: ApprovalPolicy

    @Field(key: "stage")
    var stage: Int

    @Parent(key: "group_id")
    var group: AccessGroup

    @Field(key: "required")
    var required: Int

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(policyID: UUID, stage: Int, groupID: UUID, required: Int, createdByID: UUID?) {
        self.$policy.id = policyID
        self.stage = stage
        self.$group.id = groupID
        self.required = required
        self.$createdBy.id = createdByID
    }
}

final class ApprovalPolicyVersion: Model, @unchecked Sendable {
    static let schema = "approval_policy_versions"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "policy_id")
    var policy: ApprovalPolicy

    @Field(key: "version")
    var version: Int

    @Field(key: "definition")
    var definition: ApprovalPolicyDefinition

    @OptionalParent(key: "created_by") var createdBy: User?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(policyID: UUID, version: Int, definition: ApprovalPolicyDefinition, createdByID: UUID?) {
        self.$policy.id = policyID
        self.version = version
        self.definition = definition
        self.$createdBy.id = createdByID
    }

    func toGetDTO() -> GetApprovalPolicyVersionDTO {
        GetApprovalPolicyVersionDTO(
            id: id,
            policyId: $policy.id,
            version: version,
            definition: definition,
            createdById: $createdBy.id,
            createdAt: createdAt
        )
    }
}

final class ApprovalRequest: Model, @unchecked Sendable {
    static let schema = "approval_requests"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "organization_id")
    var organization: Organization

    @Field(key: "permission")
    var permission: String

    @OptionalField(key: "target_id")
    var targetID: UUID?

    @Field(key: "change")
    var change: ProposedChange

    @Field(key: "status")
    var status: String

    @OptionalField(key: "failure_reason")
    var failureReason: String?

    @Parent(key: "requested_by")
    var requestedBy: User

    @Children(for: \.$request)
    var tracks: [ApprovalRequestTrack]

    @Children(for: \.$request)
    var decisions: [ApprovalDecision]

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        organizationID: UUID,
        permission: String,
        targetID: UUID?,
        change: ProposedChange,
        status: String,
        requestedByID: UUID
    ) {
        self.$organization.id = organizationID
        self.permission = permission
        self.targetID = targetID
        self.change = change
        self.status = status
        self.$requestedBy.id = requestedByID
    }

    static func query(on db: any Database, organizationID: UUID) -> QueryBuilder<ApprovalRequest> {
        query(on: db).filter(\.$organization.$id == organizationID)
    }

    func toGetDTO() -> GetApprovalRequestDTO {
        GetApprovalRequestDTO(
            id: id,
            permission: permission,
            targetId: targetID,
            status: status,
            failureReason: failureReason,
            requestedBy: $requestedBy.id,
            change: change,
            tracks: tracks.map { $0.toGetDTO() },
            decisions: decisions.map { $0.toGetDTO() },
            createdAt: createdAt,
            updatedAt: updatedAt,
            invitation: nil
        )
    }
}

final class ApprovalRequestTrack: Model, @unchecked Sendable {
    static let schema = "approval_request_tracks"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "request_id")
    var request: ApprovalRequest

    @Parent(key: "policy_version_id")
    var policyVersion: ApprovalPolicyVersion

    @Field(key: "current_stage")
    var currentStage: Int

    @Field(key: "status")
    var status: String

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(requestID: UUID, policyVersionID: UUID, currentStage: Int, status: String) {
        self.$request.id = requestID
        self.$policyVersion.id = policyVersionID
        self.currentStage = currentStage
        self.status = status
    }

    func toGetDTO() -> GetApprovalTrackDTO {
        GetApprovalTrackDTO(
            id: id,
            policyVersionId: $policyVersion.id,
            version: policyVersion.version,
            definition: policyVersion.definition,
            currentStage: currentStage,
            status: status
        )
    }
}

final class ApprovalDecision: Model, @unchecked Sendable {
    static let schema = "approval_decisions"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "request_id")
    var request: ApprovalRequest

    @OptionalParent(key: "track_id")
    var track: ApprovalRequestTrack?

    @OptionalField(key: "stage")
    var stage: Int?

    @Field(key: "kind")
    var kind: String

    @OptionalParent(key: "decided_by")
    var decidedBy: User?

    @OptionalField(key: "operator")
    var operatorName: String?

    @Field(key: "qualifying_group_ids")
    var qualifyingGroupIDs: [UUID]

    @OptionalField(key: "comment")
    var comment: String?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        requestID: UUID,
        trackID: UUID?,
        stage: Int?,
        kind: String,
        decidedByID: UUID?,
        operatorName: String?,
        qualifyingGroupIDs: [UUID],
        comment: String?
    ) {
        self.$request.id = requestID
        self.$track.id = trackID
        self.stage = stage
        self.kind = kind
        self.$decidedBy.id = decidedByID
        self.operatorName = operatorName
        self.qualifyingGroupIDs = qualifyingGroupIDs
        self.comment = comment
    }

    func toGetDTO() -> GetApprovalDecisionDTO {
        GetApprovalDecisionDTO(
            id: id,
            trackId: $track.id,
            stage: stage,
            kind: kind,
            decidedBy: $decidedBy.id,
            operator: operatorName,
            qualifyingGroupIds: qualifyingGroupIDs,
            comment: comment,
            createdAt: createdAt
        )
    }
}
