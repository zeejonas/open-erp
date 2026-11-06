import Fluent
import SQLKit

private let globalAuditTables = ["organizations", "revoked_access_tokens", "users"]

func auditCoverageProblems(on database: any Database) async throws -> [String] {
    let sql = try database.requireSQL()
    let auditTable = try await sql.raw("""
        SELECT pg_catalog.to_regclass('audit.audit_events') IS NOT NULL AS present
        """).first()
    var problems: [String] = []
    if try auditTable?.decode(column: "present", as: Bool.self) != true {
        problems.append("audit.audit_events is missing")
    }

    // 29 is the catalog bit mask for an AFTER INSERT OR UPDATE OR DELETE row trigger.
    let tables = try await sql.raw("""
        SELECT relation.relname::text AS name,
            EXISTS (
                SELECT FROM pg_catalog.pg_trigger AS trigger
                WHERE trigger.tgrelid = relation.oid
                    AND trigger.tgfoid = pg_catalog.to_regprocedure('audit.capture_change()')
                    AND trigger.tgtype = 29
                    AND trigger.tgenabled IN ('O', 'A')
                    AND trigger.tgqual IS NULL
                    AND trigger.tgattr::text = ''
            ) AS captured,
            EXISTS (
                SELECT FROM pg_catalog.pg_attribute AS attribute
                WHERE attribute.attrelid = relation.oid
                    AND attribute.attname = 'organization_id'
                    AND attribute.atttypid = 'pg_catalog.uuid'::pg_catalog.regtype
                    AND attribute.attnotnull AND NOT attribute.attisdropped
            ) AS tenant_scoped
        FROM pg_catalog.pg_class AS relation
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public' AND relation.relkind IN ('r', 'p')
            AND relation.relname <> '_fluent_migrations'
        ORDER BY relation.relname
        """).all()

    for row in tables {
        let table = try row.decode(column: "name", as: String.self)
        if try !row.decode(column: "captured", as: Bool.self) {
            problems.append("public.\(table) lacks an enabled audit change trigger")
        }
        if !globalAuditTables.contains(table), try !row.decode(column: "tenant_scoped", as: Bool.self) {
            problems.append("public.\(table) lacks a required organization_id and is unclassified")
        }
    }
    return problems
}

func auditGrantProblems(on database: any Database) async throws -> [String] {
    let sql = try database.requireSQL()
    let rows = try await sql.raw("""
        WITH audit_table AS (
            SELECT oid, relowner FROM pg_catalog.pg_class
            WHERE oid = pg_catalog.to_regclass('audit.audit_events')
        ), application_tables AS (
            SELECT relation.oid, relation.relname::text AS name
            FROM pg_catalog.pg_class AS relation
            JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname = 'public' AND relation.relkind IN ('r', 'p')
                AND relation.relname <> '_fluent_migrations'
        ), accessible_roles AS (
            SELECT login.rolname::text AS name, granted.oid
            FROM pg_catalog.pg_roles AS login
            CROSS JOIN audit_table
            JOIN pg_catalog.pg_roles AS granted ON pg_catalog.pg_has_role(login.oid, granted.oid, 'SET')
            WHERE login.rolcanlogin AND NOT login.rolsuper
                AND NOT pg_catalog.pg_has_role(login.oid, audit_table.relowner, 'MEMBER')
        )
        SELECT DISTINCT role.name, 'audit.audit_events' AS target
        FROM accessible_roles AS role CROSS JOIN audit_table
        WHERE pg_catalog.has_table_privilege(role.oid, audit_table.oid, 'INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER')
            OR pg_catalog.has_any_column_privilege(role.oid, audit_table.oid, 'INSERT,UPDATE')
        UNION
        SELECT DISTINCT role.name, 'public.' || relation.name AS target
        FROM accessible_roles AS role CROSS JOIN application_tables AS relation
        WHERE pg_catalog.has_table_privilege(role.oid, relation.oid, 'TRUNCATE,TRIGGER')
        UNION
        SELECT DISTINCT role.name, 'audit.capture_change()' AS target
        FROM accessible_roles AS role
        WHERE pg_catalog.has_function_privilege(role.oid, pg_catalog.to_regprocedure('audit.capture_change()'), 'EXECUTE')
        UNION
        SELECT DISTINCT role.name, 'public._fluent_migrations' AS target
        FROM accessible_roles AS role
        WHERE pg_catalog.has_table_privilege(role.oid, pg_catalog.to_regclass('public._fluent_migrations')::oid, 'INSERT,UPDATE,DELETE,TRUNCATE')
        ORDER BY name, target
        """).all()
    return try rows.map { row in
        let role = try row.decode(column: "name", as: String.self)
        let target = try row.decode(column: "target", as: String.self)
        return "Database role \(role) has unsafe privileges on \(target)"
    }
}
