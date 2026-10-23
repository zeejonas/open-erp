import Vapor

struct ApprovalCatalogEntry: Content {
    var permission: String
    var fields: [String]
    var companyScope: Bool
}

enum ApprovalRequestStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case applied
    case rejected
    case withdrawn
    case failed
}

enum ApprovalTrackStatus: String, Codable, Sendable {
    case pending
    case approved
}

enum ApprovalDecisionKind: String, Codable, Sendable {
    case approve
    case reject
    case override
}

enum ApprovalCatalog {
    static let companyScoped: Set<Permission> = [
        .companyUpdate,
        .companyDelete,
        .groupUpdate,
        .groupDelete,
        .groupMemberCreate,
        .groupMemberDelete,
        .groupRoleCreate,
        .groupRoleDelete,
        .groupCompanyCreate,
        .groupCompanyDelete,
    ]

    static let updateFields: [Permission: [String]] = [
        .organizationUpdate: ["code", "name"],
        .companyUpdate: ["code", "name"],
        .roleUpdate: ["name", "permissions"],
        .groupUpdate: ["name"],
        .approvalPolicyUpdate: ["name", "fields", "companyId", "stages"],
    ]

    static func isGateable(_ permission: Permission) -> Bool {
        !permission.isRead && permission != .approvalOverrideCreate
    }

    static func supportsCompanyScope(_ permission: Permission) -> Bool {
        companyScoped.contains(permission)
    }

    static func fields(for permission: Permission) -> [String] {
        updateFields[permission] ?? []
    }

    static var entries: [ApprovalCatalogEntry] {
        Permission.allCases.filter(isGateable).map { permission in
            ApprovalCatalogEntry(
                permission: permission.rawValue,
                fields: fields(for: permission),
                companyScope: supportsCompanyScope(permission)
            )
        }
    }
}

struct ApprovalSlotDTO: Content, Equatable {
    var groupId: UUID
    var required: Int
}

struct ApprovalStageDTO: Content, Equatable {
    var slots: [ApprovalSlotDTO]
}

struct ApprovalPolicyDefinition: Content, Equatable {
    var name: String
    var permission: String
    var fields: [String]
    var companyId: UUID?
    var stages: [ApprovalStageDTO]

    func normalized() -> ApprovalPolicyDefinition {
        var copy = self
        copy.fields = Array(Set(fields)).sorted()
        copy.stages = stages.map { stage in
            ApprovalStageDTO(slots: stage.slots.sorted { $0.groupId.uuidString < $1.groupId.uuidString })
        }
        return copy
    }

    func changedFields(from before: ApprovalPolicyDefinition) -> Set<String> {
        let after = normalized()
        let prior = before.normalized()
        var changed: Set<String> = []
        if prior.name != after.name { changed.insert("name") }
        if Set(prior.fields) != Set(after.fields) { changed.insert("fields") }
        if prior.companyId != after.companyId { changed.insert("companyId") }
        if prior.stages != after.stages { changed.insert("stages") }
        return changed
    }
}

extension ApprovalPolicyDefinition: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add(
            "name",
            as: String.self,
            is: !.empty && .count(1...100),
            customFailureDescription: "Name must be 1-100 characters"
        )
        validations.add("permission", as: String.self, is: !.empty, customFailureDescription: "permission is required")
    }
}

struct CodeNameSnapshot: Codable, Equatable, Sendable {
    var code: String
    var name: String
}

struct RoleSnapshot: Codable, Equatable, Sendable {
    var name: String
    var permissions: [String]
}

struct RoleDraft: Codable, Equatable, Sendable {
    var name: String
    var level: String
    var permissions: [String]
}

struct GroupSnapshot: Codable, Equatable, Sendable {
    var name: String
}

struct InvitationDraft: Codable, Equatable, Sendable {
    var email: String
    var firstName: String
    var lastName: String
    var groupId: UUID?
    var invitationId: UUID?
}

struct GroupMemberDraft: Codable, Equatable, Sendable {
    var groupId: UUID
    var userId: UUID
}

struct GroupRoleDraft: Codable, Equatable, Sendable {
    var groupId: UUID
    var roleId: UUID
}

struct GroupCompanyDraft: Codable, Equatable, Sendable {
    var groupId: UUID
    var companyId: UUID
}
