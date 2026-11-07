import Fluent
import FluentSQL
import SQLKit
import Vapor
import VaporToOpenAPI

struct WebhookDeliveryDTO: Content {
    let id: UUID
    let eventId: UUID
    let subscriptionId: UUID
    let revisionId: UUID
    let state: WebhookDeliveryState
    let attemptCount: Int
    let nextAttemptAt: Date
    let firstAttemptAt: Date?
    let cancellationReason: WebhookCancellationReason?
    let createdAt: Date
    init(_ delivery: WebhookDelivery) throws {
        id = try delivery.requireID()
        eventId = delivery.$event.id
        subscriptionId = delivery.$subscription.id
        revisionId = delivery.$revision.id
        state = delivery.state
        attemptCount = delivery.attemptCount
        nextAttemptAt = delivery.nextAttemptAt
        firstAttemptAt = delivery.firstAttemptAt
        cancellationReason = delivery.cancellationReason
        createdAt = delivery.createdAt
    }
}

struct WebhookAttemptDTO: Content {
    let id: UUID
    let revisionId: UUID
    let secretId: UUID
    let payloadDigest: String
    let createdAt: Date
    let startedAt: Date
    let finishedAt: Date?
    let httpStatus: Int?
    let outcome: WebhookAttemptOutcome
    let reason: String?
    init(start: WebhookDeliveryEntry, result: WebhookDeliveryEntry?) throws {
        guard let id = start.attemptID, let secretId = start.secretID, let startedAt = start.startedAt else { throw BusinessEventWriter.InvalidTransaction() }
        self.id = id
        revisionId = start.$revision.id
        self.secretId = secretId
        payloadDigest = start.payloadDigest
        createdAt = start.createdAt
        self.startedAt = startedAt
        finishedAt = result?.finishedAt
        httpStatus = result?.httpStatus
        outcome = result?.outcome ?? .started
        reason = result?.reason
    }
}

struct WebhookHealthDTO: Content {
    let counts: [String: Int]
    let oldestQueuedAt: Date?
    let lastAcknowledgedAt: Date?
    let lastFailureAt: Date?
    let medianAttemptDurationSeconds: Double?
    let failingSince: Date?
    let disabledReason: WebhookDisabledReason?
    let needsAttention: Bool
}

struct WebhookDeliveryFilters: ListFilters {
    static let keys: Set<String> = ["subscriptionId", "eventId", "state", "from", "to"]
    var subscriptionId: UUID?
    var eventId: UUID?
    var state: WebhookDeliveryState?
    var from: String?
    var to: String?
    static func validations(_ validations: inout Validations) {
        validations.add("subscriptionId", as: UUID.self, required: false)
        validations.add("eventId", as: UUID.self, required: false)
        validations.add("state", as: String.self, is: .case(of: WebhookDeliveryState.self), required: false)
        validations.add("from", as: String.self, is: !.empty, required: false)
        validations.add("to", as: String.self, is: !.empty, required: false)
    }
}

struct WebhookAttemptFilters: ListFilters {
    static let keys: Set<String> = ["outcome", "from", "to"]
    var outcome: WebhookAttemptOutcome?
    var from: String?
    var to: String?
    static func validations(_ validations: inout Validations) {
        validations.add("outcome", as: String.self, is: .case(of: WebhookAttemptOutcome.self), required: false)
        validations.add("from", as: String.self, is: !.empty, required: false)
        validations.add("to", as: String.self, is: !.empty, required: false)
    }
}

