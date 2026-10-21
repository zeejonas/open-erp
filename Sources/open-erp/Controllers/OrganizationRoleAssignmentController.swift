import Fluent
import Vapor

struct OrganizationRoleAssignmentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let assignments = routes.grouped(AuthMiddleware(), OrganizationMiddleware())
            .grouped("organization-role-assignments")
        assignments.post(use: self.create)
        assignments.get(use: self.index)
        assignments.group(":assignmentID") { assignment in
            assignment.delete(use: self.revoke)
        }
    }

    @Sendable
    func create(req: Request) async throws -> GetOrganizationRoleAssignmentDTO {
        try req.require(.organizationRoleAssignmentCreate)
        let dto = try req.content.decode(CreateOrganizationRoleAssignmentDTO.self)

        guard let membership = try await OrganizationUser.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$user.$id == dto.userId)
            .first()
        else {
            throw Abort(.notFound)
        }

        guard let role = try await Role.find(dto.roleId, on: req.db) else {
            throw Abort(.badRequest, reason: "Role must be an organization-level role in this organization")
        }
        guard role.$organization.id == req.organizationID, role.roleLevel == .organization else {
            throw Abort(.badRequest, reason: "Role must be an organization-level role in this organization")
        }

        let assignment = OrganizationRoleAssignment(
            organizationUserID: try membership.requireID(),
            roleID: dto.roleId,
            createdByID: try req.userID()
        )
        try await conflictOnDuplicate("User already holds this role") {
            try await assignment.save(on: req.db)
        }
        return assignment.toGetDTO(userID: dto.userId)
    }

    @Sendable
    func index(req: Request) async throws -> [GetOrganizationRoleAssignmentDTO] {
        try req.require(.organizationRoleAssignmentRead)
        let assignments = try await OrganizationRoleAssignment.query(on: req.db)
            .join(OrganizationUser.self, on: \OrganizationRoleAssignment.$organizationUser.$id == \OrganizationUser.$id)
            .filter(OrganizationUser.self, \.$organization.$id == req.organizationID)
            .filter(OrganizationUser.self, \.$deletedAt == nil)
            .filter(\.$deletedAt == nil)
            .all()
        return try assignments.map { assignment in
            let membership = try assignment.joined(OrganizationUser.self)
            return assignment.toGetDTO(userID: membership.$user.id)
        }
    }

    @Sendable
    func revoke(req: Request) async throws -> HTTPStatus {
        try req.require(.organizationRoleAssignmentDelete)
        guard let assignmentID = req.parameters.get("assignmentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid assignment ID")
        }
        guard let assignment = try await OrganizationRoleAssignment.query(on: req.db)
            .join(OrganizationUser.self, on: \OrganizationRoleAssignment.$organizationUser.$id == \OrganizationUser.$id)
            .filter(\.$id == assignmentID)
            .filter(OrganizationUser.self, \.$organization.$id == req.organizationID)
            .filter(OrganizationUser.self, \.$deletedAt == nil)
            .first()
        else {
            throw Abort(.notFound)
        }
        try await assignment.softDelete(by: req.userID(), \.$deletedBy, on: req.db)
        return .noContent
    }
}
