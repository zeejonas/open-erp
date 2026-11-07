import Fluent
import Foundation
import SQLKit
import Vapor

enum AuditActorType: String, Codable, CaseIterable, Sendable {
    case user, platformAdmin = "platform_admin", `operator`, system, database
}

struct AuditContext: Encodable, Sendable {
    let actorType: AuditActorType
    var actorID: UUID?
    var actorName: String?
    var ipAddress: String?
    var requestID: String?
    var approvalRequestID: UUID?

    enum CodingKeys: String, CodingKey {
        case actorType = "actor_type"
        case actorID = "actor_id"
        case actorName = "actor_name"
        case ipAddress = "ip_address"
        case requestID = "request_id"
        case approvalRequestID = "approval_request_id"
    }

    func forApproval(_ id: UUID) -> Self {
        var context = self
        context.approvalRequestID = id
        return context
    }
}

extension Request {
    func auditContext(
        actorType: AuditActorType = .user,
        user: User? = nil,
        verifiedSubject: String? = nil
    ) throws -> AuditContext {
        let actorID = try (user ?? authenticatedUser)?.requireID()
        guard actorID != nil || verifiedSubject != nil else { throw Abort(.internalServerError) }
        return AuditContext(
            actorType: actorType,
            actorID: actorID,
            actorName: actorID == nil ? verifiedSubject : nil,
            ipAddress: auditClientIP,
            requestID: id
        )
    }
}

extension Database {
    func auditedTransaction<T: Sendable>(
        _ context: AuditContext,
        _ body: @escaping @Sendable (any Database) async throws -> T
    ) async throws -> T {
        try await transaction { database in
            try await database.setAuditContext(context)
            return try await body(database)
        }
    }

    func setAuditContext(_ context: AuditContext) async throws {
        let json = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        try await requireSQL().raw("SELECT pg_catalog.set_config('audit.context', \(bind: json), true)").run()
    }
}
