import Fluent
import Vapor

// MARK: - Organization DTOs
struct CreateOrganizationDTO: Content {
    var code: String
    var name: String
    
}
// Use validations so we can avoid trying to process a request with invalid data
// https://docs.vapor.codes/basics/validation/
// Vapor’s Validation API helps you validate the body and query parameters of an incoming request before using the Content API to decode data.
extension CreateOrganizationDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("code", as: String.self, is: !.empty, customFailureDescription: "code must be 4-10 characters and alphanumeric")
        validations.add("code", as: String.self, is: .count(4...10) && .alphanumeric, customFailureDescription: "code must be 4-10 characters and alphanumeric")

        validations.add("name", as: String.self, is: !.empty, customFailureDescription: "Name must be 3-255 characters")
        validations.add("name", as: String.self, is: .count(3...255), customFailureDescription: "Name must be 3-255 characters")
    }
}

struct GetOrganizationDTO: Content {
    var id: UUID?
    var code: String
    var name: String
    var createdById: UUID?
    var updatedById: UUID?
    var deletedById: UUID?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?
}

struct PatchOrganizationDTO: Content {
    var code: String?
    var name: String?
}

extension PatchOrganizationDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("code", as: String.self, is: !.empty, required: false, customFailureDescription: "code must be 4-10 characters and alphanumeric")
        validations.add("code", as: String.self, is: .count(4...10) && .alphanumeric, required: false, customFailureDescription: "code must be 4-10 characters and alphanumeric")

        validations.add("name", as: String.self, is: !.empty, required: false, customFailureDescription: "Name must be 3-255 characters")
        validations.add("name", as: String.self, is: .count(3...255), required: false, customFailureDescription: "Name must be 3-255 characters")
    }
}

// MARK: - Company DTOs

struct CreateCompanyDTO: Content {
    var code: String
    var name: String
}

extension CreateCompanyDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("code", as: String.self, is: !.empty && .count(4...10) && .alphanumeric, customFailureDescription: "code must be 4-10 characters and alphanumeric")
        validations.add("name", as: String.self, is: !.empty && .count(3...255), customFailureDescription: "Name must be 3-255 characters")
    }
}

struct GetCompanyDTO: Content {
    var id: UUID?
    var code: String
    var name: String
    var organizationId: UUID
    var createdById: UUID?
    var updatedById: UUID?
    var deletedById: UUID?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?
}

struct PatchCompanyDTO: Content {
    var code: String?
    var name: String?
}

extension PatchCompanyDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("code", as: String.self, is: !.empty && .count(4...10) && .alphanumeric, required: false, customFailureDescription: "code must be 4-10 characters and alphanumeric")
        validations.add("name", as: String.self, is: !.empty && .count(3...255), required: false, customFailureDescription: "Name must be 3-255 characters")
    }
}

// MARK: - User DTOs
struct CreateUserDTO: Content {
    var firstName: String
    var lastName: String
    var email: String
}

extension CreateUserDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("firstName", as: String.self, is: !.empty && .count(1...100), customFailureDescription: "First name must be 1-100 characters")
        validations.add("lastName", as: String.self, is: !.empty && .count(1...100), customFailureDescription: "Last name must be 1-100 characters")
        validations.add("email", as: String.self, is: .email && .count(...254), customFailureDescription: "Email must be a valid email address")
    }
}

struct GetUserDTO: Content {
    var id: UUID?
    var firstName: String
    var lastName: String
    var email: String
    var createdById: UUID?
    var updatedById: UUID?
    var deletedById: UUID?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?
}

struct PatchUserDTO: Content {
    var firstName: String?
    var lastName: String?
    var email: String?
}

extension PatchUserDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("firstName", as: String.self, is: !.empty && .count(1...100), required: false, customFailureDescription: "First name must be 1-100 characters")
        validations.add("lastName", as: String.self, is: !.empty && .count(1...100), required: false, customFailureDescription: "Last name must be 1-100 characters")
        validations.add("email", as: String.self, is: .email && .count(...254), required: false, customFailureDescription: "Email must be a valid email address")
    }
}

// MARK: - OrganizationUser DTOs

struct CreateOrganizationUserDTO: Content {
    var userId: UUID
}

extension CreateOrganizationUserDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("userId", as: UUID.self, customFailureDescription: "userId must be a UUID")
    }
}
