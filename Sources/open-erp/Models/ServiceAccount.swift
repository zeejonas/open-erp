import Fluent
import Foundation

/// A non-human principal. Its identity, name and bound subject live on the `users` row with the same ID.
final class ServiceAccount: Model, @unchecked Sendable {
    static let schema = "service_accounts"

    @ID(custom: .id, generatedBy: .user) var id: UUID?
    @Parent(key: "organization_id") var organization: Organization
    @Parent(key: "owner_id") var owner: User
    @OptionalField(key: "description") var description: String?
    @OptionalField(key: "disabled_at") var disabledAt: Date?
    @OptionalParent(key: "disabled_by") var disabledBy: User?
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?
    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "updated_by") var updatedBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(id: UUID, organizationID: UUID, ownerID: UUID, description: String?, createdByID: UUID) {
        self.id = id
        self.$organization.id = organizationID
        self.$owner.id = ownerID
        self.description = description
        self.$createdBy.id = createdByID
    }

    /// `users.email` is required and unique. The reserved `.invalid` TLD (RFC 2606) can never be a verified
    /// identity-provider email, so no invitation can ever match a service account.
    static func email(for id: UUID) -> String {
        "\(id.uuidString.lowercased())@service-accounts.invalid"
    }

    static func query(on db: any Database, organizationID: UUID) -> QueryBuilder<ServiceAccount> {
        query(on: db).filter(\.$organization.$id == organizationID)
    }
}
