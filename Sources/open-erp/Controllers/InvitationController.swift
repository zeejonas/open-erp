import Fluent
import Vapor
import VaporToOpenAPI

struct InvitationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("invitations", "accept", use: self.accept)
            .openAPI(
                summary: "Accept invitation",
                description: "Requires a bearer access token and a matching verified email from the identity provider; no existing membership is needed.",
                body: .type(AcceptInvitationDTO.self),
                response: .type(AcceptInvitationResponse.self),
                auth: .bearer()
            )

        let invitations = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("organization-invitations")
        invitations.post(use: self.create)
            .openAPI(
                summary: "Create invitation",
                description: "Requires organization_invitation:create. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                headers: .type(OrganizationHeaders.self),
                body: .type(CreateInvitationDTO.self),
                response: .type(CreateInvitationResponse.self),
                auth: .bearer()
            )
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        invitations.get(use: self.index)
            .openAPI(
                summary: "List invitations",
                description: "Requires organization_invitation:read. Newest createdAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.",
                query: [.type(ListPage.self), .type(InvitationListFilters.self)],
                headers: .type(OrganizationHeaders.self),
                response: .type(Page<GetInvitationDTO>.self),
                auth: .bearer()
            )
        invitations.group(":invitationID") { invitation in
            invitation.delete(use: self.revoke)
                .openAPI(
                    summary: "Revoke invitation",
                    description: "Requires organization_invitation:delete. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                    headers: .type(OrganizationHeaders.self),
                    responseDescription: "Deleted",
                    statusCode: 204,
                    auth: .bearer()
                )
                .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        }
    }

    @Sendable
    func create(req: Request) async throws -> ApprovalOutcome<CreateInvitationResponse> {
        try req.require(.organizationInvitationCreate)
        try CreateInvitationDTO.validate(content: req)
        let dto = try req.content.decode(CreateInvitationDTO.self)
        return try await req.approvals.submit(.organizationInvitationCreate(InvitationDraft(
            email: dto.email,
            firstName: dto.firstName,
            lastName: dto.lastName,
            groupId: dto.groupId,
            invitationId: nil
        )))
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
    func revoke(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.organizationInvitationDelete)
        guard let invitationID = req.parameters.get("invitationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid invitation ID")
        }
        return try await req.approvals.submit(.organizationInvitationDelete(id: invitationID))
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
                let organization = try await lockOrganization(invitation.$organization.id, on: db)
                // Definitive lookup follows the organization lock, after any userinfo delay.
                guard let current = try await OrganizationInvitation.pending(on: db)
                    .filter(\.$id == invitation.requireID())
                    .first()
                else {
                    throw Abort(.notFound)
                }

                let organizationID = current.$organization.id
                if current.isOnboarding, organization.onboardedAt != nil { throw Abort(.conflict) }
                if let requestID = current.$approvalRequest.id {
                    guard let approval = try await ApprovalRequest.find(requestID, on: db),
                        approval.status == ApprovalRequestStatus.applied.rawValue
                    else {
                        throw Abort(.conflict, reason: "Invitation is waiting for approval")
                    }
                }
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
                if current.isOnboarding {
                    organization.onboardedAt = current.acceptedAt
                    organization.$updatedBy.id = userID
                    try await organization.save(on: db)
                }

                return AcceptInvitationResponse(user: user.toGetDTO(), organizationId: organizationID)
            }
        }
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
