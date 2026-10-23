import Fluent
import Vapor

final class AccessGroup: Model, @unchecked Sendable {
    static let schema = "groups"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "organization_id")
    var organization: Organization

    @Field(key: "name")
    var name: String

    @OptionalField(key: "template_key")
    var templateKey: String?

    @Children(for: \.$group)
    var roles: [GroupRole]

    @Children(for: \.$group)
    var companies: [GroupCompany]

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "updated_by") var updatedBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(
        organizationID: UUID,
        name: String,
        templateKey: String? = nil,
        createdByID: UUID? = nil
    ) {
        self.$organization.id = organizationID
        self.name = name
        self.templateKey = templateKey
        self.$createdBy.id = createdByID
    }

    func toGetDTO() -> GetGroupDTO {
        .init(
            id: id,
            name: name,
            templateKey: templateKey,
            roleIds: roles.map { $0.$role.id }.sorted { $0.uuidString < $1.uuidString },
            companyIds: companies.map { $0.$company.id }.sorted { $0.uuidString < $1.uuidString },
            createdById: $createdBy.id,
            updatedById: $updatedBy.id,
            deletedById: $deletedBy.id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    func loadAssignments(on db: any Database) async throws {
        try await $roles.load(on: db)
        try await $companies.load(on: db)
    }

    /// Active members and pending invitations keep the group's history addressable, so it cannot be deleted.
    /// A group membership whose organization membership is already gone does not count.
    func isInUse(on db: any Database) async throws -> Bool {
        let groupID = try requireID()
        let activeMember = try await GroupMember.query(on: db)
            .join(OrganizationUser.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
            .filter(\.$group.$id == groupID)
            .filter(OrganizationUser.self, \.$deletedAt == nil)
            .first()
        if activeMember != nil {
            return true
        }
        return try await OrganizationInvitation.pending(on: db).filter(\.$group.$id == groupID).first() != nil
    }

    static func query(on db: any Database, organizationID: UUID) -> QueryBuilder<AccessGroup> {
        query(on: db).filter(\.$organization.$id == organizationID)
    }

    /// Copies group templates onto the roles just copied for this organization. `template_key` is reporting only.
    @discardableResult
    static func copyTemplates(
        into organizationID: UUID,
        roles: [Role],
        createdByID: UUID,
        on db: any Database
    ) async throws -> [AccessGroup] {
        var rolesByKey: [String: Role] = [:]
        for role in roles {
            if let key = role.templateKey {
                rolesByKey[key] = role
            }
        }
        var created: [AccessGroup] = []
        for template in GroupTemplate.all {
            let group = Self(
                organizationID: organizationID,
                name: template.name,
                templateKey: template.key,
                createdByID: createdByID
            )
            try await group.save(on: db)
            for roleKey in template.roleKeys {
                guard let role = rolesByKey[roleKey] else {
                    throw Abort(.internalServerError, reason: "Role template \(roleKey) was not copied")
                }
                try await GroupRole(
                    groupID: try group.requireID(),
                    roleID: try role.requireID(),
                    createdByID: createdByID
                ).save(on: db)
            }
            created.append(group)
        }
        return created
    }
}

final class GroupMember: Model, @unchecked Sendable {
    static let schema = "group_members"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "group_id")
    var group: AccessGroup

    @Parent(key: "organization_user_id")
    var organizationUser: OrganizationUser

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(groupID: UUID, organizationUserID: UUID, createdByID: UUID? = nil) {
        self.$group.id = groupID
        self.$organizationUser.id = organizationUserID
        self.$createdBy.id = createdByID
    }

    func toGetDTO(userID: UUID) -> GetGroupMemberDTO {
        .init(
            id: id,
            userId: userID,
            organizationUserId: $organizationUser.id,
            createdById: $createdBy.id,
            createdAt: createdAt
        )
    }
}

final class GroupRole: Model, @unchecked Sendable {
    static let schema = "group_roles"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "group_id")
    var group: AccessGroup

    @Parent(key: "role_id")
    var role: Role

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(groupID: UUID, roleID: UUID, createdByID: UUID? = nil) {
        self.$group.id = groupID
        self.$role.id = roleID
        self.$createdBy.id = createdByID
    }

    func toGetDTO() -> GetGroupRoleDTO {
        .init(
            id: id,
            groupId: $group.id,
            roleId: $role.id,
            createdById: $createdBy.id,
            createdAt: createdAt
        )
    }
}

final class GroupCompany: Model, @unchecked Sendable {
    static let schema = "group_companies"

    @ID(custom: .id, generatedBy: .database)
    var id: UUID?

    @Parent(key: "group_id")
    var group: AccessGroup

    @Parent(key: "company_id")
    var company: Company

    @OptionalParent(key: "created_by") var createdBy: User?
    @OptionalParent(key: "deleted_by") var deletedBy: User?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(groupID: UUID, companyID: UUID, createdByID: UUID? = nil) {
        self.$group.id = groupID
        self.$company.id = companyID
        self.$createdBy.id = createdByID
    }

    func toGetDTO() -> GetGroupCompanyDTO {
        .init(
            id: id,
            groupId: $group.id,
            companyId: $company.id,
            createdById: $createdBy.id,
            createdAt: createdAt
        )
    }
}
