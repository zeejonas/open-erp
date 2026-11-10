import Fluent
import Vapor

/// The approval-gateable state of a service account. `subject` is the identity provider client's token `sub`.
struct ServiceAccountSnapshot: Content, Equatable {
    var name: String
    var description: String?
    var ownerId: UUID
    var subject: String
    var enabled: Bool

    func changedFields(from before: Self) -> Set<String> {
        var fields: Set<String> = []
        if name != before.name { fields.insert("name") }
        if description != before.description { fields.insert("description") }
        if ownerId != before.ownerId { fields.insert("ownerId") }
        if subject != before.subject { fields.insert("subject") }
        if enabled != before.enabled { fields.insert("enabled") }
        return fields
    }
}

struct CreateServiceAccountDTO: Content {
    var name: String
    var description: String?
    var ownerId: UUID?
    var subject: String
}

extension CreateServiceAccountDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        ServiceAccountValidation.add(to: &validations, required: true)
    }
}

/// An empty `description` clears it.
struct PatchServiceAccountDTO: Content {
    var name: String?
    var description: String?
    var ownerId: UUID?
    var subject: String?
    var enabled: Bool?

    func applying(to before: ServiceAccountSnapshot) -> ServiceAccountSnapshot {
        .init(
            name: name ?? before.name,
            description: description.map { $0.isEmpty ? nil : $0 } ?? before.description,
            ownerId: ownerId ?? before.ownerId,
            subject: subject ?? before.subject,
            enabled: enabled ?? before.enabled
        )
    }
}

extension PatchServiceAccountDTO: Validatable {
    static func validations(_ validations: inout Validations) {
        ServiceAccountValidation.add(to: &validations, required: false)
    }
}

private enum ServiceAccountValidation {
    static func add(to validations: inout Validations, required: Bool) {
        validations.add("name", as: String.self, is: .count(1...100), required: required, customFailureDescription: "Name must be 1-100 characters")
        validations.add("subject", as: String.self, is: .count(1...255), required: required, customFailureDescription: "subject must be 1-255 characters")
        validations.add("description", as: String.self, is: .count(...500), required: false, customFailureDescription: "description must be at most 500 characters")
    }
}

struct ServiceAccountDTO: Content {
    var id: UUID
    var name: String
    var description: String?
    var ownerId: UUID
    var subject: String
    var enabled: Bool
    var disabledAt: Date?
    var disabledById: UUID?
    var lastUsedAt: Date?
    var createdById: UUID?
    var updatedById: UUID?
    var createdAt: Date?
    var updatedAt: Date?

    init(_ account: ServiceAccount, user: User) throws {
        id = try account.requireID()
        name = user.firstName
        description = account.description
        ownerId = account.$owner.id
        subject = user.authSubject ?? ""
        enabled = account.disabledAt == nil
        disabledAt = account.disabledAt
        disabledById = account.$disabledBy.id
        lastUsedAt = account.lastUsedAt
        createdById = account.$createdBy.id
        updatedById = account.$updatedBy.id
        createdAt = account.createdAt
        updatedAt = account.updatedAt
    }
}
