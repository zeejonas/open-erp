import Fluent
import FluentSQL
import SQLKit

struct CreateAuditEvent: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.requireSQL()
        try await database.schema("audit_events", space: "audit")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("created_at", .datetime, .required, .sql(.default(SQLFunction("clock_timestamp"))))
            .field("organization_id", .uuid)
            .field("table_name", .string, .required)
            .field("record_id", .uuid)
            .field("operation", .string, .required)
            .field("changed_fields", .array(of: .string), .required)
            .field("old_values", .json)
            .field("new_values", .json)
            .field("actor_type", .string, .required)
            .field("actor_id", .uuid)
            .field("actor_name", .string)
            .field("ip_address", .string)
            .field("request_id", .string)
            .field("approval_request_id", .uuid)
            .field("database_user", .string, .required)
            .field("transaction_id", .int64, .required)
            .create()
        try await sql.raw("""
            CREATE INDEX audit_events_organization_time
            ON audit.audit_events (organization_id, created_at DESC, id)
            """).run()
        try await sql.raw("""
            CREATE INDEX audit_events_organization_record
            ON audit.audit_events (organization_id, table_name, record_id)
            """).run()
        try await database.createAppendOnlyTrigger(on: "audit_events", in: "audit")
        try await sql.raw(Self.captureFunction).run()
        // Only the migration owner can attach this privileged function to a table.
        try await sql.raw("REVOKE EXECUTE ON FUNCTION audit.capture_change() FROM PUBLIC").run()
    }

    func revert(on database: any Database) async throws {
        try await database.requireSQL().raw("DROP FUNCTION audit.capture_change()").run()
        try await database.schema("audit_events", space: "audit").delete()
        try await database.dropAppendOnlyTriggerFunction(on: "audit_events", in: "audit")
    }

    private static let captureFunction: SQLQueryString = """
        CREATE FUNCTION audit.capture_change() RETURNS trigger
        LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $body$
        DECLARE
            context jsonb := NULLIF(current_setting('audit.context', true), '')::jsonb;
            old_row jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
            new_row jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
            affected_row jsonb := COALESCE(new_row, old_row);
            redacted_columns text[] := COALESCE(TG_ARGV, ARRAY[]::text[]);
            changed text[];
            action text;
        BEGIN
            IF context IS NULL THEN
                IF NOT (
                    SELECT role.rolsuper OR pg_has_role(role.oid, relation.relowner, 'MEMBER')
                    FROM pg_roles AS role, pg_class AS relation
                    WHERE role.rolname = session_user AND relation.oid = 'audit.audit_events'::regclass
                ) THEN
                    RAISE EXCEPTION 'Missing audit context' USING ERRCODE = '42501';
                END IF;
                context := '{"actor_type":"database"}'::jsonb;
            END IF;

            IF TG_OP = 'UPDATE' AND old_row = new_row THEN
                RETURN NULL;
            END IF;

            action := CASE
                WHEN TG_OP = 'INSERT' THEN 'create'
                WHEN TG_OP = 'DELETE' THEN 'delete'
                WHEN old_row->>'deleted_at' IS NULL AND new_row->>'deleted_at' IS NOT NULL THEN 'soft_delete'
                WHEN old_row->>'deleted_at' IS NOT NULL AND new_row->>'deleted_at' IS NULL THEN 'restore'
                ELSE 'update'
            END;

            SELECT ARRAY(
                SELECT key FROM jsonb_object_keys(affected_row) AS fields(key)
                WHERE old_row->key IS DISTINCT FROM new_row->key
                ORDER BY key
            ) INTO changed;

            INSERT INTO audit.audit_events (
                organization_id, table_name, record_id, operation, changed_fields, old_values, new_values,
                actor_type, actor_id, actor_name, ip_address, request_id, approval_request_id,
                database_user, transaction_id
            ) VALUES (
                (CASE WHEN TG_TABLE_NAME = 'organizations' THEN affected_row->>'id'
                    ELSE affected_row->>'organization_id' END)::uuid,
                TG_TABLE_NAME, (affected_row->>'id')::uuid, action, changed,
                old_row - redacted_columns, new_row - redacted_columns,
                context->>'actor_type', (context->>'actor_id')::uuid, context->>'actor_name',
                context->>'ip_address', context->>'request_id', (context->>'approval_request_id')::uuid,
                session_user, txid_current()
            );
            RETURN NULL;
        END;
        $body$
        """
}

enum CapturedOperation: String, CaseIterable, Sendable {
    case insert = "INSERT", update = "UPDATE", delete = "DELETE"
}

extension Database {
    func createChangeTrigger(
        on table: String, redact columns: [String] = [],
        operations: [CapturedOperation] = CapturedOperation.allCases
    ) async throws {
        precondition(!operations.isEmpty)
        let events = operations.map(\.rawValue).joined(separator: " OR ")
        try await requireSQL().raw("""
            CREATE TRIGGER capture_audit_change
            AFTER \(unsafeRaw: events) ON public.\(ident: table)
            FOR EACH ROW
            EXECUTE FUNCTION audit.capture_change(\(literals: columns, joinedBy: ", "))
            """).run()
    }
}
