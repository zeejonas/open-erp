import Fluent
import Foundation
import Vapor
import VaporToOpenAPI

struct AuditEventController: RouteCollection {
    private static let listDescription = "Newest createdAt first, then id ascending. Exact filters combine with AND. from and to are inclusive ISO 8601 timestamps. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400."

    func boot(routes: any RoutesBuilder) throws {
        let authenticated = routes.grouped(AuthMiddleware())
        authenticated.grouped(OrganizationMiddleware()).get("audit-events", use: self.tenant)
            .openAPI(
                summary: "List organization audit events",
                description: "Requires audit_event:read. Returns only this organization's events. Actor names are visible for operator and system actors, IP addresses for user actors, and database users are omitted. " + Self.listDescription,
                query: [.type(ListPage.self), .type(AuditEventFilters.self)],
                headers: .type(OrganizationHeaders.self),
                response: .type(Page<AuditEventDTO>.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest)
        authenticated.grouped(PlatformAdminMiddleware()).get("platform", "audit-events", use: self.platform)
            .openAPI(
                summary: "List global audit events",
                description: "Platform administrator only. Returns global events with full attribution. " + Self.listDescription,
                query: [.type(ListPage.self), .type(AuditEventFilters.self)],
                response: .type(Page<AuditEventDTO>.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest)
    }

    @Sendable
    private func tenant(req: Request) async throws -> Page<AuditEventDTO> {
        try req.require(.auditEventRead)
        return try await list(req, organizationID: req.organizationID)
    }

    @Sendable
    private func platform(req: Request) async throws -> Page<AuditEventDTO> {
        try await list(req, organizationID: nil)
    }

    private func list(_ req: Request, organizationID: UUID?) async throws -> Page<AuditEventDTO> {
        let (filters, page) = try req.listParameters(AuditEventFilters.self)
        let query = AuditEvent.query(on: req.db).filter(\.$organizationID == organizationID)
        if let table = filters.table { query.filter(\.$tableName == table) }
        if let recordID = filters.recordId { query.filter(\.$recordID == recordID) }
        if let actorID = filters.actorId { query.filter(\.$actorID == actorID) }
        if let operation = filters.operation { query.filter(\.$operation == operation) }
        if let requestID = filters.requestId { query.filter(\.$requestID == requestID) }
        if let from = try filters.timestamp(filters.from, named: "from") { query.filter(\.$createdAt >= from) }
        if let to = try filters.timestamp(filters.to, named: "to") { query.filter(\.$createdAt <= to) }

        return try await query.newestFirst(\.$createdAt).paginate(page)
            .map { try AuditEventDTO($0, platform: organizationID == nil) }
    }
}

private struct AuditEventFilters: ListFilters {
    static let keys: Set<String> = ["table", "recordId", "actorId", "operation", "requestId", "from", "to"]
    var table: String?
    var recordId: UUID?
    var actorId: UUID?
    var operation: AuditOperation?
    var requestId: String?
    var from: String?
    var to: String?

    static func validations(_ validations: inout Validations) {
        validations.add("table", as: String.self, is: !.empty, required: false)
        validations.add("recordId", as: UUID.self, required: false)
        validations.add("actorId", as: UUID.self, required: false)
        validations.add("operation", as: String.self, is: .case(of: AuditOperation.self), required: false)
        validations.add("requestId", as: String.self, is: !.empty, required: false)
        validations.add("from", as: String.self, is: !.empty, required: false)
        validations.add("to", as: String.self, is: !.empty, required: false)
    }

    func timestamp(_ value: String?, named name: String) throws -> Date? {
        guard let value else { return nil }
        guard let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
        else {
            throw Abort(.badRequest, reason: "Invalid ISO 8601 timestamp for \(name)")
        }
        return date
    }
}
