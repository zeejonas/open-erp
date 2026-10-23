import Fluent
import Vapor

struct ApprovalWriteResult: @unchecked Sendable {
    private let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func cast<T>() throws -> T {
        guard let typed = value as? T else {
            throw Abort(.internalServerError, reason: "Unexpected approval result")
        }
        return typed
    }
}

enum ApprovalOutcome<T: AsyncResponseEncodable & Sendable>: AsyncResponseEncodable, Sendable {
    case applied(T)
    case held(GetApprovalRequestDTO)

    func encodeResponse(for request: Request) async throws -> Response {
        switch self {
        case .applied(let value):
            return try await value.encodeResponse(for: request)
        case .held(let body):
            let response = Response(status: .accepted)
            try response.content.encode(body)
            return response
        }
    }
}

struct NewDecision: Sendable {
    var trackID: UUID?
    var stage: Int?
    var kind: ApprovalDecisionKind
    var decidedByID: UUID?
    var operatorName: String?
    var qualifyingGroupIDs: [UUID]
    var comment: String?

    func insert(requestID: UUID, on db: any Database) async throws {
        try await ApprovalDecision(
            requestID: requestID,
            trackID: trackID,
            stage: stage,
            kind: kind.rawValue,
            decidedByID: decidedByID,
            operatorName: operatorName,
            qualifyingGroupIDs: qualifyingGroupIDs,
            comment: comment
        ).save(on: db)
    }
}

struct ApprovalApplyFailure: Error, Sendable {
    var reason: String
    var decisions: [NewDecision]
    var actorID: UUID?
}
