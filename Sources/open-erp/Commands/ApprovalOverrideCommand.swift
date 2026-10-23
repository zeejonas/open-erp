import Fluent
import Vapor

struct ApprovalOverrideCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "request", help: "Approval request ID")
        var request: String?

        @Option(name: "operator", help: "Name of the operator overriding the request")
        var operatorName: String?

        @Option(name: "reason", help: "Why the request is being overridden")
        var reason: String?
    }

    var help: String {
        "Complete a pending approval request. Records an override decision with the operator name and reason."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let request = signature.request, let requestID = UUID(uuidString: request) else {
            throw ApprovalOverrideCommandError(description: "Request must be a UUID")
        }
        guard let operatorName = signature.operatorName, !operatorName.isEmpty else {
            throw ApprovalOverrideCommandError(description: "Operator name is required")
        }
        guard let reason = signature.reason, !reason.isEmpty else {
            throw ApprovalOverrideCommandError(description: "A reason is required")
        }
        let db = context.application.db
        guard let existing = try await ApprovalRequest.find(requestID, on: db) else {
            throw ApprovalOverrideCommandError(description: "Request \(request) was not found")
        }
        guard existing.status == ApprovalRequestStatus.pending.rawValue else {
            throw ApprovalOverrideCommandError(description: "Request is not pending")
        }
        let result = try await ApprovalActions.override(
            requestID: requestID,
            organizationID: nil,
            reason: reason,
            operatorName: operatorName,
            actorID: nil,
            on: db
        )
        context.application.logger.notice(
            "Overrode approval request",
            metadata: [
                "request": .string(requestID.uuidString),
                "operator": .string(operatorName),
                "reason": .string(reason),
                "status": .string(result.status),
            ]
        )
        context.console.print("Overrode approval request \(requestID) as \(operatorName): \(result.status)")
    }
}

struct ApprovalOverrideCommandError: Error, CustomStringConvertible {
    var description: String
}
