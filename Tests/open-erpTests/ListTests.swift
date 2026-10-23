@testable import open_erp
import Fluent
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("GET /roles pages with a fixed order and rejects bad parameters")
    func roleListContract() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            _ = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "reader@example.com",
                subject: "reader",
                permissions: [.roleRead]
            )
            let token = try await signAccessToken(on: app, subject: "reader")
            _ = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "denied@example.com",
                subject: "denied",
                permissions: []
            )
            let deniedToken = try await signAccessToken(on: app, subject: "denied")

            let rejected = [
                ("per=101", "per"),
                ("page=0", "page"),
                ("page=abc", "page"),
                ("pageSize=50", "pageSize"),
                ("name=AP&name=AR", "name"),
                ("name=", "name"),
                ("level=global", "level"),
                ("sort=name", "sort"),
            ]
            for (query, parameter) in rejected {
                try await authorizedGet(app, "roles", query: query, token: token, organizationID: orgID) { res in
                    try expectBadRequest(res, naming: parameter)
                }
            }

            try await authorizedGet(app, "roles", query: "page=1", token: deniedToken, organizationID: orgID) { res in
                #expect(res.status == .forbidden)
            }

            let reader = try #require(try await User.find(email: "reader@example.com", on: app.db))
            let readerID = try reader.requireID()
            for number in 1...29 {
                try await Role(
                    organizationID: orgID,
                    name: String(format: "Role %02d", number),
                    level: .organization,
                    createdByID: readerID
                ).save(on: app.db)
            }

            let all = try await listRoles(app, token: token, organizationID: orgID, query: "per=100")
            #expect(all.metadata.total == 30)
            #expect(all.items.count == 30)
            let ordered = all.items.map(\.id)

            let first = try await listRoles(app, token: token, organizationID: orgID)
            #expect(first.metadata.page == 1)
            #expect(first.metadata.per == 25)
            #expect(first.metadata.total == 30)
            #expect(first.items.map(\.id) == Array(ordered.prefix(25)))

            let second = try await listRoles(app, token: token, organizationID: orgID, query: "page=2&per=10")
            #expect(second.metadata.page == 2)
            #expect(second.metadata.per == 10)
            #expect(second.metadata.total == 30)
            #expect(second.items.map(\.id) == Array(ordered[10..<20]))

            let past = try await listRoles(app, token: token, organizationID: orgID, query: "page=99")
            #expect(past.items.isEmpty)
            #expect(past.metadata.total == 30)
            #expect(past.metadata.page == 99)

            var paged: [UUID?] = []
            for number in 1...30 {
                let page = try await listRoles(app, token: token, organizationID: orgID, query: "page=\(number)&per=1")
                #expect(page.items.count == 1)
                paged.append(page.items[0].id)
            }
            #expect(paged == ordered)
        }
    }

    @Test("Company lists filter, keep a renamed company first, and count only the caller's organization")
    func companyLists() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()
            _ = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "ada@example.com",
                subject: "ada",
                permissions: Permission.allCases
            )
            let token = try await signAccessToken(on: app, subject: "ada")

            let acme = try await saveCompany(on: app.db, organizationID: orgAID, code: "EAST", name: "Acme Corp")
            let globex = try await saveCompany(on: app.db, organizationID: orgAID, code: "WEST", name: "Globex")
            _ = try await saveCompany(on: app.db, organizationID: orgAID, code: "UNDR", name: "A_B")
            _ = try await saveCompany(on: app.db, organizationID: orgAID, code: "WILD", name: "AXB")
            let acmeID = try acme.requireID()
            let globexID = try globex.requireID()

            let byName = try await listCompanies(app, token: token, organizationID: orgAID, query: "name=acme")
            #expect(byName.metadata.total == 1)
            #expect(byName.items.map(\.name) == ["Acme Corp"])

            let byCode = try await listCompanies(app, token: token, organizationID: orgAID, query: "code=east")
            #expect(byCode.items.map(\.code) == ["EAST"])

            let literal = try await listCompanies(app, token: token, organizationID: orgAID, query: "name=A_B")
            #expect(literal.items.map(\.name) == ["A_B"])

            try await app.testing().test(.PATCH, "companies/\(acmeID)", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgAID)
                try req.content.encode(PatchCompanyDTO(code: nil, name: "Acme Renamed"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            let ordered = try await listCompanies(app, token: token, organizationID: orgAID, query: "per=10")
            #expect(ordered.items.first?.id == acmeID)
            #expect(ordered.items.map(\.id).contains(globexID))

            for number in 1...5 {
                _ = try await saveCompany(on: app.db, organizationID: orgBID, code: "B\(number)", name: "Org B \(number)")
            }
            let scoped = try await listCompanies(app, token: token, organizationID: orgAID)
            #expect(scoped.metadata.total == 4)
            #expect(scoped.items.allSatisfy { $0.organizationId == orgAID })
        }
    }

    @Test("Role lists filter by level and name")
    func roleListFilters() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            let admin = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "admin@example.com",
                subject: "admin",
                permissions: [.roleRead]
            )
            try await Role(
                organizationID: orgID,
                name: "Accounts Payable",
                level: .organization,
                createdByID: try admin.requireID()
            ).save(on: app.db)
            try await Role(
                organizationID: orgID,
                name: "Plant Clerk",
                level: .company,
                createdByID: try admin.requireID()
            ).save(on: app.db)
            let token = try await signAccessToken(on: app, subject: "admin")

            let byLevel = try await listRoles(app, token: token, organizationID: orgID, query: "level=company")
            #expect(byLevel.items.map(\.name) == ["Plant Clerk"])
            #expect(byLevel.metadata.total == 1)

            let byName = try await listRoles(app, token: token, organizationID: orgID, query: "name=plant")
            #expect(byName.items.map(\.name) == ["Plant Clerk"])
        }
    }

    @Test("User lists combine filters and skip removed members and deleted groups")
    func userListFilters() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            let admin = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "admin@example.com",
                subject: "admin",
                permissions: Permission.allCases
            )
            let ann = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "ann@example.com",
                subject: "ann",
                permissions: [],
                firstName: "Ann",
                lastName: "Smith"
            )
            let bea = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "bea@example.com",
                subject: "bea",
                permissions: [],
                firstName: "Bea",
                lastName: "Smith"
            )
            let cal = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "cal@example.com",
                subject: "cal",
                permissions: [],
                firstName: "Cal",
                lastName: "Jones"
            )
            let adminID = try admin.requireID()
            let annID = try ann.requireID()
            let beaID = try bea.requireID()
            let calID = try cal.requireID()
            let token = try await signAccessToken(on: app, subject: "admin")

            let clerks = AccessGroup(organizationID: orgID, name: "AP Clerks", createdByID: adminID)
            try await clerks.save(on: app.db)
            let clerksID = try clerks.requireID()
            for userID in [annID, calID] {
                let membership = try await OrganizationUser.query(on: app.db, organizationID: orgID)
                    .filter(\.$user.$id == userID)
                    .first()
                try await GroupMember(
                    groupID: clerksID,
                    organizationUserID: try membership!.requireID(),
                    createdByID: adminID
                ).save(on: app.db)
            }

            let combined = try await listUsers(
                app,
                token: token,
                organizationID: orgID,
                query: "lastName=smith&groupId=\(clerksID)"
            )
            #expect(combined.items.map(\.email) == ["ann@example.com"])
            #expect(combined.metadata.total == 1)

            let byFirst = try await listUsers(app, token: token, organizationID: orgID, query: "firstName=cal")
            #expect(byFirst.items.map(\.email) == ["cal@example.com"])

            let byEmail = try await listUsers(app, token: token, organizationID: orgID, query: "email=BEA@")
            #expect(byEmail.items.map(\.email) == ["bea@example.com"])

            try await app.testing().test(.DELETE, "groups/\(clerksID)/members/\(annID)", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            let afterRemoval = try await listUsers(app, token: token, organizationID: orgID, query: "groupId=\(clerksID)")
            #expect(afterRemoval.items.compactMap(\.id) == [calID])

            let temps = AccessGroup(organizationID: orgID, name: "Temps", createdByID: adminID)
            try await temps.save(on: app.db)
            let tempsID = try temps.requireID()
            let beaMembership = try await OrganizationUser.query(on: app.db, organizationID: orgID)
                .filter(\.$user.$id == beaID)
                .first()
            try await GroupMember(
                groupID: tempsID,
                organizationUserID: try beaMembership!.requireID(),
                createdByID: adminID
            ).save(on: app.db)
            try await temps.delete(on: app.db)
            let deletedGroup = try await listUsers(app, token: token, organizationID: orgID, query: "groupId=\(tempsID)")
            #expect(deletedGroup.items.isEmpty)
            #expect(deletedGroup.metadata.total == 0)
        }
    }

    @Test("Group lists answer access reviews and ignore detached or foreign roles")
    func groupListFilters() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()
            let admin = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "admin@example.com",
                subject: "admin",
                permissions: Permission.allCases
            )
            let token = try await signAccessToken(on: app, subject: "admin")
            let actorID = try admin.requireID()

            let clerks = AccessGroup(organizationID: orgAID, name: "AP Clerks", createdByID: actorID)
            let viewers = AccessGroup(organizationID: orgAID, name: "Viewers", createdByID: actorID)
            try await clerks.save(on: app.db)
            try await viewers.save(on: app.db)
            let clerksID = try clerks.requireID()
            let role = Role(organizationID: orgAID, name: "Organization Viewer", level: .organization, createdByID: actorID)
            try await role.save(on: app.db)
            let roleID = try role.requireID()
            let company = try await saveCompany(on: app.db, organizationID: orgAID, code: "EAST", name: "Acme East")
            let companyID = try company.requireID()
            try await GroupRole(groupID: clerksID, roleID: roleID, createdByID: actorID).save(on: app.db)
            try await GroupCompany(groupID: clerksID, companyID: companyID, createdByID: actorID).save(on: app.db)

            let byName = try await listGroups(app, token: token, organizationID: orgAID, query: "name=viewers")
            #expect(byName.items.map(\.name) == ["Viewers"])

            let byCompany = try await listGroups(app, token: token, organizationID: orgAID, query: "companyId=\(companyID)")
            #expect(byCompany.items.compactMap(\.id) == [clerksID])
            #expect(byCompany.items.first?.companyIds == [companyID])
            #expect(byCompany.items.first?.roleIds == [roleID])

            try await app.testing().test(.DELETE, "groups/\(clerksID)/roles/\(roleID)", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            let detached = try await listGroups(app, token: token, organizationID: orgAID, query: "roleId=\(roleID)")
            #expect(detached.items.isEmpty)
            #expect(detached.metadata.total == 0)

            let foreign = Role(organizationID: orgBID, name: "Foreign", level: .organization, createdByID: nil)
            try await foreign.save(on: app.db)
            let foreignID = try foreign.requireID()
            let otherOrg = try await listGroups(app, token: token, organizationID: orgAID, query: "roleId=\(foreignID)")
            #expect(otherOrg.items.isEmpty)
            #expect(otherOrg.metadata.total == 0)

            try await authorizedGet(app, "groups", query: "roleId=abc", token: token, organizationID: orgAID) { res in
                try expectBadRequest(res, naming: "roleId")
            }
        }
    }

    @Test("Group members are newest by membership creation")
    func groupMemberListOrder() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            _ = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "admin@example.com",
                subject: "admin",
                permissions: Permission.allCases
            )
            let ann = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "ann@example.com",
                subject: "ann",
                permissions: [],
                firstName: "Ann",
                lastName: "A"
            )
            let bea = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "bea@example.com",
                subject: "bea",
                permissions: [],
                firstName: "Bea",
                lastName: "B"
            )
            let token = try await signAccessToken(on: app, subject: "admin")
            let annID = try ann.requireID()
            let beaID = try bea.requireID()

            var groupID: UUID?
            try await app.testing().test(.POST, "groups", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgID)
                try req.content.encode(CreateGroupDTO(name: "AP Clerks"))
            }, afterResponse: { res async throws in
                groupID = try res.content.decode(GetGroupDTO.self).id
            })
            let group = try #require(groupID)

            var firstMember: UUID?
            var secondMember: UUID?
            for (userID, slot) in [(annID, true), (beaID, false)] {
                try await app.testing().test(.POST, "groups/\(group)/members", beforeRequest: { req in
                    authorize(&req, token: token, organizationID: orgID)
                    try req.content.encode(AddGroupMemberDTO(userId: userID))
                }, afterResponse: { res async throws in
                    let memberID = try res.content.decode(GetGroupMemberDTO.self).id
                    if slot {
                        firstMember = memberID
                    } else {
                        secondMember = memberID
                    }
                })
            }

            let page = try await listMembers(app, token: token, organizationID: orgID, groupID: group)
            let stored = try await GroupMember.query(on: app.db).filter(\.$group.$id == group).all()
            let older = try #require(stored.first { $0.id == firstMember })
            let newer = try #require(stored.first { $0.id == secondMember })
            #expect(newer.createdAt! > older.createdAt!)
            #expect(page.items.map(\.id) == [secondMember, firstMember])
            #expect(page.metadata.total == 2)
        }
    }

    @Test("Invitation lists filter pending rows and order them by creation")
    func invitationListFilters() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            let admin = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "admin@example.com",
                subject: "admin",
                permissions: [.organizationInvitationCreate, .organizationInvitationRead, .groupCreate]
            )
            let token = try await signAccessToken(on: app, subject: "admin")
            let viewers = AccessGroup(organizationID: orgID, name: "Viewers", createdByID: try admin.requireID())
            try await viewers.save(on: app.db)
            let viewersID = try viewers.requireID()

            var beaID: UUID?
            var calID: UUID?
            try await app.testing().test(.POST, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgID)
                try req.content.encode(CreateInvitationDTO(
                    email: "bea@acme.com",
                    firstName: "Bea",
                    lastName: "Acme",
                    groupId: viewersID
                ))
            }, afterResponse: { res async throws in
                beaID = try res.content.decode(CreateInvitationResponse.self).invitation.id
            })
            try await app.testing().test(.POST, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: token, organizationID: orgID)
                try req.content.encode(CreateInvitationDTO(
                    email: "cal@acme.com",
                    firstName: "Cal",
                    lastName: "Acme",
                    groupId: nil
                ))
            }, afterResponse: { res async throws in
                calID = try res.content.decode(CreateInvitationResponse.self).invitation.id
            })

            let byEmail = try await listInvitations(app, token: token, organizationID: orgID, query: "email=BEA")
            #expect(byEmail.items.map(\.email) == ["bea@acme.com"])
            #expect(byEmail.metadata.total == 1)

            let byGroup = try await listInvitations(app, token: token, organizationID: orgID, query: "groupId=\(viewersID)")
            #expect(byGroup.items.map(\.id) == [beaID])

            let listed = try await listInvitations(app, token: token, organizationID: orgID)
            let stored = try await OrganizationInvitation.query(on: app.db)
                .filter(\.$organization.$id == orgID)
                .all()
            let bea = try #require(stored.first { $0.id == beaID })
            let cal = try #require(stored.first { $0.id == calID })
            #expect(cal.createdAt! > bea.createdAt!)
            #expect(listed.items.map(\.id) == [calID, beaID])
        }
    }

    @Test("My organizations are newest by the organization's update")
    func myOrganizationsOrder() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()
            let user = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "ada@example.com",
                subject: "ada",
                permissions: []
            )
            try await OrganizationUser(organizationID: orgBID, userID: try user.requireID()).save(on: app.db)
            orgA.name = "Org A renamed"
            try await orgA.update(on: app.db)
            let token = try await signAccessToken(on: app, subject: "ada")

            var ordered: [UUID?] = []
            try await authorizedGet(app, "me/organizations", token: token) { res in
                #expect(res.status == .ok)
                let page = try res.content.decode(Page<GetOrganizationDTO>.self)
                #expect(page.metadata.total == 2)
                ordered = page.items.map(\.id)
            }
            #expect(ordered.compactMap { $0 } == [orgAID, orgBID])
        }
    }
}

