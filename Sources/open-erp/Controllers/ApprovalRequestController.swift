import Fluent
import Vapor
import VaporToOpenAPI

struct ApprovalRequestController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let requests = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("approval-requests")
        requests.get(use: self.index)
            .openAPI(
                summary: "List approval requests",
                description: "Requires approval_request:read. Newest updatedAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.",
                query: [.type(ListPage.self), .type(ApprovalRequestListFilters.self)],
                headers: .type(OrganizationHeaders.self),
                response: .type(of: Page(items: [GetApprovalRequestDTO.example], metadata: .init(page: 1, per: 25, total: 1))),
                auth: .bearer()
            )
        requests.group(":requestID") { approval in
            approval.get(use: self.show)
                .openAPI(
                    summary: "Get approval request",
                    description: "Requires approval_request:read, ownership of the request, or current approver eligibility.",
                    headers: .type(OrganizationHeaders.self),
                    response: .type(GetApprovalRequestDTO.self),
                    auth: .bearer()
                )
            approval.post("approve", use: self.approve)
                .openAPI(
                    summary: "Approve approval request",
                    description: "Requires current approver eligibility; requesters cannot approve their own requests.",
                    headers: .type(OrganizationHeaders.self),
                    response: .type(GetApprovalRequestDTO.self),
                    auth: .bearer()
                )
            approval.post("reject", use: self.reject)
                .openAPI(
                    summary: "Reject approval request",
                    description: "Requires current approver eligibility and a nonempty comment.",
                    headers: .type(OrganizationHeaders.self),
                    body: .type(ApprovalCommentDTO.self),
                    response: .type(GetApprovalRequestDTO.self),
                    auth: .bearer()
                )
            approval.post("withdraw", use: self.withdraw)
                .openAPI(
                    summary: "Withdraw approval request",
                    description: "Only the original requester can withdraw a pending request.",
                    headers: .type(OrganizationHeaders.self),
                    response: .type(GetApprovalRequestDTO.self),
                    auth: .bearer()
                )
            approval.post("override", use: self.override)
                .openAPI(
                    summary: "Override approval request",
                    description: "Requires approval_override:create and a nonempty reason; requesters cannot override their own requests.",
                    headers: .type(OrganizationHeaders.self),
                    body: .type(ApprovalOverrideDTO.self),
                    response: .type(GetApprovalRequestDTO.self),
                    auth: .bearer()
                )
        }
    }

    @Sendable
    func index(req: Request) async throws -> Page<GetApprovalRequestDTO> {
        try req.require(.approvalRequestRead)
        let (filters, page) = try req.listParameters(ApprovalRequestListFilters.self)
        let permission = try requireGateablePermission(filters.permission)
        var approvals = ApprovalRequest.query(on: req.db, organizationID: req.organizationID)
            .with(\.$tracks) { $0.with(\.$policyVersion) }
            .with(\.$decisions)
        if let status = filters.status {
            approvals = approvals.filter(\.$status == status.rawValue)
        }
        if let permission {
            approvals = approvals.filter(\.$permission == permission.rawValue)
        }
        if let requestedBy = filters.requestedBy {
            approvals = approvals.filter(\.$requestedBy.$id == requestedBy)
        }
        let result = try await approvals.newestFirst(\.$updatedAt).paginate(page)
        return Page(items: result.items.map { $0.toGetDTO() }, metadata: result.metadata)
    }

    @Sendable
    func show(req: Request) async throws -> GetApprovalRequestDTO {
        guard let requestID = req.parameters.get("requestID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid request ID")
        }
        let approval = try await ApprovalRequest.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$id == requestID)
            .with(\.$tracks) { $0.with(\.$policyVersion) }
            .with(\.$decisions)
            .first()
        guard let approval else {
            throw Abort(.notFound)
        }
        let userID = try req.userID()
        let canRead = req.permissions.contains(.approvalRequestRead) || approval.$requestedBy.id == userID
        let eligible = try await isCurrentApprover(approval, userID: userID, on: req.db)
        guard canRead || eligible else {
            throw Abort(.forbidden)
        }
        return approval.toGetDTO()
    }

    @Sendable
    func approve(req: Request) async throws -> GetApprovalRequestDTO {
        try await req.approvals.approve(try requestID(req))
    }

    @Sendable
    func reject(req: Request) async throws -> GetApprovalRequestDTO {
        let comment = try req.content.decode(ApprovalCommentDTO.self).comment
        return try await req.approvals.reject(try requestID(req), comment: comment)
    }

    @Sendable
    func withdraw(req: Request) async throws -> GetApprovalRequestDTO {
        try await req.approvals.withdraw(try requestID(req))
    }

    @Sendable
    func override(req: Request) async throws -> GetApprovalRequestDTO {
        try req.require(.approvalOverrideCreate)
        let reason = try req.content.decode(ApprovalOverrideDTO.self).reason
        return try await req.approvals.override(try requestID(req), reason: reason)
    }

    private func requestID(_ req: Request) throws -> UUID {
        guard let requestID = req.parameters.get("requestID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid request ID")
        }
        return requestID
    }
}
