import Fluent
import Vapor

struct GroupController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let groups = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("groups")
        groups.post(use: self.create)
        groups.get(use: self.index)
        groups.group(":groupID") { group in
            group.get(use: self.show)
            group.patch(use: self.patch)
            group.delete(use: self.delete)
            group.group("members") { members in
                members.post(use: self.addMember)
                members.get(use: self.listMembers)
                members.group(":userID") { member in
                    member.delete(use: self.removeMember)
                }
            }
            group.group("roles") { roles in
                roles.post(use: self.addRole)
                roles.group(":roleID") { role in
                    role.delete(use: self.removeRole)
                }
            }
            group.group("companies") { companies in
                companies.post(use: self.addCompany)
                companies.group(":companyID") { company in
                    company.delete(use: self.removeCompany)
                }
            }
        }
    }

    @Sendable
    func create(req: Request) async throws -> GetGroupDTO {
        try req.require(.groupCreate)
        try CreateGroupDTO.validate(content: req)
        let dto = try req.content.decode(CreateGroupDTO.self)
        let group = AccessGroup(organizationID: req.organizationID, name: dto.name, createdByID: try req.userID())
        try await conflictOnDuplicate(Self.duplicateName) {
            try await group.save(on: req.db)
        }
        try await group.loadAssignments(on: req.db)
        return group.toGetDTO()
    }

    @Sendable
    func index(req: Request) async throws -> [GetGroupDTO] {
        try req.require(.groupRead)
        return try await AccessGroup.query(on: req.db, organizationID: req.organizationID)
            .with(\.$roles)
            .with(\.$companies)
            .all()
            .map { $0.toGetDTO() }
    }

    @Sendable
    func show(req: Request) async throws -> GetGroupDTO {
        try req.require(.groupRead)
        let group = try await findGroup(req: req)
        try await group.loadAssignments(on: req.db)
        return group.toGetDTO()
    }

    @Sendable
    func patch(req: Request) async throws -> GetGroupDTO {
        try req.require(.groupUpdate)
        try PatchGroupDTO.validate(content: req)
        let dto = try req.content.decode(PatchGroupDTO.self)
        let group = try await findGroup(req: req)
        if let name = dto.name {
            group.name = name
        }
        group.$updatedBy.id = try req.userID()
        try await conflictOnDuplicate(Self.duplicateName) {
            try await group.update(on: req.db)
        }
        try await group.loadAssignments(on: req.db)
        return group.toGetDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        try req.require(.groupDelete)
        let group = try await findGroup(req: req)
        if try await group.isInUse(on: req.db) {
            throw Abort(.conflict, reason: "Group has active members or pending invitations")
        }
        try await group.softDelete(by: req.userID(), \.$deletedBy, on: req.db)
        return .noContent
    }

    @Sendable
    func addMember(req: Request) async throws -> GetGroupMemberDTO {
        try req.require(.groupMemberCreate)
        let group = try await findGroup(req: req)
        let dto = try req.content.decode(AddGroupMemberDTO.self)
        guard let membership = try await OrganizationUser.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$user.$id == dto.userId)
            .first()
        else {
            throw Abort(.notFound)
        }
        let groupMembership = GroupMember(
            groupID: try group.requireID(),
            organizationUserID: try membership.requireID(),
            createdByID: try req.userID()
        )
        try await conflictOnDuplicate(Self.duplicateMember) {
            try await groupMembership.save(on: req.db)
        }
        return groupMembership.toGetDTO(userID: dto.userId)
    }

    @Sendable
    func listMembers(req: Request) async throws -> [GetGroupMemberDTO] {
        try req.require(.groupMemberRead)
        let group = try await findGroup(req: req)
        let members = try await GroupMember.query(on: req.db)
            .join(OrganizationUser.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
            .filter(\.$group.$id == group.requireID())
            .filter(OrganizationUser.self, \.$deletedAt == nil)
            .all()
        return try members.map { member in
            let membership = try member.joined(OrganizationUser.self)
            return member.toGetDTO(userID: membership.$user.id)
        }
    }

    @Sendable
    func removeMember(req: Request) async throws -> HTTPStatus {
        try req.require(.groupMemberDelete)
        let group = try await findGroup(req: req)
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        guard let groupMembership = try await GroupMember.query(on: req.db)
            .join(OrganizationUser.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
            .filter(\.$group.$id == group.requireID())
            .filter(OrganizationUser.self, \.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound)
        }
        try await groupMembership.softDelete(by: req.userID(), \.$deletedBy, on: req.db)
        return .noContent
    }

    @Sendable
    func addRole(req: Request) async throws -> GetGroupRoleDTO {
        try req.require(.groupRoleCreate)
        let group = try await findGroup(req: req)
        let dto = try req.content.decode(AddGroupRoleDTO.self)
        guard try await Role.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$id == dto.roleId)
            .first() != nil
        else {
            throw Abort(.badRequest, reason: "Role must belong to this organization")
        }
        let link = GroupRole(groupID: try group.requireID(), roleID: dto.roleId, createdByID: try req.userID())
        try await conflictOnDuplicate(Self.duplicateRole) {
            try await link.save(on: req.db)
        }
        return link.toGetDTO()
    }

    @Sendable
    func removeRole(req: Request) async throws -> HTTPStatus {
        try req.require(.groupRoleDelete)
        let group = try await findGroup(req: req)
        guard let roleID = req.parameters.get("roleID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid role ID")
        }
        guard let link = try await GroupRole.query(on: req.db)
            .filter(\.$group.$id == group.requireID())
            .filter(\.$role.$id == roleID)
            .first()
        else {
            throw Abort(.notFound)
        }
        try await link.softDelete(by: req.userID(), \.$deletedBy, on: req.db)
        return .noContent
    }

    @Sendable
    func addCompany(req: Request) async throws -> GetGroupCompanyDTO {
        try req.require(.groupCompanyCreate)
        let group = try await findGroup(req: req)
        let dto = try req.content.decode(AddGroupCompanyDTO.self)
        guard try await Company.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$id == dto.companyId)
            .first() != nil
        else {
            throw Abort(.badRequest, reason: "Company must belong to this organization")
        }
        let link = GroupCompany(groupID: try group.requireID(), companyID: dto.companyId, createdByID: try req.userID())
        try await conflictOnDuplicate(Self.duplicateCompany) {
            try await link.save(on: req.db)
        }
        return link.toGetDTO()
    }

    @Sendable
    func removeCompany(req: Request) async throws -> HTTPStatus {
        try req.require(.groupCompanyDelete)
        let group = try await findGroup(req: req)
        guard let companyID = req.parameters.get("companyID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid company ID")
        }
        guard let link = try await GroupCompany.query(on: req.db)
            .filter(\.$group.$id == group.requireID())
            .filter(\.$company.$id == companyID)
            .first()
        else {
            throw Abort(.notFound)
        }
        try await link.softDelete(by: req.userID(), \.$deletedBy, on: req.db)
        return .noContent
    }

    private static let duplicateName = "A group with this name already exists"
    private static let duplicateMember = "User is already a member of this group"
    private static let duplicateRole = "Group already holds this role"
    private static let duplicateCompany = "Group is already eligible at this company"

    private func findGroup(req: Request) async throws -> AccessGroup {
        guard let groupID = req.parameters.get("groupID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }
        guard let group = try await AccessGroup.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$id == groupID)
            .first()
        else {
            throw Abort(.notFound)
        }
        return group
    }
}
