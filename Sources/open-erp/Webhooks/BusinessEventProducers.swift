import Fluent
import Vapor

/// Explicitly invoked by semantic operations, never by storage lifecycle hooks.
protocol BusinessEventSource: Model where IDValue == UUID {
    var eventOrganizationID: UUID { get throws }
    func eventSummary(on db: any Database) async throws -> BusinessEventSummary
}

extension BusinessEventSource {
    func emit(_ type: BusinessEventType, changedFields: Set<String> = [], on db: any Database) async throws {
        try await BusinessEventWriter.write(type, resourceID: requireID(), organizationID: eventOrganizationID,
            changedFields: Array(changedFields), data: eventSummary(on: db), on: db)
    }
}

extension Organization: BusinessEventSource {
    var eventOrganizationID: UUID { get throws { try requireID() } }
    func eventSummary(on db: any Database) async throws -> BusinessEventSummary {
        .organization(code: code, name: name, deleted: deletedAt != nil)
    }
}
extension Company: BusinessEventSource {
    var eventOrganizationID: UUID { $organization.id }
    func eventSummary(on db: any Database) async throws -> BusinessEventSummary {
        .company(code: code, name: name, deleted: deletedAt != nil)
    }
}
extension Role: BusinessEventSource {
    var eventOrganizationID: UUID { $organization.id }
    func eventSummary(on db: any Database) async throws -> BusinessEventSummary {
        guard let level = RoleLevel(rawValue: level) else { throw Abort(.internalServerError) }
        return .role(name: name, level: level, deleted: deletedAt != nil)
    }
}
extension AccessGroup: BusinessEventSource {
    var eventOrganizationID: UUID { $organization.id }
    func eventSummary(on db: any Database) async throws -> BusinessEventSummary {
        .group(name: name, deleted: deletedAt != nil)
    }
}
extension OrganizationUser: BusinessEventSource {
    var eventOrganizationID: UUID { $organization.id }
    func eventSummary(on db: any Database) async throws -> BusinessEventSummary { .organizationUser(userId: $user.id) }
}
extension GroupMember: BusinessEventSource {
    var eventOrganizationID: UUID { $organization.id }
    func eventSummary(on db: any Database) async throws -> BusinessEventSummary {
        guard let membership = try await OrganizationUser.query(on: db, organizationID: $organization.id)
            .withDeleted().filter(\.$id == $organizationUser.id).first() else { throw Abort(.internalServerError) }
        return .groupMember(groupId: $group.id, userId: membership.$user.id)
    }
}
extension GroupRole: BusinessEventSource {
    var eventOrganizationID: UUID { $organization.id }
    func eventSummary(on db: any Database) async throws -> BusinessEventSummary { .groupRole(groupId: $group.id, roleId: $role.id) }
}
extension GroupCompany: BusinessEventSource {
    var eventOrganizationID: UUID { $organization.id }
    func eventSummary(on db: any Database) async throws -> BusinessEventSummary { .groupCompany(groupId: $group.id, companyId: $company.id) }
}
extension ApprovalPolicy: BusinessEventSource {
    var eventOrganizationID: UUID { $organization.id }
    func eventSummary(on db: any Database) async throws -> BusinessEventSummary {
        .approvalPolicy(name: name, permission: permission, currentVersion: currentVersion, deleted: deletedAt != nil)
    }
}
extension OrganizationInvitation: BusinessEventSource {
    var eventOrganizationID: UUID { $organization.id }
    func eventSummary(on db: any Database) async throws -> BusinessEventSummary {
        .invitation(groupId: $group.id, status: deletedAt != nil ? "revoked" : acceptedAt != nil ? "accepted" : "pending", expiresAt: expiresAt)
    }
}

extension ApprovalRequest {
    func emit(_ type: BusinessEventType, decision: ApprovalDecision? = nil, on db: any Database) async throws {
        try await BusinessEventWriter.write(type, resourceID: requireID(), organizationID: $organization.id,
            data: .approvalRequest(permission: permission, targetId: targetID, status: status,
                decisionId: decision?.id, decisionKind: decision?.kind), on: db)
    }
}
