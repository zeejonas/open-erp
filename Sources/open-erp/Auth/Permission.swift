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
    case organizationRoleAssignmentCreate = "organization_role_assignment:create"
    case organizationRoleAssignmentRead = "organization_role_assignment:read"
    case organizationRoleAssignmentDelete = "organization_role_assignment:delete"

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
