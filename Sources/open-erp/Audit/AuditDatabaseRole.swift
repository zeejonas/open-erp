import Fluent
import SQLKit
import Vapor

enum AuditSafetyError: Error, CustomStringConvertible {
    case unsafeDatabaseRole
    case verificationFailed

    var description: String {
        switch self {
        case .unsafeDatabaseRole:
            "Serving requires a database role separate from the audit owner and superusers"
        case .verificationFailed:
            "Audit verification failed"
        }
    }
}

func checkServingDatabaseRole(
    on database: any Database,
    environment: Environment,
    logger: Logger
) async throws {
    guard environment != .testing else { return }
    let sql = try database.requireSQL()
    let row = try await sql.raw("""
        SELECT role.rolsuper OR EXISTS (
            SELECT FROM pg_catalog.pg_namespace AS namespace
            WHERE namespace.nspname = 'audit'
                AND pg_catalog.pg_has_role(role.oid, namespace.nspowner, 'MEMBER')
        ) AS unsafe
        FROM pg_catalog.pg_roles AS role
        WHERE role.rolname = session_user
        """).first()
    guard try row?.decode(column: "unsafe", as: Bool.self) == true else { return }
    let error = AuditSafetyError.unsafeDatabaseRole
    if environment == .production { throw error }
    logger.warning("\(error.description)")
}
