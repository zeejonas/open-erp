import Fluent
import SQLKit
import Vapor

struct PruneRevokedTokensCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    var help: String { "Delete expired access-token revocations; retain unexpired enforcement records." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let count = try await Self.prune(on: context.application.db)
        context.application.logger.notice("Expired access-token revocations pruned", metadata: ["count": "\(count)"])
        context.console.print("Pruned \(count) expired access-token revocations")
    }

    static func prune(on db: any Database, now: Date = Date()) async throws -> Int {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        // Return a constant per deleted row, never fingerprints.
        return try await sql.delete(from: RevokedAccessToken.schema)
            .where("expires_at", .lessThanOrEqual, SQLBind(now))
            .returning(SQLLiteral.numeric("1"))
            .all()
            .count
    }
}
