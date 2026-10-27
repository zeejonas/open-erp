import Fluent
import Vapor
import VaporToOpenAPI

struct PlatformController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let platform = routes.grouped(AuthMiddleware()).grouped("platform")
        platform.post("organizations", use: self.provision)
            .openAPI(
                summary: "Provision platform",
                description: "Requires a platform administrator.",
                body: .type(ProvisionOrganizationDTO.self),
                response: .type(ProvisionOrganizationResponse.self),
                auth: .bearer()
            )
    }

    @Sendable
    func provision(req: Request) async throws -> ProvisionOrganizationResponse {
        guard req.user.isPlatformAdmin else {
            throw Abort(.forbidden)
        }
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

                let (_, token) = try await OrganizationInvitation.issue(
                    organizationID: organizationID,
                    email: dto.adminEmail,
                    firstName: dto.adminFirstName,
                    lastName: dto.adminLastName,
                    groupID: try adminGroup.requireID(),
                    createdByID: actorID,
                    on: db
                )
                return ProvisionOrganizationResponse(
                    organization: organization.toGetDTO(),
                    invitationToken: token
                )
            }
        }
    }
}
