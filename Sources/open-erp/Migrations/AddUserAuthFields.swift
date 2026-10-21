import Fluent
import FluentSQL
import SQLKit

struct AddUserAuthFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("auth_subject", .string)
            .field("is_platform_admin", .bool, .required, .sql(.default(false)))
            .unique(on: "auth_subject")
            .update()
    }

    func revert(on database: any Database) async throws {
        // Dropping the column also drops its unique constraint. Fluent's generated
        // constraint name does not match the name Postgres assigns on update.
        try await database.schema("users")
            .deleteField("auth_subject")
            .deleteField("is_platform_admin")
            .update()
    }
}
