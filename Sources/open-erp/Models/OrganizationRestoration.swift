import Fluent
import Foundation

final class OrganizationRestoration: Model, @unchecked Sendable {
    static let schema = "organization_restorations"

    @ID(key: .id) var id: UUID?
    @Parent(key: "organization_id") var organization: Organization
    @Field(key: "deleted_at") var deletedAt: Date
    @OptionalParent(key: "deleted_by") var deletedBy: User?
    @Parent(key: "restored_by") var restoredBy: User
    @Field(key: "reason") var reason: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(organizationID: UUID, deletedAt: Date, deletedByID: UUID?, restoredByID: UUID, reason: String) {
        self.$organization.id = organizationID
        self.deletedAt = deletedAt
        self.$deletedBy.id = deletedByID
        self.$restoredBy.id = restoredByID
        self.reason = reason
    }
}
