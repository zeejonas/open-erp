import Fluent
import Vapor

struct AccessSnapshot {
    var groupsByMember: [UUID: Set<UUID>]
    var rolesByGroup: [UUID: Set<UUID>]
    var permissionsByRole: [UUID: Set<Permission>]
    /// Service accounts hold permissions like members but never count as administrators.
    var serviceAccounts: Set<UUID> = []

    static func load(organizationID: UUID, on db: any Database) async throws -> Self {
        let members = try await OrganizationUser.query(on: db, organizationID: organizationID).all()
        let groups = try await AccessGroup.query(on: db, organizationID: organizationID).all()
        let roles = try await Role.query(on: db, organizationID: organizationID)
            .filter(\.$level == RoleLevel.organization.rawValue).all()
        let groupIDs = try groups.map { try $0.requireID() }
        let roleIDs = try roles.map { try $0.requireID() }
        let usersByMembership = try Dictionary(uniqueKeysWithValues: members.map {
            (try $0.requireID(), $0.$user.id)
        })

        var snapshot = Self(
            groupsByMember: Dictionary(uniqueKeysWithValues: usersByMembership.values.map { ($0, []) }),
            rolesByGroup: [:],
            permissionsByRole: [:]
        )
        let memberships = try await GroupMember.query(on: db)
            .filter(\.$group.$id ~~ groupIDs)
            .filter(\.$organizationUser.$id ~~ Array(usersByMembership.keys)).all()
        for link in memberships {
            if let userID = usersByMembership[link.$organizationUser.id] {
                snapshot.groupsByMember[userID, default: []].insert(link.$group.id)
            }
        }
        let attachments = try await GroupRole.query(on: db)
            .filter(\.$group.$id ~~ groupIDs).filter(\.$role.$id ~~ roleIDs).all()
        for link in attachments {
            snapshot.rolesByGroup[link.$group.id, default: []].insert(link.$role.id)
        }
        snapshot.serviceAccounts = Set(try await ServiceAccount.query(on: db, organizationID: organizationID).all().map { try $0.requireID() })
        let grants = try await RolePermission.query(on: db).filter(\.$role.$id ~~ roleIDs).all()
        for grant in grants {
            if let permission = Permission(rawValue: grant.permission), permission.level == .organization {
                snapshot.permissionsByRole[grant.$role.id, default: []].insert(permission)
            }
        }
        return snapshot
    }

    func permissions(for memberID: UUID) -> Set<Permission> {
        var permissions: Set<Permission> = []
        for groupID in groupsByMember[memberID] ?? [] {
            for roleID in rolesByGroup[groupID] ?? [] {
                permissions.formUnion(permissionsByRole[roleID] ?? [])
            }
        }
        return permissions
    }

    func holders(of permission: Permission) -> Set<UUID> {
        Set(groupsByMember.keys.filter { permissions(for: $0).contains(permission) })
    }

    var administrators: Set<UUID> {
        let required = Set(Permission.allCases.filter { $0.level == .organization })
        return Set(groupsByMember.keys.filter { !serviceAccounts.contains($0) && permissions(for: $0).isSuperset(of: required) })
    }

    mutating func removeMember(_ memberID: UUID) {
        groupsByMember.removeValue(forKey: memberID)
    }

    mutating func removeGroupMember(_ memberID: UUID, from groupID: UUID) {
        groupsByMember[memberID]?.remove(groupID)
    }

    mutating func removeGroupRole(_ roleID: UUID, from groupID: UUID) {
        rolesByGroup[groupID]?.remove(roleID)
    }

    mutating func replaceRolePermissions(_ roleID: UUID, with permissions: Set<Permission>) {
        permissionsByRole[roleID] = permissions.filter { $0.level == .organization }
    }
}