@discardableResult
private func saveCompany(
    on db: any Database,
    organizationID: UUID,
    code: String,
    name: String
) async throws -> Company {
    let company = Company(
        code: code,
        name: name,
        organizationID: organizationID,
        createdBy: nil,
        updatedBy: nil,
        deletedBy: nil
    )
    try await company.save(on: db)
    return company
}

private func listRoles(
    _ app: Application,
    token: String,
    organizationID: UUID,
    query: String? = nil
) async throws -> Page<GetRoleDTO> {
    var page: Page<GetRoleDTO>?
    try await authorizedGet(app, "roles", query: query, token: token, organizationID: organizationID) { res in
        #expect(res.status == .ok)
        page = try res.content.decode(Page<GetRoleDTO>.self)
    }
    return try #require(page)
}

private func listCompanies(
    _ app: Application,
    token: String,
    organizationID: UUID,
    query: String? = nil
) async throws -> Page<GetCompanyDTO> {
    var page: Page<GetCompanyDTO>?
    try await authorizedGet(app, "companies", query: query, token: token, organizationID: organizationID) { res in
        #expect(res.status == .ok)
        page = try res.content.decode(Page<GetCompanyDTO>.self)
    }
    return try #require(page)
}

private func listUsers(
    _ app: Application,
    token: String,
    organizationID: UUID,
    query: String? = nil
) async throws -> Page<GetUserDTO> {
    var page: Page<GetUserDTO>?
    try await authorizedGet(app, "users", query: query, token: token, organizationID: organizationID) { res in
        #expect(res.status == .ok)
        page = try res.content.decode(Page<GetUserDTO>.self)
    }
    return try #require(page)
}

