import Vapor

struct GetApprovalPolicyDTO: Content {
    var id: UUID?
    var name: String
    var permission: String
    var fields: [String]
    var companyId: UUID?
    var currentVersion: Int
    var stages: [ApprovalStageDTO]
    var createdById: UUID?
    var updatedById: UUID?
    var deletedById: UUID?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?
}

struct GetApprovalPolicyVersionDTO: Content {
    var id: UUID?
    var policyId: UUID
    var version: Int
    var definition: ApprovalPolicyDefinition
    var createdById: UUID?
    var createdAt: Date?
}

struct GetApprovalTrackDTO: Content {
    var id: UUID?
    var policyVersionId: UUID
    var version: Int
    var definition: ApprovalPolicyDefinition
    var currentStage: Int
    var status: String
}

struct GetApprovalDecisionDTO: Content {
    var id: UUID?
    var trackId: UUID?
    var stage: Int?
    var kind: String
    var decidedBy: UUID?
    var `operator`: String?
    var qualifyingGroupIds: [UUID]
    var comment: String?
    var createdAt: Date?
}

struct GetApprovalRequestDTO: Content {
    var id: UUID?
    var permission: String
    var targetId: UUID?
    var status: String
    var failureReason: String?
    var requestedBy: UUID
    var change: ProposedChange
    var tracks: [GetApprovalTrackDTO]
    var decisions: [GetApprovalDecisionDTO]
    var createdAt: Date?
    var updatedAt: Date?
    var invitation: CreateInvitationResponse?
}

struct ApprovalCommentDTO: Content {
    var comment: String?
}

struct ApprovalOverrideDTO: Content {
    var reason: String?
}
