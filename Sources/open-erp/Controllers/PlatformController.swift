import Fluent
import Vapor
import VaporToOpenAPI

struct PlatformController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let platform = routes.grouped(AuthMiddleware(), PlatformAdminMiddleware()).grouped("platform")
        platform.get("organizations", use: self.index)
            .openAPI(
                summary: "List organizations",
                description: "Platform administrator only. Literal case-insensitive code/name filters and onboarded completion filter combine with AND. Newest updatedAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated parameters return 400.",
                query: [.type(ListPage.self), .type(PlatformOrganizationListFilters.self)],
                response: .type(Page<PlatformOrganizationDTO>.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest)
        platform.get("organizations", ":organizationID", use: self.show)
            .openAPI(
                summary: "Get organization onboarding detail",
                description: "Platform administrator only. Completion and invitation lifecycle are separate facts; diagnostics are advisory. Grants no tenant access.",
                response: .type(PlatformOrganizationDetailDTO.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest, .notFound)
        platform.post("organizations", use: self.provision)
            .openAPI(
                summary: "Create organization",
                description: "Requires a platform administrator.",
                body: .type(ProvisionOrganizationDTO.self),
                response: .type(ProvisionOrganizationResponse.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest, .payloadTooLarge, .unsupportedMediaType, .conflict)
        platform.post("organizations", ":organizationID", "admin-invitation", "reissue", use: self.reissue)
            .openAPI(summary: "Reissue administrator invitation",
                description: "Platform administrator only. No body or recipient changes. Replaces incomplete onboarding with a seven-day token returned once. 409 for completed/unavailable onboarding or an unavailable original group.",
                response: .type(ProvisionOrganizationResponse.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound, .conflict)
    }

    @Sendable
    func index(req: Request) async throws -> Page<PlatformOrganizationDTO> {
        let (filters, page) = try req.listParameters(PlatformOrganizationListFilters.self)
        let query = Organization.query(on: req.db)
            .filter(\.$code, contains: filters.code)
            .filter(\.$name, contains: filters.name)
        if let onboarded = filters.onboarded {
            query.filter(\.$onboardedAt, onboarded ? .notEqual : .equal, nil)
        }
        return try await query.newestFirst(\.$updatedAt).paginate(page)
            .map { try PlatformOrganizationDTO($0) }
    }

    @Sendable
    func show(req: Request) async throws -> PlatformOrganizationDetailDTO {
        guard let id = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        guard let organization = try await Organization.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        let invitation = try await OrganizationInvitation.onboarding(organizationID: id, on: req.db)
        return PlatformOrganizationDetailDTO(
            organization: try PlatformOrganizationDTO(organization),
            onboardingInvitation: try invitation.map(PlatformOnboardingInvitationDTO.init),
            onboardingIssue: try await onboardingIssue(organization, invitation, on: req.db)
        )
    }

    /// Advisory: reissue's locked transaction remains authoritative.
    private func onboardingIssue(
        _ organization: Organization,
        _ invitation: OrganizationInvitation?,
        on db: any Database
    ) async throws -> PlatformOnboardingIssue? {
        guard organization.onboardedAt == nil else { return nil }
        let id = try organization.requireID()
        if try await OrganizationInvitation.hasAcceptedOnboarding(organizationID: id, on: db) {
            return .acceptedWithoutCompletion
        }
        guard let invitation else { return .missingOnboardingInvitation }
        guard let groupID = invitation.$group.id,
            try await AccessGroup.query(on: db, organizationID: id).filter(\.$id == groupID).first() != nil
        else { return .originalGroupUnavailable }
        return nil
    }

    @Sendable
    func provision(req: Request) async throws -> ProvisionOrganizationResponse {
        try ProvisionOrganizationDTO.validate(content: req)
        let dto = try req.content.decode(ProvisionOrganizationDTO.self)
        let actorID = try req.userID()

        return try await conflictOnDuplicate("An organization with this code already exists") {
            try await req.db.transaction { db in
                let organization = Organization(
                    code: dto.code,
                    name: dto.name,
                    createdBy: req.user,
                    updatedBy: nil,
                    deletedBy: nil
                )
                try await organization.save(on: db)
                let organizationID = try organization.requireID()

                let roles = try await Role.copyTemplates(into: organizationID, createdByID: actorID, on: db)
                let groups = try await AccessGroup.copyTemplates(into: organizationID, roles: roles, createdByID: actorID, on: db)
                guard let adminGroup = groups.first(where: { $0.templateKey == GroupTemplate.organizationAdministrators.key }) else {
                    throw Abort(.internalServerError, reason: "Organization Administrators template was not copied")
                }

                let (invitation, token) = try await OrganizationInvitation.issue(
                    organizationID: organizationID,
                    email: dto.adminEmail,
                    firstName: dto.adminFirstName,
                    lastName: dto.adminLastName,
                    groupID: try adminGroup.requireID(),
                    createdByID: actorID,
                    isOnboarding: true,
                    on: db
                )
                return ProvisionOrganizationResponse(
                    organization: organization.toGetDTO(),
                    invitationToken: token,
                    invitation: invitation.toGetDTO()
                )
            }
        }
    }

    @Sendable
    func reissue(req: Request) async throws -> ProvisionOrganizationResponse {
        guard let id = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        // A recovery request has no editable recipient or group.
        guard req.body.data?.readableBytes ?? 0 == 0 else {
            throw Abort(.badRequest, reason: "Reissue accepts no request body")
        }
        let actorID = try req.userID()
        return try await req.db.transaction { db in
            let organization = try await lockOrganization(id, on: db)
            guard organization.onboardedAt == nil,
                try await !OrganizationInvitation.hasAcceptedOnboarding(organizationID: id, on: db),
                let previous = try await OrganizationInvitation.onboarding(organizationID: id, on: db),
                let groupID = previous.$group.id,
                try await lockGroup(groupID, organizationID: id, on: db) != nil
            else { throw Abort(.conflict, reason: "Onboarding cannot be reissued") }
            if previous.deletedAt == nil {
                try await previous.softDelete(by: actorID, \.$deletedBy, on: db)
            }
            let (invitation, token) = try await OrganizationInvitation.issue(
                organizationID: id, email: previous.email, firstName: previous.firstName,
                lastName: previous.lastName, groupID: groupID, createdByID: actorID,
                isOnboarding: true, on: db)
            return ProvisionOrganizationResponse(organization: organization.toGetDTO(),
                invitationToken: token, invitation: invitation.toGetDTO())
        }
    }
}
