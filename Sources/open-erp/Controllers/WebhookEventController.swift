import Fluent
import Vapor
import VaporToOpenAPI

struct WebhookEventTypeDTO: Content, @unchecked Sendable {
    let type: BusinessEventType
    let schemaVersion: Int
    let resourceType: BusinessResourceType
    let sourceReadPermission: String
    let supportsCompanyFilter: Bool
    let emittingOperation: String
    let summarySchema: SchemaObject

    init(_ event: BusinessEventType) {
        type = event
        schemaVersion = 1
        resourceType = event.resourceType
        sourceReadPermission = event.sourceReadPermission.rawValue
        supportsCompanyFilter = event.supportsCompanyFilter
        emittingOperation = event.emittingOperation
        summarySchema = BusinessEventSchemas.summary(event.resourceType)
    }
}

struct WebhookEventDTO: Content {
    let id: UUID
    let type: BusinessEventType
    let schemaVersion: Int
    let createdAt: Date
    let organizationId: UUID
    let companyId: UUID?
    let resource: BusinessEventEnvelope.Resource
    let actor: BusinessEventEnvelope.Actor
    let requestedById: UUID?
    let requestId: String?
    let approvalRequestId: UUID?
    let changedFields: [String]

    init(_ event: BusinessEvent) throws {
        id = try event.requireID()
        type = event.type
        schemaVersion = event.schemaVersion
        createdAt = event.createdAt
        organizationId = event.$organization.id
        companyId = event.companyID
        resource = .init(type: event.resourceType, id: event.resourceID, revision: event.revision)
        actor = .init(type: event.actorType, id: event.actorID)
        requestedById = event.requestedByID
        requestId = event.requestID
        approvalRequestId = event.approvalRequestID
        changedFields = event.changedFields
    }
}

struct WebhookEventFilters: ListFilters {
    static let keys: Set<String> = ["type", "resourceType", "resourceId", "companyId", "approvalRequestId", "requestId", "from", "to"]
    var type: BusinessEventType?
    var resourceType: BusinessResourceType?
    var resourceId: UUID?
    var companyId: UUID?
    var approvalRequestId: UUID?
    var requestId: String?
    var from: String?
    var to: String?
    static func validations(_ validations: inout Validations) {
        validations.add("type", as: String.self, is: .case(of: BusinessEventType.self), required: false)
        validations.add("resourceType", as: String.self, is: .case(of: BusinessResourceType.self), required: false)
        for key: ValidationKey in ["resourceId", "companyId", "approvalRequestId"] { validations.add(key, as: UUID.self, required: false) }
        for key: ValidationKey in ["requestId", "from", "to"] { validations.add(key, as: String.self, is: !.empty, required: false) }
    }
}

func webhookTimestamp(_ value: String?, named name: String) throws -> Date? {
    guard let value else { return nil }
    guard let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
        ?? (try? Date.ISO8601FormatStyle().parse(value)) else {
        throw Abort(.badRequest, reason: "Invalid ISO 8601 timestamp for \(name)")
    }
    return date
}

struct WebhookEventController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let scoped = routes.grouped(AuthMiddleware(), OrganizationMiddleware())
        scoped.get("webhook-event-types", use: catalog)
            .openAPI(summary: "List supported webhook event types", description: "Requires webhook_event:read. Type ascending; no filters or sort. v1 summaries explicitly exclude sensitive fields.", query: .type(ListPage.self), headers: .type(OrganizationHeaders.self), response: .type(Page<WebhookEventTypeDTO>.self), auth: .bearer())
            .problemResponses(.badRequest)
        scoped.get("webhook-events", use: index)
            .openAPI(summary: "List organization business events", description: "Requires webhook_event:read. Exact filters combine with AND. Inclusive ISO 8601 from/to. createdAt descending, id ascending. No sort. Metadata excludes payloads and internal database linkage.", query: [.type(ListPage.self), .type(WebhookEventFilters.self)], headers: .type(OrganizationHeaders.self), response: .type(Page<WebhookEventDTO>.self), auth: .bearer())
            .problemResponses(.badRequest)
        scoped.get("webhook-events", ":eventID", use: show)
            .openAPI(summary: "Get business event metadata", description: "Requires webhook_event:read.", headers: .type(OrganizationHeaders.self), response: .type(WebhookEventDTO.self), auth: .bearer())
            .problemResponses(.badRequest, .notFound)
        scoped.get("webhook-events", ":eventID", "payload", use: payload)
            .openAPI(summary: "Inspect exact business event payload", description: "Requires webhook_event:read and webhook_payload:read. Returns the retained UTF-8 JSON bytes. Nullable envelope fields are present as null; data is allowlisted by event type.", headers: .type(OrganizationHeaders.self), response: .schema(BusinessEventSchemas.envelope), auth: .bearer())
            .problemResponses(.badRequest, .notFound)
    }

    @Sendable func catalog(req: Request) async throws -> Page<WebhookEventTypeDTO> {
        try req.require(.webhookEventRead)
        let (_, page) = try req.listParameters(NoFilters.self)
        let events = BusinessEventType.allCases.sorted { $0.rawValue < $1.rawValue }
        let start = (page.page - 1).multipliedReportingOverflow(by: page.per)
        let slice = start.overflow ? [] : Array(events.dropFirst(start.partialValue).prefix(page.per))
        return Page(items: slice.map(WebhookEventTypeDTO.init), metadata: .init(page: page.page, per: page.per, total: events.count))
    }

    @Sendable func index(req: Request) async throws -> Page<WebhookEventDTO> {
        try req.require(.webhookEventRead)
        let (filters, page) = try req.listParameters(WebhookEventFilters.self)
        let query = BusinessEvent.metadata(on: req.db, organizationID: req.organizationID)
        if let value = filters.type { query.filter(\.$type == value) }
        if let value = filters.resourceType { query.filter(\.$resourceType == value) }
        if let value = filters.resourceId { query.filter(\.$resourceID == value) }
        if let value = filters.companyId { query.filter(\.$companyID == value) }
        if let value = filters.approvalRequestId { query.filter(\.$approvalRequestID == value) }
        if let value = filters.requestId { query.filter(\.$requestID == value) }
        if let value = try webhookTimestamp(filters.from, named: "from") { query.filter(\.$createdAt >= value) }
        if let value = try webhookTimestamp(filters.to, named: "to") { query.filter(\.$createdAt <= value) }
        return try await query.newestFirst(\.$createdAt).paginate(page).map(WebhookEventDTO.init)
    }

    @Sendable func show(req: Request) async throws -> WebhookEventDTO {
        try req.require(.webhookEventRead)
        return try await WebhookEventDTO(require(req))
    }

    @Sendable func payload(req: Request) async throws -> Response {
        try req.require(.webhookEventRead)
        try req.require(.webhookPayloadRead)
        let event = try await require(req, payload: true)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: event.payload))
    }

    private func require(_ req: Request, payload: Bool = false) async throws -> BusinessEvent {
        let query = payload ? BusinessEvent.query(on: req.db).filter(\.$organization.$id == req.organizationID)
            : BusinessEvent.metadata(on: req.db, organizationID: req.organizationID)
        guard let id = req.parameters.get("eventID", as: UUID.self), let event = try await query.filter(\.$id == id).first() else { throw Abort(.notFound) }
        return event
    }
}
