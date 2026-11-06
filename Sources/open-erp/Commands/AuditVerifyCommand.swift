import Fluent
import Vapor

struct AuditVerifyCommand: AsyncCommand {
    struct Signature: CommandSignature {}

    var help: String { "Check audit trigger coverage and database grants." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let db = context.application.db
        let coverage = try await auditCoverageProblems(on: db)
        let grants = try await auditGrantProblems(on: db)
        let problems = coverage + grants
        guard problems.isEmpty else {
            for problem in problems { context.console.error(problem) }
            throw AuditSafetyError.verificationFailed
        }
        context.console.print("Audit verification passed")
    }
}
