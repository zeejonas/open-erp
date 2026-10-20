import Fluent
import Vapor

final class Organization: Model, @unchecked Sendable {
    static let schema = "organizations"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Field(key: "code")
    var code: String

    @Field(key: "name")
    var name: String

    @Children(for: \.$organization)
    var companies: [Company]

    @Siblings(through: OrganizationUser.self, from: \.$organization, to: \.$user)
    var users: [User]

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "updated_by") var updatedBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create, format: .iso8601) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update, format: .iso8601) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete, format: .iso8601) var deletedAt: Date?

    init () {}

    init(code: String, name: String, createdBy: User?, updatedBy: User?, deletedBy: User?) {
        self.code = code
        self.name = name
        self.$createdBy.id = createdBy?.id
        self.$updatedBy.id = updatedBy?.id
        self.$deletedBy.id = deletedBy?.id
    }

    func toCreateDTO() -> CreateOrganizationDTO {
        .init(code: self.code, name: self.name)
    }

    func toGetDTO() -> GetOrganizationDTO {
        .init(
            id: self.id,
            code: self.code,
            name: self.name,
            createdById: self.$createdBy.id,
            updatedById: self.$updatedBy.id,
            deletedById: self.$deletedBy.id,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt,
            deletedAt: self.deletedAt,
        )
    }
}

final class Company: Model, @unchecked Sendable {
    static let schema = "companies"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Field(key: "code")
    var code: String

    @Field(key: "name")
    var name: String

    @Parent(key: "organization_id")
    var organization: Organization

    @Siblings(through: CompanyUser.self, from: \.$company, to: \.$user)
    var users: [User]

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "updated_by") var updatedBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create, format: .iso8601) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update, format: .iso8601) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete, format: .iso8601) var deletedAt: Date?

    init() {}

    init(code: String, name: String, organizationID: UUID, createdBy: User?, updatedBy: User?, deletedBy: User?) {
        self.code = code
        self.name = name
        self.$organization.id = organizationID
        self.$createdBy.id = createdBy?.id
        self.$updatedBy.id = updatedBy?.id
        self.$deletedBy.id = deletedBy?.id
    }

    func toCreateDTO() -> CreateCompanyDTO {
        .init(
            code: self.code,
            name: self.name,
            organizationId: self.$organization.id
        )
    }

    func toGetDTO() -> GetCompanyDTO {
        .init(
            id: self.id,
            code: self.code,
            name: self.name,
            organizationId: self.$organization.id,
            createdById: self.$createdBy.id,
            updatedById: self.$updatedBy.id,
            deletedById: self.$deletedBy.id,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt,
            deletedAt: self.deletedAt,
        )
    }
}

final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Field(key: "first_name")
    var firstName: String

    @Field(key: "last_name")
    var lastName: String

    @Field(key: "email")
    var email: String

    @Siblings(through: OrganizationUser.self, from: \.$user, to: \.$organization)
    var organizations: [Organization]

    @Siblings(through: CompanyUser.self, from: \.$user, to: \.$company)
    var companies: [Company]

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "updated_by") var updatedBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create, format: .iso8601) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update, format: .iso8601) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete, format: .iso8601) var deletedAt: Date?

    init() {}

    init(firstName: String, lastName: String, email: String, createdBy: User?, updatedBy: User?, deletedBy: User?) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.$createdBy.id = createdBy?.id
        self.$updatedBy.id = updatedBy?.id
        self.$deletedBy.id = deletedBy?.id
    }

    func toCreateDTO() -> CreateUserDTO {
        .init(
            firstName: self.firstName,
            lastName: self.lastName,
            email: self.email
        )
    }

    func toGetDTO() -> GetUserDTO {
        .init(
            id: self.id,
            firstName: self.firstName,
            lastName: self.lastName,
            email: self.email,
            createdById: self.$createdBy.id,
            updatedById: self.$updatedBy.id,
            deletedById: self.$deletedBy.id,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt,
            deletedAt: self.deletedAt,
        )
    }
}

final class OrganizationUser: Model, @unchecked Sendable {
    static let schema = "organization_users"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?
    
    @Parent(key: "organization_id")
    var organization: Organization

    @Parent(key: "user_id")
    var user: User

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create, format: .iso8601) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete, format: .iso8601) var deletedAt: Date?

    init() {}

    init(organizationID: UUID, userID: UUID, createdByID: UUID? = nil, deletedByID: UUID? = nil) {
        self.$organization.id = organizationID
        self.$user.id = userID
        self.$createdBy.id = createdByID
        self.$deletedBy.id = deletedByID
    }
}

final class CompanyUser: Model, @unchecked Sendable {
    static let schema = "company_users"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "company_id")
    var company: Company

    @Parent(key: "user_id")
    var user: User

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create, format: .iso8601) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete, format: .iso8601) var deletedAt: Date?

    init() {}

    init(companyID: UUID, userID: UUID, createdByID: UUID? = nil, deletedByID: UUID? = nil) {
        self.$company.id = companyID
        self.$user.id = userID
        self.$createdBy.id = createdByID
        self.$deletedBy.id = deletedByID
    }
}