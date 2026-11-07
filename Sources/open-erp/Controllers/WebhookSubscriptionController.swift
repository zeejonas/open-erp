import Fluent
import FluentSQL
import SQLKit
import Vapor
import VaporToOpenAPI

struct WebhookSubscriptionListFilters: ListFilters {
    static let keys: Set<String> = ["name", "enabled", "eventType"]
    var name: String?
    var enabled: Bool?
    var eventType: BusinessEventType?
    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty, required: false)
        validations.add("enabled", as: Bool.self, required: false)
        validations.add("eventType", as: String.self, is: .case(of: BusinessEventType.self), required: false)
    }
}

struct WebhookSubscriptionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let scoped = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("webhook-subscriptions")
        scoped.post(use: create)
            .openAPI(summary: "Create disabled webhook subscription", description: "Requires webhook_subscription:create, webhook_payload:read and each event's source-read permission. At most 100 active subscriptions. May return 202 awaiting approval.", headers: .type(OrganizationHeaders.self), body: .type(CreateWebhookSubscriptionDTO.self), response: .type(WebhookSubscriptionDTO.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound, .conflict, .payloadTooLarge, .unsupportedMediaType)
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        scoped.get(use: index)
            .openAPI(summary: "List webhook subscriptions", description: "Requires webhook_subscription:read. Literal name, enabled and eventType filters. updatedAt descending, id ascending; no sort parameter.", query: [.type(ListPage.self), .type(WebhookSubscriptionListFilters.self)], headers: .type(OrganizationHeaders.self), response: .type(Page<WebhookSubscriptionDTO>.self), auth: .bearer())
            .problemResponses(.badRequest)
        scoped.get(":subscriptionID", use: show)
            .openAPI(summary: "Get webhook subscription", description: "Requires webhook_subscription:read. Secrets and ciphertext are excluded.", headers: .type(OrganizationHeaders.self), response: .type(WebhookSubscriptionDTO.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound)
        scoped.get(":subscriptionID", "versions", use: versions)
            .openAPI(summary: "List webhook configuration versions", description: "Requires webhook_subscription:read. createdAt descending then id ascending. No filters or sort parameter.", query: .type(ListPage.self), headers: .type(OrganizationHeaders.self), response: .type(Page<WebhookRevisionDTO>.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound)
        scoped.patch(":subscriptionID", use: patch)
            .openAPI(summary: "Update webhook subscription", description: "Requires webhook_subscription:update and source-read grants. Expansion or enablement also requires webhook_payload:read. expectedRevisionId prevents stale writes. rotateSecret applies immediately after any required approval.", headers: .type(OrganizationHeaders.self), body: .type(PatchWebhookSubscriptionDTO.self), response: .type(WebhookSubscriptionDTO.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound, .conflict, .payloadTooLarge, .unsupportedMediaType)
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        scoped.delete(":subscriptionID", use: delete)
            .openAPI(summary: "Delete webhook subscription", description: "Requires webhook_subscription:delete. Soft deletion may require approval. Pending deliveries are cancelled when deletion applies.", headers: .type(OrganizationHeaders.self), statusCode: 204, auth: .bearer())
            .problemResponses(.badRequest, .notFound, .conflict)
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        scoped.post(":subscriptionID", "disable", use: disable)
            .openAPI(summary: "Emergency-disable webhook subscription", description: "Requires webhook_subscription:disable. Immediate audited shutdown is never approval-held. Already authorized requests can finish.", headers: .type(OrganizationHeaders.self), statusCode: 204, auth: .bearer())
            .problemResponses(.badRequest, .notFound)
        scoped.post(":subscriptionID", "secret", use: secret)
            .openAPI(summary: "Disclose current webhook signing secret", description: "Requires webhook_secret:read. A disclosure record commits before the secret is returned. Cache-Control: no-store.", headers: .type(OrganizationHeaders.self), response: .type(WebhookSecretDTO.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound)
    }

    @Sendable func create(req: Request) async throws -> ApprovalOutcome<WebhookSubscriptionDTO> {
        try req.require(.webhookSubscriptionCreate)
        let dto = try req.content.decode(CreateWebhookSubscriptionDTO.self)
        return try await req.approvals.submit(.webhookSubscriptionCreate(dto.configuration))
    }

    @Sendable func index(req: Request) async throws -> Page<WebhookSubscriptionDTO> {
        try req.require(.webhookSubscriptionRead)
        let (filters, page) = try req.listParameters(WebhookSubscriptionListFilters.self)
        let query = WebhookSubscriptionRevision.query(on: req.db)
            .join(WebhookSubscription.self, on: \WebhookSubscriptionRevision.$id == \WebhookSubscription.$currentRevisionID)
            .filter(WebhookSubscription.self, \.$organization.$id == req.organizationID)
            .filter(WebhookSubscription.self, \.$deletedAt == nil)
            .filter(\.$name, contains: filters.name)
        if let enabled = filters.enabled {
            if enabled {
                query.filter(\.$enabled == true).filter(WebhookSubscription.self, \.$disabledReason == nil)
            } else {
                query.group(.or) { $0.filter(\.$enabled == false).filter(WebhookSubscription.self, \.$disabledReason != nil) }
            }
        }
        if let event = filters.eventType {
            query.filter(.sql(embed: "\(bind: event.rawValue) = ANY(webhook_subscription_revisions.event_types)"))
        }
        return try await query.newestFirst(WebhookSubscription.self, \.$updatedAt).paginate(page).map { revision in
            try WebhookSubscriptionDTO(revision.joined(WebhookSubscription.self), revision: revision)
        }
    }

    @Sendable func show(req: Request) async throws -> WebhookSubscriptionDTO {
        try req.require(.webhookSubscriptionRead)
        let (subscription, revision) = try await require(req)
        return try .init(subscription, revision: revision)
    }

    @Sendable func versions(req: Request) async throws -> Page<WebhookRevisionDTO> {
        try req.require(.webhookSubscriptionRead)
        let (subscription, _) = try await require(req)
        let (_, page) = try req.listParameters(NoFilters.self)
        return try await WebhookSubscriptionRevision.query(on: req.db)
            .filter(\.$organization.$id == req.organizationID).filter(\.$subscription.$id == subscription.requireID())
            .newestFirst(\.$createdAt).paginate(page).map(WebhookRevisionDTO.init)
    }

    @Sendable func patch(req: Request) async throws -> ApprovalOutcome<WebhookSubscriptionDTO> {
        try req.require(.webhookSubscriptionUpdate)
        let dto = try req.content.decode(PatchWebhookSubscriptionDTO.self)
        let (subscription, revision) = try await require(req)
        var before = revision.configuration
        before.enabled = before.enabled && subscription.disabledReason == nil
        return try await req.approvals.submit(.webhookSubscriptionUpdate(id: subscription.requireID(),
            expectedRevisionID: dto.expectedRevisionId, before: before, after: dto.applying(to: before), rotateSecret: dto.rotateSecret == true))
    }

    @Sendable func delete(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.webhookSubscriptionDelete)
        let (subscription, _) = try await require(req)
        return try await req.approvals.submit(.webhookSubscriptionDelete(id: subscription.requireID(), expectedRevisionID: subscription.currentRevisionID))
    }

    @Sendable func disable(req: Request) async throws -> HTTPStatus {
        try req.require(.webhookSubscriptionDisable)
        let id = try subscriptionID(req), organizationID = req.organizationID, context = try req.auditContext()
        try await req.db.auditedTransaction(context) { db in
            let (subscription, _) = try await WebhookSubscriptionService.require(id, organizationID: organizationID, lock: true, on: db)
            try await WebhookRevocation.disable(subscription, reason: .emergency, context: context, cancellation: .subscriptionDisabled, on: db)
        }
        return .noContent
    }

    @Sendable func secret(req: Request) async throws -> WebhookSecretDTO {
        try req.require(.webhookSecretRead)
        let id = try subscriptionID(req), organizationID = req.organizationID, actorID = try req.userID(), requestID = req.id
        let key = try WebhookEncryptionKey.load()
        return try await req.db.auditedTransaction(req.auditContext()) { db in
            let (subscription, revision) = try await WebhookSubscriptionService.require(id, organizationID: organizationID, lock: true, on: db)
            let secret = try key.decrypt(revision.secretCiphertext, organizationID: organizationID, subscriptionID: subscription.requireID(), secretID: revision.secretID)
            let reveal = WebhookSecretReveal()
            reveal.$organization.id = organizationID
            reveal.$subscription.id = id
            reveal.$revision.id = try revision.requireID()
            reveal.secretID = revision.secretID
            reveal.actorID = actorID
            reveal.requestID = requestID
            reveal.createdAt = try await WebhookSubscriptionService.transactionTime(on: db)
            try await reveal.create(on: db)
            return WebhookSecretDTO(secretId: revision.secretID, secret: secret.disclosedValue)
        }
    }

    private func subscriptionID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("subscriptionID", as: UUID.self) else { throw Abort(.notFound) }
        return id
    }
    private func require(_ req: Request) async throws -> (WebhookSubscription, WebhookSubscriptionRevision) {
        try await WebhookSubscriptionService.require(subscriptionID(req), organizationID: req.organizationID, on: req.db)
    }
}
