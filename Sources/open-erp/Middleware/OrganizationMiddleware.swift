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

/// Fluent soft-deletes only the base model, so every joined table filters `deleted_at` itself.
private func loadPermissions(userID: UUID, organizationID: UUID, on db: any Database) async throws -> Set<Permission> {
    let grants = try await RolePermission.query(on: db)
        .join(Role.self, on: \RolePermission.$role.$id == \Role.$id)
        .join(OrganizationRoleAssignment.self, on: \Role.$id == \OrganizationRoleAssignment.$role.$id)
        .join(OrganizationUser.self, on: \OrganizationRoleAssignment.$organizationUser.$id == \OrganizationUser.$id)
        .filter(OrganizationUser.self, \.$user.$id == userID)
        .filter(OrganizationUser.self, \.$organization.$id == organizationID)
        .filter(OrganizationUser.self, \.$deletedAt == nil)
        .filter(Role.self, \.$organization.$id == organizationID)
        .filter(Role.self, \.$deletedAt == nil)
        .filter(OrganizationRoleAssignment.self, \.$deletedAt == nil)
        .all()
    return Set(grants.compactMap { Permission(rawValue: $0.permission) })
}
