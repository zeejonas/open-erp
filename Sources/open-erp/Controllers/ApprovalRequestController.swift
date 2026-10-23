import Fluent
import Vapor

struct ApprovalRequestController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let requests = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("approval-requests")
        requests.get(use: self.index)
        requests.group(":requestID") { approval in
            approval.get(use: self.show)
            approval.post("approve", use: self.approve)
            approval.post("reject", use: self.reject)
            approval.post("withdraw", use: self.withdraw)
            approval.post("override", use: self.override)
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
