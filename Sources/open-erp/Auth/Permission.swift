import Vapor

enum RoleLevel: String, Codable, CaseIterable, Sendable {
    case organization
    case company
}

enum Permission: String, Codable, CaseIterable, Sendable {
    case organizationRead = "organization:read"
    case organizationUpdate = "organization:update"
    case organizationDelete = "organization:delete"
    case companyCreate = "company:create"
    case companyRead = "company:read"
    case companyUpdate = "company:update"
    case companyDelete = "company:delete"
    case organizationUserRead = "organization_user:read"
    case organizationUserDelete = "organization_user:delete"
    case organizationInvitationCreate = "organization_invitation:create"
    case organizationInvitationRead = "organization_invitation:read"
    case organizationInvitationDelete = "organization_invitation:delete"
    case roleCreate = "role:create"
    case roleRead = "role:read"
    case roleUpdate = "role:update"
    case roleDelete = "role:delete"
    case groupCreate = "group:create"
    case groupRead = "group:read"
    case groupUpdate = "group:update"
    case groupDelete = "group:delete"
    case groupMemberCreate = "group_member:create"
    case groupMemberRead = "group_member:read"
    case groupMemberDelete = "group_member:delete"
    case groupRoleCreate = "group_role:create"
    case groupRoleDelete = "group_role:delete"
    case groupCompanyCreate = "group_company:create"
    case groupCompanyDelete = "group_company:delete"
    case approvalPolicyCreate = "approval_policy:create"
    case approvalPolicyRead = "approval_policy:read"
    case approvalPolicyUpdate = "approval_policy:update"
    case approvalPolicyDelete = "approval_policy:delete"
    case approvalRequestRead = "approval_request:read"
    case approvalOverrideCreate = "approval_override:create"

    /// Every permission shipped in this change is organization-wide.
    /// Company-scoped permissions arrive with company-level enforcement.
    var level: RoleLevel { .organization }

    var isRead: Bool { rawValue.hasSuffix(":read") }
}

struct RoleTemplate: Sendable {
    var key: String
    var name: String
    var level: RoleLevel
    var permissions: [Permission]

    static let organizationAdministrator = RoleTemplate(
        key: "org_admin",
        name: "Organization Administrator",
        level: .organization,
        permissions: Permission.allCases.filter { $0.level == .organization }
    )

    static let organizationViewer = RoleTemplate(
        key: "org_viewer",
        name: "Organization Viewer",
        level: .organization,
        permissions: Permission.allCases.filter { $0.level == .organization && $0.isRead }
    )

    static let all = [organizationAdministrator, organizationViewer]
}

struct GroupTemplate: Sendable {
    var key: String
    var name: String
    var roleKeys: [String]

    static let organizationAdministrators = GroupTemplate(
        key: "org_admins",
        name: "Organization Administrators",
        roleKeys: [RoleTemplate.organizationAdministrator.key]
    )

    static let organizationViewers = GroupTemplate(
        key: "org_viewers",
        name: "Organization Viewers",
        roleKeys: [RoleTemplate.organizationViewer.key]
    )

    static let all = [organizationAdministrators, organizationViewers]
}

func permissions(from rawValues: [String], level: RoleLevel) throws -> [Permission] {
    var resolved: [Permission] = []
    var seen: Set<Permission> = []
    for rawValue in rawValues {
        guard let permission = Permission(rawValue: rawValue) else {
            throw Abort(.badRequest, reason: "Unknown permission \(rawValue)")
        }
        guard permission.level == level else {
            throw Abort(.badRequest, reason: "Permission \(rawValue) does not match role level \(level.rawValue)")
        }
        if seen.insert(permission).inserted {
            resolved.append(permission)
        }
    }
    return resolved
}