private func listGroups(
    _ app: Application,
    token: String,
    organizationID: UUID,
    query: String? = nil
) async throws -> Page<GetGroupDTO> {
    var page: Page<GetGroupDTO>?
    try await authorizedGet(app, "groups", query: query, token: token, organizationID: organizationID) { res in
        #expect(res.status == .ok)
        page = try res.content.decode(Page<GetGroupDTO>.self)
    }
    return try #require(page)
}

private func listMembers(
    _ app: Application,
    token: String,
    organizationID: UUID,
    groupID: UUID
) async throws -> Page<GetGroupMemberDTO> {
    var page: Page<GetGroupMemberDTO>?
    try await authorizedGet(app, "groups/\(groupID)/members", token: token, organizationID: organizationID) { res in
        #expect(res.status == .ok)
        page = try res.content.decode(Page<GetGroupMemberDTO>.self)
    }
    return try #require(page)
}

private func listInvitations(
    _ app: Application,
    token: String,
    organizationID: UUID,
    query: String? = nil
) async throws -> Page<GetInvitationDTO> {
    var page: Page<GetInvitationDTO>?
    try await authorizedGet(app, "organization-invitations", query: query, token: token, organizationID: organizationID) { res in
        #expect(res.status == .ok)
        page = try res.content.decode(Page<GetInvitationDTO>.self)
    }
    return try #require(page)
}
