import Vapor

struct PatchMeDTO: Content {
    var firstName: String?
    var lastName: String?
}

extension PatchMeDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("firstName", as: String.self, is: !.empty && .count(1...100), required: false, customFailureDescription: "First name must be 1-100 characters")
        validations.add("lastName", as: String.self, is: !.empty && .count(1...100), required: false, customFailureDescription: "Last name must be 1-100 characters")
    }
}

struct CreateInvitationDTO: Content {
    var email: String
    var firstName: String
    var lastName: String
    var roleId: UUID?
}

extension CreateInvitationDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: .email && .count(...254), customFailureDescription: "Email must be a valid email address")
        validations.add("firstName", as: String.self, is: !.empty && .count(1...100), customFailureDescription: "First name must be 1-100 characters")
        validations.add("lastName", as: String.self, is: !.empty && .count(1...100), customFailureDescription: "Last name must be 1-100 characters")
    }
}

struct GetInvitationDTO: Content {
    var id: UUID?
    var email: String
    var firstName: String
    var lastName: String
    var roleId: UUID?
    var expiresAt: Date
    var acceptedAt: Date?
    var createdById: UUID?
}

struct CreateInvitationResponse: Content {
    var invitation: GetInvitationDTO
    var token: String
}

struct AcceptInvitationDTO: Content {
    var token: String
}

extension AcceptInvitationDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("token", as: String.self, is: !.empty, customFailureDescription: "token is required")
    }
}

struct AcceptInvitationResponse: Content {
    var user: GetUserDTO
    var organizationId: UUID
}

struct CreateRoleDTO: Content {
    var name: String
    var level: String
    var permissions: [String]
}

extension CreateRoleDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty && .count(1...100), customFailureDescription: "Name must be 1-100 characters")
        validations.add("level", as: String.self, is: .in(RoleLevel.organization.rawValue, RoleLevel.company.rawValue), customFailureDescription: "level must be organization or company")
    }
}

struct PatchRoleDTO: Content {
    var name: String?
    var level: String?
    var permissions: [String]?
}

extension PatchRoleDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty && .count(1...100), required: false, customFailureDescription: "Name must be 1-100 characters")
        validations.add("level", as: String.self, is: .in(RoleLevel.organization.rawValue, RoleLevel.company.rawValue), required: false, customFailureDescription: "level must be organization or company")
    }
}

struct GetRoleDTO: Content {
    var id: UUID?
    var name: String
    var level: String
    var templateKey: String?
    var permissions: [String]
    var createdById: UUID?
    var updatedById: UUID?
    var deletedById: UUID?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?
}

struct CreateOrganizationRoleAssignmentDTO: Content {
    var userId: UUID
    var roleId: UUID
}

struct GetOrganizationRoleAssignmentDTO: Content {
    var id: UUID?
    var organizationUserId: UUID
    var userId: UUID
    var roleId: UUID
    var createdById: UUID?
    var createdAt: Date?
}

struct ProvisionOrganizationDTO: Content {
    var code: String
    var name: String
    var adminEmail: String
    var adminFirstName: String
    var adminLastName: String
}

extension ProvisionOrganizationDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("code", as: String.self, is: !.empty && .count(4...10) && .alphanumeric, customFailureDescription: "code must be 4-10 characters and alphanumeric")
        validations.add("name", as: String.self, is: !.empty && .count(3...255), customFailureDescription: "Name must be 3-255 characters")
        validations.add("adminEmail", as: String.self, is: .email && .count(...254), customFailureDescription: "Email must be a valid email address")
        validations.add("adminFirstName", as: String.self, is: !.empty && .count(1...100), customFailureDescription: "First name must be 1-100 characters")
        validations.add("adminLastName", as: String.self, is: !.empty && .count(1...100), customFailureDescription: "Last name must be 1-100 characters")
    }
}

struct ProvisionOrganizationResponse: Content {
    var organization: GetOrganizationDTO
    var invitationToken: String
}
