import Fluent
import Vapor

private let subjectTaken = "Subject is already bound to another user"

/// Check and apply steps for service account changes, run at submission and again when a held change applies.
enum ServiceAccountChanges {
    static func require(_ id: UUID, organizationID: UUID, on db: any Database) async throws -> (ServiceAccount, User) {
        guard let account = try await ServiceAccount.query(on: db, organizationID: organizationID).filter(\.$id == id).first(),
              let user = try await User.find(id, on: db)
        else {
            throw Abort(.notFound)
        }
        return (account, user)
    }

    static func snapshot(_ account: ServiceAccount, user: User) -> ServiceAccountSnapshot {
        .init(
            name: user.firstName,
            description: account.description,
            ownerId: account.$owner.id,
            subject: user.authSubject ?? "",
            enabled: account.disabledAt == nil
        )
    }

    /// The owner must be an active person member of the organization.
    static func validateOwner(_ ownerID: UUID, organizationID: UUID, on db: any Database) async throws {
        guard try await User.query(on: db, organizationID: organizationID)
            .filter(\.$id == ownerID).filter(\.$kind == .person).first() != nil
        else {
            throw Abort(.badRequest, reason: "ownerId must be an active person member of this organization")
        }
    }

    /// A subject binds at most one user, including deleted people, so the conflict surfaces before the unique index.
    static func validateSubject(_ subject: String, on db: any Database) async throws {
        if try await User.query(on: db).withDeleted().filter(\.$authSubject == subject).first() != nil {
            throw Abort(.conflict, reason: subjectTaken)
        }
    }

    static func checkUpdate(id: UUID, before: ServiceAccountSnapshot, after: ServiceAccountSnapshot, organizationID: UUID, on db: any Database) async throws {
        let (account, user) = try await require(id, organizationID: organizationID, on: db)
        let current = snapshot(account, user: user)
        let changed = after.changedFields(from: before)
        try throwIfStale(changed.contains("name") && current.name != before.name)
        try throwIfStale(changed.contains("description") && current.description != before.description)
        try throwIfStale(changed.contains("ownerId") && current.ownerId != before.ownerId)
        try throwIfStale(changed.contains("subject") && current.subject != before.subject)
        try throwIfStale(changed.contains("enabled") && current.enabled != before.enabled)
        if changed.contains("ownerId") { try await validateOwner(after.ownerId, organizationID: organizationID, on: db) }
        if changed.contains("subject") { try await validateSubject(after.subject, on: db) }
    }

    static func create(_ snapshot: ServiceAccountSnapshot, organizationID: UUID, actorID: UUID, on db: any Database) async throws -> ServiceAccountDTO {
        let id = UUID()
        let user = User(firstName: snapshot.name, lastName: "", email: ServiceAccount.email(for: id), authSubject: snapshot.subject, kind: .service)
        user.id = id
        user.$createdBy.id = actorID
        try await conflictOnDuplicate(subjectTaken) {
            try await user.create(on: db)
        }
        try await OrganizationUser(organizationID: organizationID, userID: id, createdByID: actorID).create(on: db)
        let account = ServiceAccount(id: id, organizationID: organizationID, ownerID: snapshot.ownerId, description: snapshot.description, createdByID: actorID)
        try await account.create(on: db)
        return try ServiceAccountDTO(account, user: user)
    }

    static func update(id: UUID, before: ServiceAccountSnapshot, after: ServiceAccountSnapshot, organizationID: UUID, actorID: UUID, on db: any Database) async throws -> ServiceAccountDTO {
        let (account, user) = try await require(id, organizationID: organizationID, on: db)
        let changed = after.changedFields(from: before)
        if changed.contains("name") { user.firstName = after.name }
        if changed.contains("subject") { user.authSubject = after.subject }
        if changed.contains("description") { account.description = after.description }
        if changed.contains("ownerId") { account.$owner.id = after.ownerId }
        if changed.contains("enabled") {
            account.disabledAt = after.enabled ? nil : Date()
            account.$disabledBy.id = after.enabled ? nil : actorID
        }
        if user.hasChanges {
            user.$updatedBy.id = actorID
            try await conflictOnDuplicate(subjectTaken) {
                try await user.update(on: db)
            }
        }
        if account.hasChanges {
            account.$updatedBy.id = actorID
            try await account.update(on: db)
        }
        return try ServiceAccountDTO(account, user: user)
    }

    /// Takes effect immediately and is never held, so an integration can be shut down without waiting for approval.
    static func disable(id: UUID, organizationID: UUID, actorID: UUID, on db: any Database) async throws {
        let (account, _) = try await require(id, organizationID: organizationID, on: db)
        guard account.disabledAt == nil else { return }
        account.disabledAt = Date()
        account.$disabledBy.id = actorID
        account.$updatedBy.id = actorID
        try await account.update(on: db)
    }

    /// Ends the membership and group memberships, keeps attribution on records the account wrote, and releases the subject.
    static func delete(id: UUID, organizationID: UUID, actorID: UUID, on db: any Database) async throws {
        let (account, user) = try await require(id, organizationID: organizationID, on: db)
        if let membership = try await OrganizationUser.query(on: db, organizationID: organizationID).filter(\.$user.$id == id).first() {
            let membershipID = try membership.requireID()
            for groupMembership in try await GroupMember.query(on: db).filter(\.$organizationUser.$id == membershipID).all() {
                try await groupMembership.softDelete(by: actorID, \.$deletedBy, on: db)
                try await groupMembership.emit(.groupMemberDeleted, on: db)
            }
            try await membership.softDelete(by: actorID, \.$deletedBy, on: db)
        }
        try await account.softDelete(by: actorID, \.$deletedBy, on: db)
        user.authSubject = nil
        try await user.softDelete(by: actorID, \.$deletedBy, on: db)
    }
}
