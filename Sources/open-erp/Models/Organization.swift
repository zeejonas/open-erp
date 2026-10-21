import Fluent
import FluentSQL
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

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

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

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

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
            name: self.name
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

    static func query(on db: any Database, organizationID: UUID) -> QueryBuilder<Company> {
        query(on: db).filter(\.$organization.$id == organizationID)
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

    @OptionalField(key: "auth_subject")
    var authSubject: String?

    @Field(key: "is_platform_admin")
    var isPlatformAdmin: Bool

    @Siblings(through: OrganizationUser.self, from: \.$user, to: \.$organization)
    var organizations: [Organization]

    @Siblings(through: CompanyUser.self, from: \.$user, to: \.$company)
    var companies: [Company]

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "updated_by") var updatedBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(
        firstName: String,
        lastName: String,
        email: String,
        authSubject: String? = nil,
        isPlatformAdmin: Bool = false,
        createdBy: User? = nil,
        updatedBy: User? = nil,
        deletedBy: User? = nil
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.authSubject = authSubject
        self.isPlatformAdmin = isPlatformAdmin
        self.$createdBy.id = createdBy?.id
        self.$updatedBy.id = updatedBy?.id
        self.$deletedBy.id = deletedBy?.id
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

    static func query(on db: any Database, organizationID: UUID) -> QueryBuilder<User> {
        query(on: db)
            .join(OrganizationUser.self, on: \User.$id == \OrganizationUser.$user.$id)
            .filter(OrganizationUser.self, \.$organization.$id == organizationID)
            .filter(OrganizationUser.self, \.$deletedAt == nil)
    }

    static func find(email: String, on db: any Database) async throws -> User? {
        try await User.query(on: db)
            .filter(.sql(embed: "LOWER(\(ident: "email")) = \(bind: email.lowercased())"))
            .first()
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

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(organizationID: UUID, userID: UUID, createdByID: UUID? = nil, deletedByID: UUID? = nil) {
        self.$organization.id = organizationID
        self.$user.id = userID
        self.$createdBy.id = createdByID
        self.$deletedBy.id = deletedByID
    }

    static func query(on db: any Database, organizationID: UUID) -> QueryBuilder<OrganizationUser> {
        query(on: db).filter(\.$organization.$id == organizationID)
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

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(companyID: UUID, userID: UUID, createdByID: UUID? = nil, deletedByID: UUID? = nil) {
        self.$company.id = companyID
        self.$user.id = userID
        self.$createdBy.id = createdByID
        self.$deletedBy.id = deletedByID
    }
}