struct WebhookDeliveryController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let scoped = routes.grouped(AuthMiddleware(), OrganizationMiddleware())
        scoped.get("webhook-deliveries", use: index)
            .openAPI(summary: "List webhook deliveries", description: "Requires webhook_delivery:read. Exact subscriptionId, eventId and state filters, inclusive ISO 8601 from/to. createdAt descending then id ascending; no sort.", query: [.type(ListPage.self), .type(WebhookDeliveryFilters.self)], headers: .type(OrganizationHeaders.self), response: .type(Page<WebhookDeliveryDTO>.self), auth: .bearer())
            .problemResponses(.badRequest)
        scoped.get("webhook-deliveries", ":deliveryID", use: show)
            .openAPI(summary: "Get webhook delivery", description: "Requires webhook_delivery:read. Acknowledged means HTTP transport receipt, not downstream processing.", headers: .type(OrganizationHeaders.self), response: .type(WebhookDeliveryDTO.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound)
        scoped.get("webhook-deliveries", ":deliveryID", "attempts", use: attempts)
            .openAPI(summary: "List webhook attempts", description: "Requires webhook_delivery:read. Immutable start/result pairs with outcome and inclusive ISO 8601 from/to filters. Ordered by start createdAt descending then start id ascending; no sort.", query: [.type(ListPage.self), .type(WebhookAttemptFilters.self)], headers: .type(OrganizationHeaders.self), response: .type(Page<WebhookAttemptDTO>.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound)
        scoped.get("webhook-deliveries", ":deliveryID", "payload", use: payload)
            .openAPI(summary: "Inspect webhook delivery payload", description: "Requires webhook_delivery:read, webhook_payload:read and the event's source-read permission. Returns exact retained bytes.", headers: .type(OrganizationHeaders.self), response: .schema(BusinessEventSchemas.envelope), auth: .bearer())
            .problemResponses(.badRequest, .notFound)
        scoped.get("webhook-subscriptions", ":subscriptionID", "health", use: health)
            .openAPI(summary: "Get webhook subscription health", description: "Requires webhook_delivery:read. Counts, backlog age, acknowledgment/failure times, median attempt duration over 24 hours, continuous failure and attention flags. No payloads or secrets.", headers: .type(OrganizationHeaders.self), response: .type(WebhookHealthDTO.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound)
    }

    @Sendable func index(req: Request) async throws -> Page<WebhookDeliveryDTO> {
        try req.require(.webhookDeliveryRead)
        let (filters, page) = try req.listParameters(WebhookDeliveryFilters.self)
        let query = WebhookDelivery.query(on: req.db).filter(\.$organization.$id == req.organizationID)
        if let value = filters.subscriptionId { query.filter(\.$subscription.$id == value) }
        if let value = filters.eventId { query.filter(\.$event.$id == value) }
        if let value = filters.state { query.filter(\.$state == value) }
        if let value = try webhookTimestamp(filters.from, named: "from") { query.filter(\.$createdAt >= value) }
        if let value = try webhookTimestamp(filters.to, named: "to") { query.filter(\.$createdAt <= value) }
        return try await query.newestFirst(\.$createdAt).paginate(page).map(WebhookDeliveryDTO.init)
    }

    @Sendable func show(req: Request) async throws -> WebhookDeliveryDTO {
        try req.require(.webhookDeliveryRead)
        return try await WebhookDeliveryDTO(require(req))
    }

    @Sendable func attempts(req: Request) async throws -> Page<WebhookAttemptDTO> {
        try req.require(.webhookDeliveryRead)
        let delivery = try await require(req)
        let (filters, page) = try req.listParameters(WebhookAttemptFilters.self)
        let query = try WebhookDeliveryEntry.query(on: req.db).filter(\.$organization.$id == req.organizationID)
            .filter(\.$delivery.$id == delivery.requireID()).filter(\.$kind == .started)
        if let value = try webhookTimestamp(filters.from, named: "from") { query.filter(\.$createdAt >= value) }
        if let value = try webhookTimestamp(filters.to, named: "to") { query.filter(\.$createdAt <= value) }
        if let outcome = filters.outcome {
            query.filter(.sql(embed: """
                COALESCE((SELECT result.outcome FROM webhook_delivery_entries AS result
                    WHERE result.organization_id = webhook_delivery_entries.organization_id
                        AND result.attempt_id = webhook_delivery_entries.attempt_id AND result.kind = 'result'), 'started') = \(bind: outcome.rawValue)
                """))
        }
        let starts = try await query.newestFirst(\.$createdAt).paginate(page)
        let ids = starts.items.compactMap(\.attemptID)
        let results = ids.isEmpty ? [] : try await WebhookDeliveryEntry.query(on: req.db).filter(\.$organization.$id == req.organizationID)
            .filter(\.$delivery.$id == delivery.requireID()).filter(\.$kind == .result).filter(\.$attemptID ~~ ids).all()
        let byID = Dictionary(uniqueKeysWithValues: results.compactMap { result in result.attemptID.map { ($0, result) } })
        return try Page(items: starts.items.map { try WebhookAttemptDTO(start: $0, result: $0.attemptID.flatMap { byID[$0] }) }, metadata: starts.metadata)
    }

    @Sendable func payload(req: Request) async throws -> Response {
        try req.require(.webhookDeliveryRead)
        try req.require(.webhookPayloadRead)
        let delivery = try await require(req)
        guard let event = try await BusinessEvent.metadata(on: req.db, organizationID: req.organizationID)
            .filter(\.$id == delivery.$event.id).first() else { throw Abort(.notFound) }
        try req.require(event.type.sourceReadPermission)
        guard let payload = try await BusinessEvent.query(on: req.db).filter(\.$id == delivery.$event.id).field(\.$payload).first()?.payload else { throw Abort(.notFound) }
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: payload))
    }

    @Sendable func health(req: Request) async throws -> WebhookHealthDTO {
        try req.require(.webhookDeliveryRead)
        guard let id = req.parameters.get("subscriptionID", as: UUID.self) else { throw Abort(.notFound) }
        let (subscription, _) = try await WebhookSubscriptionService.require(id, organizationID: req.organizationID, on: req.db)
        let sql = try req.db.requireSQL()
        let rows = try await sql.raw("SELECT state, count(*) AS count FROM webhook_deliveries WHERE organization_id = \(bind: req.organizationID) AND subscription_id = \(bind: id) GROUP BY state").all()
        var counts = Dictionary(uniqueKeysWithValues: WebhookDeliveryState.allCases.map { ($0.rawValue, 0) })
        for row in rows { counts[try row.decode(column: "state", as: String.self)] = try row.decode(column: "count", as: Int.self) }
        let aggregate = try await sql.raw("""
            SELECT
                MIN(delivery.created_at) FILTER (WHERE delivery.state IN ('pending', 'retrying')) AS oldest_queued,
                MAX(entry.finished_at) FILTER (WHERE entry.outcome = 'acknowledged') AS last_ack,
                MAX(entry.finished_at) FILTER (WHERE entry.kind = 'result' AND entry.outcome <> 'acknowledged') AS last_failure,
                MAX(entry.finished_at) FILTER (WHERE delivery.state = 'exhausted') AS last_exhausted,
                percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM entry.finished_at - entry.started_at))
                    FILTER (WHERE entry.kind = 'result' AND entry.finished_at >= clock_timestamp() - interval '24 hours') AS median_duration
            FROM webhook_deliveries AS delivery
            LEFT JOIN webhook_delivery_entries AS entry ON entry.delivery_id = delivery.id AND entry.organization_id = delivery.organization_id
            WHERE delivery.organization_id = \(bind: req.organizationID) AND delivery.subscription_id = \(bind: id)
            """).first()
        let oldest = try aggregate?.decode(column: "oldest_queued", as: Date?.self) ?? nil
        let ack = try aggregate?.decode(column: "last_ack", as: Date?.self) ?? nil
        let failure = try aggregate?.decode(column: "last_failure", as: Date?.self) ?? nil
        let exhausted = try aggregate?.decode(column: "last_exhausted", as: Date?.self) ?? nil
        let median = try aggregate?.decode(column: "median_duration", as: Double?.self) ?? nil
        let attention = subscription.disabledReason == .autoPaused || oldest.map { Date().timeIntervalSince($0) > 300 } == true
            || exhausted.map { $0 > (ack ?? .distantPast) } == true
        return .init(counts: counts, oldestQueuedAt: oldest, lastAcknowledgedAt: ack, lastFailureAt: failure,
            medianAttemptDurationSeconds: median, failingSince: subscription.failingSince, disabledReason: subscription.disabledReason, needsAttention: attention)
    }

    private func require(_ req: Request) async throws -> WebhookDelivery {
        guard let id = req.parameters.get("deliveryID", as: UUID.self), let delivery = try await WebhookDelivery.query(on: req.db)
            .filter(\.$organization.$id == req.organizationID).filter(\.$id == id).first() else { throw Abort(.notFound) }
        return delivery
    }
}
