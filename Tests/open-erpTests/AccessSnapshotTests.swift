@testable import open_erp
import Foundation
import Testing

@Test func accessSnapshotSimulatesEachReduction() {
    let admin = UUID()
    let viewer = UUID()
    let unassigned = UUID()
    let adminGroup = UUID()
    let viewerGroup = UUID()
    let adminRole = UUID()
    let viewerRole = UUID()
    let original = AccessSnapshot(
        groupsByMember: [admin: [adminGroup, viewerGroup], viewer: [viewerGroup], unassigned: []],
        rolesByGroup: [adminGroup: [adminRole], viewerGroup: [viewerRole]],
        permissionsByRole: [adminRole: Set(Permission.allCases), viewerRole: [.companyRead]]
    )

    #expect(original.administrators == [admin])
    #expect(original.holders(of: .companyRead) == [admin, viewer])
    #expect(original.permissions(for: unassigned).isEmpty)

    var snapshot = original
    snapshot.removeMember(admin)
    #expect(snapshot.administrators.isEmpty)
    #expect(snapshot.holders(of: .companyRead) == [viewer])

    snapshot = original
    snapshot.removeGroupMember(admin, from: adminGroup)
    #expect(snapshot.administrators.isEmpty)
    #expect(snapshot.holders(of: .companyRead) == [admin, viewer])

    snapshot = original
    snapshot.removeGroupRole(adminRole, from: adminGroup)
    #expect(snapshot.administrators.isEmpty)
    #expect(snapshot.holders(of: .companyRead) == [admin, viewer])

    snapshot = original
    snapshot.replaceRolePermissions(adminRole, with: [.companyRead])
    #expect(snapshot.administrators.isEmpty)
    #expect(snapshot.holders(of: .companyRead) == [admin, viewer])
}
