import Fluent
import Vapor

struct PlatformController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let platform = routes.grouped(AuthMiddleware()).grouped("platform")
        platform.post("organizations", use: self.provision)
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
                guard let adminRole = roles.first(where: { $0.templateKey == RoleTemplate.organizationAdministrator.key }) else {
                    throw Abort(.internalServerError, reason: "Organization Administrator template was not copied")
                }

                let (_, token) = try await OrganizationInvitation.issue(
                    organizationID: organizationID,
                    email: dto.adminEmail,
                    firstName: dto.adminFirstName,
                    lastName: dto.adminLastName,
                    roleID: try adminRole.requireID(),
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
