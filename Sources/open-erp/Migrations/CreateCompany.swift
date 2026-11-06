import Fluent
import FluentSQL
import SQLKit

struct CreateCompany: AsyncMigration {
    /// The ICU root collation sorts the same on every PostgreSQL build; libc locales depend on the OS.
    private static let sortableText = DatabaseSchema.DataType.sql(unsafeRaw: #"TEXT COLLATE "und-x-icu""#)

    func prepare(on database: any Database) async throws {
        try await database.schema("companies")
            .field("id", .uuid, .identifier(auto: false), .sql(.default(SQLFunction("gen_random_uuid"))))
            .field("code", Self.sortableText, .required)
            .field("name", Self.sortableText, .required)
            .field("organization_id", .uuid, .required, .references("organizations", "id"))
            .field("created_by", .uuid, .references("users", "id"))
            .field("updated_by", .uuid, .references("users", "id"))
            .field("deleted_by", .uuid, .references("users", "id"))
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .field("deleted_at", .datetime)
            .unique(on: "organization_id", "code")
            .unique(on: "organization_id", "id")
            .create()
        // `(organization_id, code)` is already indexed by the unique constraint.
        for column in ["name", "updated_at"] {
            try await database.createIndex("companies_organization_id_\(column)_idx", on: "companies", columns: "organization_id", column)
        }
        try await database.createChangeTrigger(on: "companies")
    }

    func revert(on database: any Database) async throws {
        try await database.schema("companies").delete()
    }
}