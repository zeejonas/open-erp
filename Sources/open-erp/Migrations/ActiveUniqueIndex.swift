import Fluent
import SQLKit

extension Database {
    /// A unique index over rows that are not soft-deleted, so a deleted row never blocks recreating it
    /// and history is kept as new rows instead of restored ones.
    func createActiveUniqueIndex(_ name: String, on table: String, columns: String...) async throws {
        let index = try requireSQL().create(index: name).on(table).unique()
        for column in columns {
            index.column(column)
        }
        index.createIndex.predicate = SQLBinaryExpression(SQLColumn("deleted_at"), .is, SQLLiteral.null)
        try await index.run()
    }

    /// An index over all rows, for reads that filter and sort within the leading columns.
    func createIndex(_ name: String, on table: String, columns: String...) async throws {
        let index = try requireSQL().create(index: name).on(table)
        for column in columns {
            index.column(column)
        }
        try await index.run()
    }

    /// A row trigger that keeps approval evidence append-only.
    /// With no protected columns, every update and delete is rejected.
    /// Otherwise a delete is rejected, and an update is rejected only when one of those columns changes.
    /// A write that resends an unchanged value is allowed. `revert` drops the table first, then this function.
    func createAppendOnlyTrigger(
        on table: String,
        in schema: String = "public",
        protected columns: [String] = []
    ) async throws {
        let function = "\(table)_append_only"
        let body: String
        if columns.isEmpty {
            body = """
            BEGIN
                RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
            END;
            """
        } else {
            let changed = columns
                .map { "NEW.\($0) IS DISTINCT FROM OLD.\($0)" }
                .joined(separator: " OR ")
            body = """
            BEGIN
                IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
                    RAISE EXCEPTION '% cannot be deleted', TG_TABLE_NAME;
                END IF;
                IF \(changed) THEN
                    RAISE EXCEPTION '% evidence is append-only', TG_TABLE_NAME;
                END IF;
                RETURN NEW;
            END;
            """
        }
        let sql = try requireSQL()
        try await sql.raw("""
            CREATE FUNCTION \(ident: schema).\(ident: function)() RETURNS trigger
            LANGUAGE plpgsql AS $body$
            \(unsafeRaw: body)
            $body$
            """).run()
        try await sql.raw("""
            CREATE TRIGGER \(ident: function)
            BEFORE UPDATE OR DELETE ON \(ident: schema).\(ident: table)
            FOR EACH ROW
            EXECUTE FUNCTION \(ident: schema).\(ident: function)()
            """).run()
        try await sql.raw("""
            CREATE TRIGGER reject_truncate
            BEFORE TRUNCATE ON \(ident: schema).\(ident: table)
            FOR EACH STATEMENT
            EXECUTE FUNCTION \(ident: schema).\(ident: function)()
            """).run()
    }

    func dropAppendOnlyTriggerFunction(on table: String, in schema: String = "public") async throws {
        let function = "\(table)_append_only"
        try await requireSQL().raw("DROP FUNCTION IF EXISTS \(ident: schema).\(ident: function)()").run()
    }

    func requireSQL() throws -> any SQLDatabase {
        guard let sql = self as? any SQLDatabase else {
            throw MigrationRequiresSQL()
        }
        return sql
    }
}

private struct MigrationRequiresSQL: Error {}
