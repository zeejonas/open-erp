import Fluent
import Vapor
import VaporToOpenAPI

struct PlatformController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let platform = routes.grouped(AuthMiddleware(), PlatformAdminMiddleware()).grouped("platform")
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
                description: "Platform administrator only. No body or recipient changes. Replaces incomplete onboarding with a seven-day token returned once. 409 for completed/unavailable onboarding or an unavailable original group. Cache-Control: no-store.",
                response: .type(ProvisionOrganizationResponse.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound, .conflict)
    }

    @Sendable
    func provision(req: Request) async throws -> Response {
        try ProvisionOrganizationDTO.validate(content: req)
        let dto = try req.content.decode(ProvisionOrganizationDTO.self)
        let actorID = try req.userID()

        let result = try await conflictOnDuplicate("An organization with this code already exists") {
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
        let response = try await result.encodeResponse(for: req)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    @Sendable
    func reissue(req: Request) async throws -> Response {
        guard let id = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        // A recovery request has no editable recipient or group.
        guard req.body.data?.readableBytes ?? 0 == 0 else {
            throw Abort(.badRequest, reason: "Reissue accepts no request body")
        }
        let actorID = try req.userID()
        let result = try await req.db.transaction { db in
            let organization = try await lockOrganization(id, on: db)
            let acceptedHistory = try await OrganizationInvitation.query(on: db, organizationID: id)
                .withDeleted().filter(\.$isOnboarding == true).filter(\.$acceptedAt != nil).count()
            guard organization.onboardedAt == nil, acceptedHistory == 0,
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
        let response = try await result.encodeResponse(for: req)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }
}
