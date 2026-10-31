import Fluent
import Vapor

struct PlatformOrganizationDTO: Content {
    var id: UUID
    var code: String
    var name: String
    var createdById: UUID?
    var updatedById: UUID?
    var createdAt: Date?
    var updatedAt: Date?
    var onboardedAt: Date?

    init(_ organization: Organization) throws {
        id = try organization.requireID()
        code = organization.code
        name = organization.name
        createdById = organization.$createdBy.id
        updatedById = organization.$updatedBy.id
        createdAt = organization.createdAt
        updatedAt = organization.updatedAt
        onboardedAt = organization.onboardedAt
    }
}

struct PlatformOnboardingInvitationDTO: Content {
    var id: UUID
    var email: String
    var firstName: String
    var lastName: String
    var groupId: UUID?
    var expiresAt: Date
    var acceptedAt: Date?
    var revokedAt: Date?
    var createdById: UUID?

    init(_ invitation: OrganizationInvitation) throws {
        id = try invitation.requireID()
        email = invitation.email
        firstName = invitation.firstName
        lastName = invitation.lastName
        groupId = invitation.$group.id
        expiresAt = invitation.expiresAt
        acceptedAt = invitation.acceptedAt
        revokedAt = invitation.deletedAt
        createdById = invitation.$createdBy.id
    }
}

enum PlatformOnboardingIssue: String, Codable {
    case acceptedWithoutCompletion = "accepted_without_completion"
    case missingOnboardingInvitation = "missing_onboarding_invitation"
    case originalGroupUnavailable = "original_group_unavailable"
}

struct PlatformOrganizationDetailDTO: Content {
    var organization: PlatformOrganizationDTO
    var onboardingInvitation: PlatformOnboardingInvitationDTO?
    var onboardingIssue: PlatformOnboardingIssue?
}
