import Fluent
import Vapor

private struct OrganizationIDKey: StorageKey {
    typealias Value = UUID
}

extension Request {
    var organizationID: UUID {
        get {
            guard let id = self.storage[OrganizationIDKey.self] else {
                fatalError("OrganizationMiddleware must run before accessing req.organizationID")
            }
            return id
        }
        set {
            self.storage[OrganizationIDKey.self] = newValue
        }
    }
}

/// Reads `X-Organization-ID` and requires an active membership in a non-deleted organization.
/// Unknown organizations, missing memberships, removed memberships, and deleted organizations
/// all respond `403` so existence is not disclosed.
struct OrganizationMiddleware: AsyncMiddleware {
    static let headerName = "X-Organization-ID"

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let user = request.authenticatedUser else {
            throw Abort(.unauthorized)
        }
        guard let raw = request.headers.first(name: Self.headerName) else {
            throw Abort(.badRequest, reason: "Missing \(Self.headerName) header")
        }
        guard let organizationID = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "\(Self.headerName) must be a UUID")
        }

        let userID = try user.requireID()
        guard try await OrganizationUser.query(on: request.db)
            .join(Organization.self, on: \OrganizationUser.$organization.$id == \Organization.$id)
            .filter(\.$user.$id == userID)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$deletedAt == nil)
            .filter(Organization.self, \.$deletedAt == nil)
            .first() != nil
        else {
            throw Abort(.forbidden)
        }

        request.organizationID = organizationID
        request.permissions = try await loadPermissions(userID: userID, organizationID: organizationID, on: request.db)
        return try await next.respond(to: request)
    }
}

func isActiveMember(userID: UUID, organizationID: UUID, on db: any Database) async throws -> Bool {
    try await OrganizationUser.query(on: db)
        .join(Organization.self, on: \OrganizationUser.$organization.$id == \Organization.$id)
        .filter(\.$user.$id == userID)
        .filter(\.$organization.$id == organizationID)
        .filter(\.$deletedAt == nil)
        .filter(Organization.self, \.$deletedAt == nil)
        .first() != nil
}

/// Fluent soft-deletes only the base model, so every joined table filters `deleted_at` itself.
/// Company eligibility is stored on `group_companies` and is not read here until a company-level permission exists.
func loadPermissions(userID: UUID, organizationID: UUID, on db: any Database) async throws -> Set<Permission> {
    let grants = try await RolePermission.query(on: db)
        .join(Role.self, on: \RolePermission.$role.$id == \Role.$id)
        .join(GroupRole.self, on: \Role.$id == \GroupRole.$role.$id)
        .join(AccessGroup.self, on: \GroupRole.$group.$id == \AccessGroup.$id)
        .join(GroupMember.self, on: \AccessGroup.$id == \GroupMember.$group.$id)
        .join(OrganizationUser.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
        .filter(OrganizationUser.self, \.$user.$id == userID)
        .filter(OrganizationUser.self, \.$organization.$id == organizationID)
        .filter(OrganizationUser.self, \.$deletedAt == nil)
        .filter(Role.self, \.$organization.$id == organizationID)
        .filter(Role.self, \.$level == RoleLevel.organization.rawValue)
        .filter(Role.self, \.$deletedAt == nil)
        .filter(GroupRole.self, \.$deletedAt == nil)
        .filter(AccessGroup.self, \.$organization.$id == organizationID)
        .filter(AccessGroup.self, \.$deletedAt == nil)
        .filter(GroupMember.self, \.$deletedAt == nil)
        .all()
    return Set(grants.compactMap { Permission(rawValue: $0.permission) })
}

func activeGroupIDs(userID: UUID, organizationID: UUID, on db: any Database) async throws -> Set<UUID> {
    let memberships = try await GroupMember.query(on: db)
        .join(OrganizationUser.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
        .join(AccessGroup.self, on: \GroupMember.$group.$id == \AccessGroup.$id)
        .filter(OrganizationUser.self, \.$user.$id == userID)
        .filter(OrganizationUser.self, \.$organization.$id == organizationID)
        .filter(OrganizationUser.self, \.$deletedAt == nil)
        .filter(AccessGroup.self, \.$organization.$id == organizationID)
        .filter(AccessGroup.self, \.$deletedAt == nil)
        .all()
    return Set(memberships.map(\.$group.id))
}

func activeMemberCount(groupID: UUID, on db: any Database) async throws -> Int {
    try await GroupMember.query(on: db)
        .join(OrganizationUser.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
        .filter(\.$group.$id == groupID)
        .filter(OrganizationUser.self, \.$deletedAt == nil)
        .count()
}
