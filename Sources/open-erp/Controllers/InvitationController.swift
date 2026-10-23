import Fluent
import Vapor

struct InvitationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("invitations", "accept", use: self.accept)

        let invitations = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("organization-invitations")
        invitations.post(use: self.create)
        invitations.get(use: self.index)
        invitations.group(":invitationID") { invitation in
            invitation.delete(use: self.revoke)
        }
    }

    @Sendable
    func create(req: Request) async throws -> CreateInvitationResponse {
        try req.require(.organizationInvitationCreate)
        try CreateInvitationDTO.validate(content: req)
        let dto = try req.content.decode(CreateInvitationDTO.self)
        if let groupID = dto.groupId {
            try await requireActiveGroup(groupID, on: req)
        }

        let (invitation, token) = try await OrganizationInvitation.issue(
            organizationID: req.organizationID,
            email: dto.email,
            firstName: dto.firstName,
            lastName: dto.lastName,
            groupID: dto.groupId,
            createdByID: try req.userID(),
            on: req.db
        )
        return CreateInvitationResponse(invitation: invitation.toGetDTO(), token: token)
    }

    @Sendable
    func index(req: Request) async throws -> Page<GetInvitationDTO> {
        try req.require(.organizationInvitationRead)
        let (filters, page) = try req.listParameters(InvitationListFilters.self)
        var invitations = OrganizationInvitation.pending(on: req.db)
            .filter(\.$organization.$id == req.organizationID)
            .filter(\.$email, contains: filters.email)
        if let groupID = filters.groupId {
            invitations = invitations.filter(\.$group.$id == groupID)
        }
        return try await invitations
            .newestFirst(\.$createdAt)
            .paginate(page)
            .map { $0.toGetDTO() }
    }

    @Sendable
    func revoke(req: Request) async throws -> HTTPStatus {
        try req.require(.organizationInvitationDelete)
        guard let invitationID = req.parameters.get("invitationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid invitation ID")
        }
        guard let invitation = try await OrganizationInvitation.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$id == invitationID)
            .filter(\.$acceptedAt == nil)
            .first()
        else {
            throw Abort(.notFound)
        }
        try await invitation.softDelete(by: req.userID(), \.$deletedBy, on: req.db)
        return .noContent
    }

    @Sendable
    func accept(req: Request) async throws -> AcceptInvitationResponse {
        let token = try await req.verifiedAccessToken()
        try AcceptInvitationDTO.validate(content: req)
        let dto = try req.content.decode(AcceptInvitationDTO.self)

        guard let invitation = try await OrganizationInvitation.pending(on: req.db)
            .filter(\.$tokenHash == InvitationToken.hash(dto.token))
            .first()
        else {
            throw Abort(.notFound)
        }

        let userInfo = try await req.application.userInfoFetcher.fetch(req)
        guard userInfo.emailVerified, userInfo.email?.lowercased() == invitation.email.lowercased() else {
            throw Abort(.forbidden)
        }

        return try await conflictOnDuplicate("User is already a member of this organization") {
            try await req.db.transaction { db in
                // Re-read so a revocation or acceptance that landed during the userinfo call wins.
                guard let current = try await OrganizationInvitation.pending(on: db)
                    .filter(\.$id == invitation.requireID())
                    .first()
                else {
                    throw Abort(.notFound)
                }

                let organizationID = current.$organization.id
                if let groupID = current.$group.id {
                    guard try await AccessGroup.query(on: db, organizationID: organizationID)
                        .filter(\.$id == groupID)
                        .first() != nil
                    else {
                        throw Abort(.badRequest, reason: "Invitation group is not an active group in this organization")
                    }
                }

                let user = try await resolveUser(subject: token.subjectID, invitation: current, on: db)
                let userID = try user.requireID()

                let membership = OrganizationUser(organizationID: organizationID, userID: userID, createdByID: userID)
                try await membership.save(on: db)

                if let groupID = current.$group.id {
                    try await GroupMember(
                        groupID: groupID,
                        organizationUserID: try membership.requireID(),
                        createdByID: userID
                    ).save(on: db)
                }

                current.acceptedAt = Date()
                current.$acceptedBy.id = userID
                try await current.save(on: db)

                return AcceptInvitationResponse(user: user.toGetDTO(), organizationId: organizationID)
            }
        }
    }
}

private func requireActiveGroup(_ groupID: UUID, on req: Request) async throws {
    guard try await AccessGroup.query(on: req.db, organizationID: req.organizationID)
        .filter(\.$id == groupID)
        .first() != nil
    else {
        throw Abort(.badRequest, reason: "Group must be an active group in this organization")
    }
}

private func resolveUser(
    subject: String,
    invitation: OrganizationInvitation,
    on db: any Database
) async throws -> User {
    let bySubject = try await User.query(on: db).filter(\.$authSubject == subject).first()
    let byEmail = try await User.find(email: invitation.email, on: db)

    if let byEmail, let bound = byEmail.authSubject, bound != subject {
        throw Abort(.conflict, reason: "Email is bound to a different account")
    }
    if let bySubject, let byEmail, bySubject.id != byEmail.id {
        throw Abort(.conflict, reason: "Email is bound to a different account")
    }

    if let bySubject {
        return bySubject
    }
    if let byEmail {
        byEmail.authSubject = subject
        try await byEmail.save(on: db)
        return byEmail
    }

    let created = User(
        firstName: invitation.firstName,
        lastName: invitation.lastName,
        email: invitation.email,
        authSubject: subject
    )
    try await created.save(on: db)
    return created
}
