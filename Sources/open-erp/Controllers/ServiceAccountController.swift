import Fluent
import Vapor
import VaporToOpenAPI

struct ServiceAccountListFilters: ListFilters {
    static let keys: Set<String> = ["name", "enabled", "ownerId"]
    var name: String?
    var enabled: Bool?
    var ownerId: UUID?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty, required: false)
        validations.add("enabled", as: Bool.self, required: false)
        validations.add("ownerId", as: UUID.self, required: false)
    }
}

struct ServiceAccountController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let scoped = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("service-accounts")
        scoped.post(use: create)
            .openAPI(summary: "Register service account", description: "Requires service_account:create. Binds the subject of an identity provider client-credentials token to a new service account in this organization. The account belongs to no group. ownerId defaults to the caller. May return 202 awaiting approval.", headers: .type(OrganizationHeaders.self), body: .type(CreateServiceAccountDTO.self), response: .type(ServiceAccountDTO.self), auth: .bearer())
            .problemResponses(.badRequest, .conflict, .payloadTooLarge, .unsupportedMediaType)
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        scoped.get(use: index)
            .openAPI(summary: "List service accounts", description: "Requires service_account:read. name (contains), enabled and ownerId filters. Newest createdAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.", query: [.type(ListPage.self), .type(ServiceAccountListFilters.self)], headers: .type(OrganizationHeaders.self), response: .type(Page<ServiceAccountDTO>.self), auth: .bearer())
            .problemResponses(.badRequest)
        scoped.get(":accountID", use: show)
            .openAPI(summary: "Get service account", description: "Requires service_account:read.", headers: .type(OrganizationHeaders.self), response: .type(ServiceAccountDTO.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound)
        scoped.patch(":accountID", use: patch)
            .openAPI(summary: "Update service account", description: "Requires service_account:update. Changing subject binds a different identity provider client; enabled true re-enables a disabled account. An empty description clears it. May return 202 awaiting approval.", headers: .type(OrganizationHeaders.self), body: .type(PatchServiceAccountDTO.self), response: .type(ServiceAccountDTO.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound, .conflict, .payloadTooLarge, .unsupportedMediaType)
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        scoped.delete(":accountID", use: delete)
            .openAPI(summary: "Delete service account", description: "Requires service_account:delete. Ends its membership and group memberships and releases its subject. May return 202 awaiting approval.", headers: .type(OrganizationHeaders.self), statusCode: 204, auth: .bearer())
            .problemResponses(.badRequest, .notFound, .conflict)
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        scoped.post(":accountID", "disable", use: disable)
            .openAPI(summary: "Disable service account", description: "Requires service_account:disable. Takes effect on the account's next request and is never approval-held. Idempotent. Already authorized requests can finish.", headers: .type(OrganizationHeaders.self), statusCode: 204, auth: .bearer())
            .problemResponses(.badRequest, .notFound)
    }

    @Sendable func create(req: Request) async throws -> ApprovalOutcome<ServiceAccountDTO> {
        try req.require(.serviceAccountCreate)
        try CreateServiceAccountDTO.validate(content: req)
        let dto = try req.content.decode(CreateServiceAccountDTO.self)
        let description = dto.description.flatMap { $0.isEmpty ? nil : $0 }
        return try await req.approvals.submit(.serviceAccountCreate(.init(
            name: dto.name, description: description, ownerId: try dto.ownerId ?? req.userID(), subject: dto.subject, enabled: true)))
    }

    @Sendable func index(req: Request) async throws -> Page<ServiceAccountDTO> {
        try req.require(.serviceAccountRead)
        let (filters, page) = try req.listParameters(ServiceAccountListFilters.self)
        let query = User.query(on: req.db)
            .join(ServiceAccount.self, on: \User.$id == \ServiceAccount.$id)
            .filter(ServiceAccount.self, \.$organization.$id == req.organizationID)
            .filter(ServiceAccount.self, \.$deletedAt == nil)
            .filter(\.$firstName, contains: filters.name)
        if let enabled = filters.enabled {
            if enabled {
                query.filter(ServiceAccount.self, \.$disabledAt == nil)
            } else {
                query.filter(ServiceAccount.self, \.$disabledAt != nil)
            }
        }
        if let ownerID = filters.ownerId {
            query.filter(ServiceAccount.self, \.$owner.$id == ownerID)
        }
        return try await query.newestFirst(ServiceAccount.self, \.$createdAt).paginate(page).map { user in
            try ServiceAccountDTO(user.joined(ServiceAccount.self), user: user)
        }
    }

    @Sendable func show(req: Request) async throws -> ServiceAccountDTO {
        try req.require(.serviceAccountRead)
        let (account, user) = try await ServiceAccountChanges.require(accountID(req), organizationID: req.organizationID, on: req.db)
        return try ServiceAccountDTO(account, user: user)
    }

    @Sendable func patch(req: Request) async throws -> ApprovalOutcome<ServiceAccountDTO> {
        try req.require(.serviceAccountUpdate)
        try PatchServiceAccountDTO.validate(content: req)
        let dto = try req.content.decode(PatchServiceAccountDTO.self)
        let (account, user) = try await ServiceAccountChanges.require(accountID(req), organizationID: req.organizationID, on: req.db)
        let before = ServiceAccountChanges.snapshot(account, user: user)
        return try await req.approvals.submit(.serviceAccountUpdate(id: account.requireID(), before: before, after: dto.applying(to: before)))
    }

    @Sendable func delete(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.serviceAccountDelete)
        let (account, user) = try await ServiceAccountChanges.require(accountID(req), organizationID: req.organizationID, on: req.db)
        return try await req.approvals.submit(.serviceAccountDelete(id: account.requireID(), before: ServiceAccountChanges.snapshot(account, user: user)))
    }

    @Sendable func disable(req: Request) async throws -> HTTPStatus {
        try req.require(.serviceAccountDisable)
        let id = try accountID(req), organizationID = req.organizationID, actorID = try req.userID()
        try await req.db.auditedTransaction(req.auditContext()) { db in
            try await ServiceAccountChanges.disable(id: id, organizationID: organizationID, actorID: actorID, on: db)
        }
        return .noContent
    }

    private func accountID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("accountID", as: UUID.self) else { throw Abort(.badRequest, reason: "Invalid service account ID") }
        return id
    }
}
