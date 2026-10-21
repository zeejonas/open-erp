import Fluent
import SQLKit

extension Database {
    /// A unique index over rows that are not soft-deleted, so a deleted row never blocks recreating it
    /// and history is kept as new rows instead of restored ones.
    func createActiveUniqueIndex(_ name: String, on table: String, columns: String...) async throws {
        let index = try sql().create(index: name).on(table).unique()
        for column in columns {
            index.column(column)
        }
        index.createIndex.predicate = SQLBinaryExpression(SQLColumn("deleted_at"), .is, SQLLiteral.null)
        try await index.run()
    }

    func dropIndex(_ name: String) async throws {
        try await sql().drop(index: name).run()
    }

    private func sql() throws -> any SQLDatabase {
        guard let sql = self as? any SQLDatabase else {
            throw MigrationRequiresSQL()
        }
        return sql
    }
}

private struct MigrationRequiresSQL: Error {}
