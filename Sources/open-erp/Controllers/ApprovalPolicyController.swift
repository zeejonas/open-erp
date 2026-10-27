import Fluent
import FluentSQL
import Vapor
import VaporToOpenAPI

struct ApprovalPolicyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let scoped = routes.grouped(AuthMiddleware(), OrganizationMiddleware())
        scoped.get("approval-catalog", use: self.catalog)
            .openAPI(
                summary: "Get approval catalog",
                description: "Requires approval_policy:read.",
                headers: .type(OrganizationHeaders.self),
                response: .type([ApprovalCatalogEntry].self),
                auth: .bearer()
            )
        let policies = scoped.grouped("approval-policies")
        policies.get(use: self.index)
            .openAPI(
                summary: "List approval policies",
                description: "Requires approval_policy:read. Newest updatedAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.",
                query: [.type(ListPage.self), .type(ApprovalPolicyListFilters.self)],
                headers: .type(OrganizationHeaders.self),
                response: .type(Page<GetApprovalPolicyDTO>.self),
                auth: .bearer()
            )
        policies.post(use: self.create)
            .openAPI(
                summary: "Create approval policy",
                description: "Requires approval_policy:create. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                headers: .type(OrganizationHeaders.self),
                body: .type(ApprovalPolicyDefinition.self),
                response: .type(GetApprovalPolicyDTO.self),
                auth: .bearer()
            )
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        policies.group(":policyID") { policy in
            policy.get(use: self.show)
                .openAPI(
                    summary: "Get approval policy",
                    description: "Requires approval_policy:read.",
                    headers: .type(OrganizationHeaders.self),
                    response: .type(GetApprovalPolicyDTO.self),
                    auth: .bearer()
                )
            policy.patch(use: self.update)
                .openAPI(
                    summary: "Update approval policy",
                    description: "Requires approval_policy:update. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                    headers: .type(OrganizationHeaders.self),
                    body: .type(ApprovalPolicyDefinition.self),
                    response: .type(GetApprovalPolicyDTO.self),
                    auth: .bearer()
                )
                .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
            policy.delete(use: self.delete)
                .openAPI(
                    summary: "Delete approval policy",
                    description: "Requires approval_policy:delete. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                    headers: .type(OrganizationHeaders.self),
                    responseDescription: "Deleted",
                    statusCode: 204,
                    auth: .bearer()
                )
                .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
            policy.get("versions", use: self.versions)
                .openAPI(
                    summary: "List approval policy versions",
                    description: "Requires approval_policy:read. Newest createdAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.",
                    query: [.type(ListPage.self), .type(NoFilters.self)],
                    headers: .type(OrganizationHeaders.self),
                    response: .type(Page<GetApprovalPolicyVersionDTO>.self),
                    auth: .bearer()
                )
        }
    }

    @Sendable
    func catalog(req: Request) async throws -> [ApprovalCatalogEntry] {
        try req.require(.approvalPolicyRead)
        return ApprovalCatalog.entries
    }

    @Sendable
    func index(req: Request) async throws -> Page<GetApprovalPolicyDTO> {
        try req.require(.approvalPolicyRead)
        let (filters, page) = try req.listParameters(ApprovalPolicyListFilters.self)
        let permission = try requireGateablePermission(filters.permission)
        var policies = ApprovalPolicy.query(on: req.db, organizationID: req.organizationID)
            .with(\.$slots)
            .filter(\.$name, contains: filters.name)
        if let permission {
            policies = policies.filter(\.$permission == permission.rawValue)
        }
        if let companyID = filters.companyId {
            policies = policies.filter(\.$company.$id == companyID)
        }
        if let groupID = filters.groupId {
            policies = policies.filter(.sql(embed: """
                EXISTS (
                    SELECT 1 FROM \(ident: "approval_policy_slots")
                    WHERE \(ident: "approval_policy_slots").\(ident: "policy_id") = \(ident: "approval_policies").\(ident: "id")
                    AND \(ident: "approval_policy_slots").\(ident: "group_id") = \(bind: groupID)
                    AND \(ident: "approval_policy_slots").\(ident: "deleted_at") IS NULL
                )
                """))
        }
        let result = try await policies.newestFirst(\.$updatedAt).paginate(page)
        return Page(items: result.items.map { $0.toGetDTO() }, metadata: result.metadata)
    }

    @Sendable
    func create(req: Request) async throws -> ApprovalOutcome<GetApprovalPolicyDTO> {
        try req.require(.approvalPolicyCreate)
        try ApprovalPolicyDefinition.validate(content: req)
        let definition = try req.content.decode(ApprovalPolicyDefinition.self).normalized()
        return try await req.approvals.submit(.approvalPolicyCreate(definition))
    }

    @Sendable
    func show(req: Request) async throws -> GetApprovalPolicyDTO {
        try req.require(.approvalPolicyRead)
        let policy = try await findPolicy(req: req, includingDeleted: true)
        try await policy.$slots.load(on: req.db)
        return policy.toGetDTO()
    }

    @Sendable
    func update(req: Request) async throws -> ApprovalOutcome<GetApprovalPolicyDTO> {
        try req.require(.approvalPolicyUpdate)
        try ApprovalPolicyDefinition.validate(content: req)
        let submitted = try req.content.decode(ApprovalPolicyDefinition.self).normalized()
        let policy = try await findPolicy(req: req, includingDeleted: false)
        guard submitted.permission == policy.permission else {
            throw Abort(.badRequest, reason: "A policy's permission cannot change")
        }
        try await policy.$slots.load(on: req.db)
        let before = policy.currentDefinition()
        return try await req.approvals.submit(.approvalPolicyUpdate(
            id: try policy.requireID(),
            before: before,
            after: submitted
        ))
    }

    @Sendable
    func delete(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.approvalPolicyDelete)
        let policy = try await findPolicy(req: req, includingDeleted: false)
        try await policy.$slots.load(on: req.db)
        return try await req.approvals.submit(.approvalPolicyDelete(
            id: try policy.requireID(),
            before: policy.currentDefinition()
        ))
    }

    @Sendable
    func versions(req: Request) async throws -> Page<GetApprovalPolicyVersionDTO> {
        try req.require(.approvalPolicyRead)
        let (_, page) = try req.listParameters(NoFilters.self)
        let policy = try await findPolicy(req: req, includingDeleted: true)
        let result = try await ApprovalPolicyVersion.query(on: req.db)
            .filter(\.$policy.$id == policy.requireID())
            .newestFirst(\.$createdAt)
            .paginate(page)
        return Page(items: result.items.map { $0.toGetDTO() }, metadata: result.metadata)
    }

    private func findPolicy(req: Request, includingDeleted: Bool) async throws -> ApprovalPolicy {
        guard let policyID = req.parameters.get("policyID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid policy ID")
        }
        var query = ApprovalPolicy.query(on: req.db, organizationID: req.organizationID).filter(\.$id == policyID)
        if includingDeleted {
            query = query.withDeleted()
        }
        guard let policy = try await query.first() else {
            throw Abort(.notFound)
        }
        return policy
    }
}
