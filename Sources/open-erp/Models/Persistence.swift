import Fluent
import FluentPostgresDriver
import Vapor

extension Model {
    /// Fluent's soft delete writes only `deleted_at`, so `deleted_by` is saved first in the same transaction.
    func softDelete(
        by actorID: UUID,
        _ deletedBy: KeyPath<Self, OptionalParentProperty<Self, User>>,
        on db: any Database
    ) async throws {
        self[keyPath: deletedBy].id = actorID
        try await db.transaction { db in
            try await self.save(on: db)
            try await self.delete(on: db)
        }
    }
}

/// Maps a unique-constraint violation to `409`. Uniqueness is enforced by the database so concurrent writes cannot race past a check.
func conflictOnDuplicate<T>(_ reason: String, _ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as PSQLError where error.serverInfo?[.sqlState] == PostgresError.Code.uniqueViolation.raw {
        throw Abort(.conflict, reason: reason)
    }
}
