import Fluent
import Vapor
import VaporToOpenAPI

struct GroupController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let groups = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("groups")
        groups.post(use: self.create)
            .openAPI(
                summary: "Create group",
                description: "Requires group:create. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                headers: .type(OrganizationHeaders.self),
                body: .type(CreateGroupDTO.self),
                response: .type(GetGroupDTO.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest, .payloadTooLarge, .unsupportedMediaType, .conflict)
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        groups.get(use: self.index)
            .openAPI(
                summary: "List groups",
                description: "Requires group:read. Newest updatedAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.",
                query: [.type(ListPage.self), .type(GroupListFilters.self)],
                headers: .type(OrganizationHeaders.self),
                response: .type(Page<GetGroupDTO>.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest)
        groups.group(":groupID") { group in
            group.get(use: self.show)
                .openAPI(
                    summary: "Get group",
                    description: "Requires group:read.",
                    headers: .type(OrganizationHeaders.self),
                    response: .type(GetGroupDTO.self),
                    auth: .bearer()
                )
                .problemResponses(.badRequest, .notFound)
            group.patch(use: self.patch)
                .openAPI(
                    summary: "Update group",
                    description: "Requires group:update. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                    headers: .type(OrganizationHeaders.self),
                    body: .type(PatchGroupDTO.self),
                    response: .type(GetGroupDTO.self),
                    auth: .bearer()
                )
                .problemResponses(.badRequest, .payloadTooLarge, .unsupportedMediaType, .notFound, .conflict)
                .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
            group.delete(use: self.delete)
                .openAPI(
                    summary: "Delete group",
                    description: "Requires group:delete. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                    headers: .type(OrganizationHeaders.self),
                    responseDescription: "Deleted",
                    statusCode: 204,
                    auth: .bearer()
                )
                .problemResponses(.badRequest, .notFound, .conflict)
                .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
            group.group("members") { members in
                members.post(use: self.addMember)
                    .openAPI(
                        summary: "Add group member",
                        description: "Requires group_member:create. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                        headers: .type(OrganizationHeaders.self),
                        body: .type(AddGroupMemberDTO.self),
                        response: .type(GetGroupMemberDTO.self),
                        auth: .bearer()
                    )
                    .problemResponses(.badRequest, .payloadTooLarge, .unsupportedMediaType, .notFound, .conflict)
                    .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
                members.get(use: self.listMembers)
                    .openAPI(
                        summary: "List group members",
                        description: "Requires group_member:read. Newest createdAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.",
                        query: [.type(ListPage.self), .type(NoFilters.self)],
                        headers: .type(OrganizationHeaders.self),
                        response: .type(Page<GetGroupMemberDTO>.self),
                        auth: .bearer()
                    )
                    .problemResponses(.badRequest, .notFound)
                members.group(":userID") { member in
                    member.delete(use: self.removeMember)
                        .openAPI(
                            summary: "Remove group member",
                            description: "Requires group_member:delete. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                            headers: .type(OrganizationHeaders.self),
                            responseDescription: "Deleted",
                            statusCode: 204,
                            auth: .bearer()
                        )
                        .problemResponses(.badRequest, .notFound, .conflict)
                        .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
                }
            }
            group.group("roles") { roles in
                roles.post(use: self.addRole)
                    .openAPI(
                        summary: "Add group role",
                        description: "Requires group_role:create. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                        headers: .type(OrganizationHeaders.self),
                        body: .type(AddGroupRoleDTO.self),
                        response: .type(GetGroupRoleDTO.self),
                        auth: .bearer()
                    )
                    .problemResponses(.badRequest, .payloadTooLarge, .unsupportedMediaType, .notFound, .conflict)
                    .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
                roles.group(":roleID") { role in
                    role.delete(use: self.removeRole)
                        .openAPI(
                            summary: "Remove group role",
                            description: "Requires group_role:delete. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                            headers: .type(OrganizationHeaders.self),
                            responseDescription: "Deleted",
                            statusCode: 204,
                            auth: .bearer()
                        )
                        .problemResponses(.badRequest, .notFound, .conflict)
                        .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
                }
            }
            group.group("companies") { companies in
                companies.post(use: self.addCompany)
                    .openAPI(
                        summary: "Add group company",
                        description: "Requires group_company:create. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                        headers: .type(OrganizationHeaders.self),
                        body: .type(AddGroupCompanyDTO.self),
                        response: .type(GetGroupCompanyDTO.self),
                        auth: .bearer()
                    )
                    .problemResponses(.badRequest, .payloadTooLarge, .unsupportedMediaType, .notFound, .conflict)
                    .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
                companies.group(":companyID") { company in
                    company.delete(use: self.removeCompany)
                        .openAPI(
                            summary: "Remove group company",
                            description: "Requires group_company:delete. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                            headers: .type(OrganizationHeaders.self),
                            responseDescription: "Deleted",
                            statusCode: 204,
                            auth: .bearer()
                        )
                        .problemResponses(.badRequest, .notFound, .conflict)
                        .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
                }
            }
        }
    }

    @Sendable
    func create(req: Request) async throws -> ApprovalOutcome<GetGroupDTO> {
        try req.require(.groupCreate)
        try CreateGroupDTO.validate(content: req)
        let dto = try req.content.decode(CreateGroupDTO.self)
        return try await req.approvals.submit(.groupCreate(name: dto.name))
    }

    @Sendable
    func index(req: Request) async throws -> Page<GetGroupDTO> {
        try req.require(.groupRead)
        let (filters, page) = try req.listParameters(GroupListFilters.self)
        var groups = AccessGroup.query(on: req.db, organizationID: req.organizationID)
            .with(\.$roles)
            .with(\.$companies)
            .filter(\.$name, contains: filters.name)
        if let roleID = filters.roleId {
            groups = groups
                .join(GroupRole.self, on: \AccessGroup.$id == \GroupRole.$group.$id)
                .filter(GroupRole.self, \.$role.$id == roleID)
                .filter(GroupRole.self, \.$deletedAt == nil)
        }
        if let companyID = filters.companyId {
            groups = groups
                .join(GroupCompany.self, on: \AccessGroup.$id == \GroupCompany.$group.$id)
                .filter(GroupCompany.self, \.$company.$id == companyID)
                .filter(GroupCompany.self, \.$deletedAt == nil)
        }
        return try await groups
            .newestFirst(\.$updatedAt)
            .paginate(page)
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
    func patch(req: Request) async throws -> ApprovalOutcome<GetGroupDTO> {
        try req.require(.groupUpdate)
        try PatchGroupDTO.validate(content: req)
        let dto = try req.content.decode(PatchGroupDTO.self)
        let group = try await findGroup(req: req)
        let before = GroupSnapshot(name: group.name)
        var after = before
        if let name = dto.name { after.name = name }
        return try await req.approvals.submit(.groupUpdate(id: try group.requireID(), before: before, after: after))
    }

    @Sendable
    func delete(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.groupDelete)
        let group = try await findGroup(req: req)
        return try await req.approvals.submit(.groupDelete(
            id: try group.requireID(),
            before: GroupSnapshot(name: group.name)
        ))
    }

    @Sendable
    func addMember(req: Request) async throws -> ApprovalOutcome<GetGroupMemberDTO> {
        try req.require(.groupMemberCreate)
        let group = try await findGroup(req: req)
        let dto = try req.content.decode(AddGroupMemberDTO.self)
        return try await req.approvals.submit(.groupMemberCreate(GroupMemberDraft(
            groupId: try group.requireID(),
            userId: dto.userId
        )))
    }

    @Sendable
    func listMembers(req: Request) async throws -> Page<GetGroupMemberDTO> {
        try req.require(.groupMemberRead)
        let (_, page) = try req.listParameters(NoFilters.self)
        let group = try await findGroup(req: req)
        let members = try await GroupMember.query(on: req.db)
            .join(OrganizationUser.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
            .filter(\.$group.$id == group.requireID())
            .filter(OrganizationUser.self, \.$deletedAt == nil)
            .newestFirst(\.$createdAt)
            .paginate(page)
        return try members.map { member in
            let membership = try member.joined(OrganizationUser.self)
            return member.toGetDTO(userID: membership.$user.id)
        }
    }

    @Sendable
    func removeMember(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.groupMemberDelete)
        let group = try await findGroup(req: req)
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        return try await req.approvals.submit(.groupMemberDelete(GroupMemberDraft(
            groupId: try group.requireID(),
            userId: userID
        )))
    }

    @Sendable
    func addRole(req: Request) async throws -> ApprovalOutcome<GetGroupRoleDTO> {
        try req.require(.groupRoleCreate)
        let group = try await findGroup(req: req)
        let dto = try req.content.decode(AddGroupRoleDTO.self)
        return try await req.approvals.submit(.groupRoleCreate(GroupRoleDraft(
            groupId: try group.requireID(),
            roleId: dto.roleId
        )))
    }

    @Sendable
    func removeRole(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.groupRoleDelete)
        let group = try await findGroup(req: req)
        guard let roleID = req.parameters.get("roleID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid role ID")
        }
        return try await req.approvals.submit(.groupRoleDelete(GroupRoleDraft(
            groupId: try group.requireID(),
            roleId: roleID
        )))
    }

    @Sendable
    func addCompany(req: Request) async throws -> ApprovalOutcome<GetGroupCompanyDTO> {
        try req.require(.groupCompanyCreate)
        let group = try await findGroup(req: req)
        let dto = try req.content.decode(AddGroupCompanyDTO.self)
        return try await req.approvals.submit(.groupCompanyCreate(GroupCompanyDraft(
            groupId: try group.requireID(),
            companyId: dto.companyId
        )))
    }

    @Sendable
    func removeCompany(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.groupCompanyDelete)
        let group = try await findGroup(req: req)
        guard let companyID = req.parameters.get("companyID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid company ID")
        }
        return try await req.approvals.submit(.groupCompanyDelete(GroupCompanyDraft(
            groupId: try group.requireID(),
            companyId: companyID
        )))
    }

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
