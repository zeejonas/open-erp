import Crypto
import Fluent
import Foundation
import Vapor

enum InvitationToken {
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    static func generate() -> String {
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class OrganizationInvitation: Model, @unchecked Sendable {
    static let schema = "organization_invitations"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "organization_id")
    var organization: Organization

    @Field(key: "email")
    var email: String

    @Field(key: "first_name")
    var firstName: String

    @Field(key: "last_name")
    var lastName: String

    @OptionalParent(key: "group_id")
    var group: AccessGroup?

    @OptionalParent(key: "approval_request_id")
    var approvalRequest: ApprovalRequest?

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "accepted_at")
    var acceptedAt: Date?

    @OptionalParent(key: "accepted_by")
    var acceptedBy: User?

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(
        organizationID: UUID,
        email: String,
        firstName: String,
        lastName: String,
        groupID: UUID?,
        tokenHash: String,
        expiresAt: Date,
        createdByID: UUID?,
        approvalRequestID: UUID? = nil
    ) {
        self.$organization.id = organizationID
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.$group.id = groupID
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
        self.$createdBy.id = createdByID
        self.$approvalRequest.id = approvalRequestID
    }

    func toGetDTO() -> GetInvitationDTO {
        .init(
            id: id,
            email: email,
            firstName: firstName,
            lastName: lastName,
            groupId: $group.id,
            expiresAt: expiresAt,
            acceptedAt: acceptedAt,
            createdById: $createdBy.id
        )
    }

    /// Not accepted, not expired, not revoked, and in an organization that still exists.
    static func pending(on db: any Database) -> QueryBuilder<OrganizationInvitation> {
        query(on: db)
            .join(Organization.self, on: \OrganizationInvitation.$organization.$id == \Organization.$id)
            .filter(Organization.self, \.$deletedAt == nil)
            .filter(\.$acceptedAt == nil)
            .filter(\.$expiresAt > Date())
    }

    static func query(on db: any Database, organizationID: UUID) -> QueryBuilder<OrganizationInvitation> {
        query(on: db).filter(\.$organization.$id == organizationID)
    }

    static func issue(
        organizationID: UUID,
        email: String,
        firstName: String,
        lastName: String,
        groupID: UUID?,
        createdByID: UUID?,
        id: UUID? = nil,
        token: String? = nil,
        approvalRequestID: UUID? = nil,
        on db: any Database
    ) async throws -> (OrganizationInvitation, String) {
        let token = token ?? InvitationToken.generate()
        let invitation = OrganizationInvitation(
            organizationID: organizationID,
            email: email,
            firstName: firstName,
            lastName: lastName,
            groupID: groupID,
            tokenHash: InvitationToken.hash(token),
            expiresAt: Date().addingTimeInterval(InvitationToken.lifetime),
            createdByID: createdByID,
            approvalRequestID: approvalRequestID
        )
        if let id {
            invitation.id = id
        }
        try await invitation.save(on: db)
        return (invitation, token)
    }
}