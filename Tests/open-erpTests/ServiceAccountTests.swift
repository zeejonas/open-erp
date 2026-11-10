@testable import open_erp
import Fluent
import Foundation
import Testing
import VaporTesting

/// Creates an enabled service account directly, bypassing the API, with permissions through its own group.
@discardableResult
func createServiceAccount(
    on db: any Database,
    organizationID: UUID,
    subject: String,
    ownerID: UUID,
    permissions: [Permission] = [],
    name: String = "AP integration"
) async throws -> ServiceAccount {
    let id = UUID()
    let user = try await createMember(
        on: db, organizationID: organizationID, email: ServiceAccount.email(for: id), subject: subject,
        permissions: permissions, firstName: name, lastName: "", kind: .service, id: id)
    let account = ServiceAccount(id: try user.requireID(), organizationID: organizationID, ownerID: ownerID, description: nil, createdByID: ownerID)
    try await account.create(on: db)
    return account
}

extension OpenERPTests {
    @Test("A service account user cannot be a platform administrator")
    func serviceAccountIsNeverPlatformAdmin() async throws {
        try await withApp { app in
            let user = User(firstName: "Bot", lastName: "", email: "bot@service-accounts.invalid", isPlatformAdmin: true, kind: .service)
            do {
                try await user.save(on: app.db)
                Issue.record("Expected the check constraint to reject a service platform administrator")
            } catch {
                #expect(String(reflecting: error).contains("23514"))
            }
        }
    }

    @Test("Service account writes are attributed to the account as service_account")
    func serviceAccountAttribution() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "SVC", name: "Service").requireID()
            let owner = try await createMember(on: app.db, organizationID: org, email: "owner@example.com", subject: "owner", permissions: [])
            let account = try await createServiceAccount(
                on: app.db, organizationID: org, subject: "bot@clients", ownerID: try owner.requireID(), permissions: [.companyCreate])
            let accountID = try account.requireID()
            let token = try await signAccessToken(on: app, subject: "bot@clients")
            try await app.testing().test(.POST, "companies", beforeRequest: { req in
                authorize(&req, token: token, organizationID: org)
                try req.content.encode(CreateCompanyDTO(code: "AP", name: "AP Co"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            let company = try #require(try await Company.query(on: app.db).filter(\.$code == "AP").first())
            #expect(company.$createdBy.id == accountID)
            let event = try #require(try await AuditEvent.query(on: app.db)
                .filter(\.$tableName == "companies").filter(\.$recordID == company.id).first())
            #expect(event.actorType == .serviceAccount)
            #expect(event.actorID == accountID)
        }
    }

    @Test("Disabled and deleted service accounts are refused while their tokens are live")
    func serviceAccountDisableTakesEffect() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "SVC", name: "Service").requireID()
            let owner = try await createMember(on: app.db, organizationID: org, email: "owner@example.com", subject: "owner", permissions: [])
            let account = try await createServiceAccount(on: app.db, organizationID: org, subject: "bot@clients", ownerID: try owner.requireID())
            let token = try await signAccessToken(on: app, subject: "bot@clients")
            try await authorizedGet(app, "me/access", token: token, organizationID: org) { #expect($0.status == .ok) }

            account.disabledAt = Date()
            try await account.update(on: app.db)
            try await authorizedGet(app, "me/access", token: token, organizationID: org) { #expect($0.status == .forbidden) }

            account.disabledAt = nil
            try await account.update(on: app.db)
            try await account.delete(on: app.db)
            try await authorizedGet(app, "me/access", token: token, organizationID: org) { #expect($0.status == .forbidden) }
        }
    }

    @Test("Last use is recorded once per day and audited as the account")
    func serviceAccountLastUse() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "SVC", name: "Service").requireID()
            let owner = try await createMember(on: app.db, organizationID: org, email: "owner@example.com", subject: "owner", permissions: [])
            let account = try await createServiceAccount(on: app.db, organizationID: org, subject: "bot@clients", ownerID: try owner.requireID())
            let accountID = try account.requireID()
            let token = try await signAccessToken(on: app, subject: "bot@clients")
            func usageEvents() async throws -> [AuditEvent] {
                try await AuditEvent.query(on: app.db)
                    .filter(\.$tableName == "service_accounts").filter(\.$recordID == accountID)
                    .filter(\.$operation == .update).all()
            }

            try await authorizedGet(app, "me/access", token: token, organizationID: org) { #expect($0.status == .ok) }
            let firstUse = try #require(try await ServiceAccount.find(accountID, on: app.db)?.lastUsedAt)
            let events = try await usageEvents()
            #expect(events.count == 1)
            #expect(events.first?.actorType == .serviceAccount)
            #expect(events.first?.actorID == accountID)

            for _ in 0..<3 {
                try await authorizedGet(app, "me/access", token: token, organizationID: org) { #expect($0.status == .ok) }
            }
            #expect(try await ServiceAccount.find(accountID, on: app.db)?.lastUsedAt == firstUse)
            #expect(try await usageEvents().count == 1)
        }
    }

    @Test("Service accounts cannot use person-only identity routes")
    func serviceAccountPersonOnlyRoutes() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "SVC", name: "Service").requireID()
            let owner = try await createMember(on: app.db, organizationID: org, email: "owner@example.com", subject: "owner", permissions: [])
            try await createServiceAccount(on: app.db, organizationID: org, subject: "bot@clients", ownerID: try owner.requireID())
            let token = try await signAccessToken(on: app, subject: "bot@clients")

            try await authorizedGet(app, "me", token: token) { #expect($0.status == .forbidden) }
            try await app.testing().test(.PATCH, "me", beforeRequest: { req in
                authorize(&req, token: token)
                try req.content.encode(["firstName": "Renamed"])
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
            let (_, invitationToken) = try await OrganizationInvitation.issue(
                organizationID: org, email: "new@example.com", firstName: "New", lastName: "Person",
                groupID: nil, createdByID: nil, on: app.db)
            stubUserInfo(app, email: "new@example.com", emailVerified: true)
            let memberships = try await OrganizationUser.query(on: app.db).count()
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: token)
                try req.content.encode(AcceptInvitationDTO(token: invitationToken))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
            #expect(try await OrganizationUser.query(on: app.db).count() == memberships)
            try await authorizedGet(app, "me/access", token: token, organizationID: org) { #expect($0.status == .ok) }
            try await authorizedGet(app, "me/organizations", token: token) { #expect($0.status == .ok) }
        }
    }

    @Test("A service account never counts as the last administrator")
    func serviceAccountIsNotAdministrator() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "SVC", name: "Service").requireID()
            let admin = try await createMember(on: app.db, organizationID: org, email: "admin@example.com", subject: "admin", permissions: Permission.allCases)
            try await createServiceAccount(
                on: app.db, organizationID: org, subject: "bot@clients", ownerID: try admin.requireID(), permissions: Permission.allCases)
            let token = try await signAccessToken(on: app, subject: "admin")
            try await app.testing().test(.DELETE, "organization-users/\(try admin.requireID())", beforeRequest: { req in
                authorize(&req, token: token, organizationID: org)
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("Member surfaces cover people; group members state each member's kind")
    func serviceAccountMemberSurfaces() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "SVC", name: "Service").requireID()
            let admin = try await createMember(on: app.db, organizationID: org, email: "admin@example.com", subject: "admin", permissions: Permission.allCases)
            let account = try await createServiceAccount(on: app.db, organizationID: org, subject: "bot@clients", ownerID: try admin.requireID(), permissions: [.companyRead])
            let accountID = try account.requireID()
            let token = try await signAccessToken(on: app, subject: "admin")

            try await authorizedGet(app, "users", token: token, organizationID: org) { res in
                let page = try res.content.decode(Page<GetUserDTO>.self)
                #expect(page.metadata.total == 1)
                #expect(page.items.map(\.id) == [try admin.requireID()])
            }
            try await authorizedGet(app, "users/\(accountID)", token: token, organizationID: org) { #expect($0.status == .notFound) }
            try await app.testing().test(.DELETE, "organization-users/\(accountID)", beforeRequest: { req in
                authorize(&req, token: token, organizationID: org)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
            #expect(try await OrganizationUser.query(on: app.db).filter(\.$user.$id == accountID).first() != nil)

            let group = try #require(try await AccessGroup.query(on: app.db)
                .filter(\.$name == "permissions-\(ServiceAccount.email(for: accountID))").first())
            try await authorizedGet(app, "groups/\(try group.requireID())/members", token: token, organizationID: org) { res in
                let page = try res.content.decode(Page<GetGroupMemberDTO>.self)
                #expect(page.items.map(\.userKind) == [.service])
            }
        }
    }

    @Test("Register, list and view service accounts within one organization")
    func serviceAccountRegistration() async throws {
        try await withApp { app in
            let tenant = try await webhookTenant(app)
            let other = try await webhookTenant(app, code: "OTHER")
            func register(_ dto: CreateServiceAccountDTO) async throws -> TestingHTTPResponse {
                try await webhookRequest(app, .POST, "service-accounts", tenant: tenant, body: dto)
            }

            let created = try await register(.init(name: "AP integration", description: "Bills", subject: "ap@clients"))
            #expect(created.status == .ok)
            let account = try created.content.decode(ServiceAccountDTO.self)
            #expect(account.enabled && account.lastUsedAt == nil && account.ownerId == tenant.userID && account.subject == "ap@clients")
            #expect(try await GroupMember.query(on: app.db).join(OrganizationUser.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
                .filter(OrganizationUser.self, \.$user.$id == account.id).count() == 0)

            #expect(try await register(.init(name: "Again", subject: "ap@clients")).status == .conflict)
            #expect(try await register(.init(name: "Person", subject: "OTHER")).status == .conflict)
            #expect(try await register(.init(name: "Bot owner", ownerId: account.id, subject: "x@clients")).status == .badRequest)
            #expect(try await register(.init(name: "Foreign owner", ownerId: other.userID, subject: "y@clients")).status == .badRequest)
            #expect(try await register(.init(name: "", subject: "z@clients")).status == .badRequest)
            #expect(try await webhookRequest(app, .POST, "service-accounts", tenant: other,
                body: CreateServiceAccountDTO(name: "Other", subject: "other@clients")).status == .ok)

            let page = try await webhookRequest(app, .GET, "service-accounts?enabled=true&name=ap&ownerId=\(tenant.userID)", tenant: tenant)
                .content.decode(Page<ServiceAccountDTO>.self)
            #expect(page.items.map(\.id) == [account.id] && page.metadata.total == 1)
            #expect(try await webhookRequest(app, .GET, "service-accounts?enabled=false", tenant: tenant)
                .content.decode(Page<ServiceAccountDTO>.self).metadata.total == 0)
            #expect(try await webhookRequest(app, .GET, "service-accounts/\(account.id)", tenant: tenant).status == .ok)
            #expect(try await webhookRequest(app, .GET, "service-accounts/\(account.id)", tenant: other).status == .notFound)
            #expect(try await webhookRequest(app, .PATCH, "service-accounts/\(account.id)", tenant: other,
                body: PatchServiceAccountDTO(name: "Stolen")).status == .notFound)
        }
    }

    @Test("Service account lifecycle is approval-gateable except disable, and re-checks the subject on apply")
    func serviceAccountApprovals() async throws {
        try await withApp { app in
            let tenant = try await webhookTenant(app)
            let approver = try await createMember(on: app.db, organizationID: tenant.organizationID, email: "approver@example.com",
                subject: "approver", permissions: [.approvalRequestRead])
            let reviewer = WebhookTestTenant(organizationID: tenant.organizationID, userID: try approver.requireID(), token: try await signAccessToken(on: app, subject: "approver"))
            let group = try #require(try await AccessGroup.query(on: app.db, organizationID: tenant.organizationID).filter(\.$name == "permissions-approver@example.com").first())
            let slots: [ApprovalStageDTO] = [.init(slots: [.init(groupId: try group.requireID(), required: 1)])]
            for (permission, fields) in [(Permission.serviceAccountCreate, [String]()), (.serviceAccountUpdate, ["enabled"])] {
                _ = try await app.db.auditedTransaction(AuditContext(actorType: .user, actorID: tenant.userID)) { db in
                    try await ProposedChange.approvalPolicyCreate(.init(name: permission.rawValue, permission: permission.rawValue, fields: fields, companyId: nil, stages: slots))
                        .apply(on: db, actorID: tenant.userID, organizationID: tenant.organizationID)
                }
            }

            let held = try await webhookRequest(app, .POST, "service-accounts", tenant: tenant, body: CreateServiceAccountDTO(name: "Late", subject: "late@clients"))
            #expect(held.status == .accepted)
            #expect(try await ServiceAccount.query(on: app.db).count() == 0)
            try await createUser(on: app.db, email: "late@example.com", subject: "late@clients")
            let requestID = try #require(try held.content.decode(GetApprovalRequestDTO.self).id)
            let failed = try await webhookRequest(app, .POST, "approval-requests/\(requestID)/approve", tenant: reviewer)
            #expect(try failed.content.decode(GetApprovalRequestDTO.self).status == "failed")
            #expect(try await ServiceAccount.query(on: app.db).count() == 0)

            let account = try await createServiceAccount(on: app.db, organizationID: tenant.organizationID, subject: "bot@clients", ownerID: tenant.userID)
            let accountID = try account.requireID()
            #expect(try await webhookRequest(app, .POST, "service-accounts/\(accountID)/disable", tenant: tenant).status == .noContent)
            #expect(try await ServiceAccount.find(accountID, on: app.db)?.disabledAt != nil)
            let reenable = try await webhookRequest(app, .PATCH, "service-accounts/\(accountID)", tenant: tenant, body: PatchServiceAccountDTO(enabled: true))
            #expect(reenable.status == .accepted)
            #expect(try await ServiceAccount.find(accountID, on: app.db)?.disabledAt != nil)
            let reenableID = try #require(try reenable.content.decode(GetApprovalRequestDTO.self).id)
            let applied = try await webhookRequest(app, .POST, "approval-requests/\(reenableID)/approve", tenant: reviewer)
            #expect(try applied.content.decode(GetApprovalRequestDTO.self).status == "applied")
            #expect(try await ServiceAccount.find(accountID, on: app.db)?.disabledAt == nil)
        }
    }

    @Test("Replacing the subject, disabling and deleting take effect on the account's tokens")
    func serviceAccountSubjectDisableDelete() async throws {
        try await withApp { app in
            let tenant = try await webhookTenant(app)
            let account = try await createServiceAccount(
                on: app.db, organizationID: tenant.organizationID, subject: "old@clients", ownerID: tenant.userID, permissions: [.companyCreate])
            let accountID = try account.requireID()
            let old = try await signAccessToken(on: app, subject: "old@clients")
            let new = try await signAccessToken(on: app, subject: "new@clients")
            func access(_ token: String) async throws -> HTTPStatus {
                try await app.testing().sendRequest(.GET, "me/access", beforeRequest: { authorize(&$0, token: token, organizationID: tenant.organizationID) }).status
            }
            try await app.testing().test(.POST, "companies", beforeRequest: { req in
                authorize(&req, token: old, organizationID: tenant.organizationID)
                try req.content.encode(CreateCompanyDTO(code: "BOT", name: "Bot Co"))
            }, afterResponse: { res async in #expect(res.status == .ok) })

            let patched = try await webhookRequest(app, .PATCH, "service-accounts/\(accountID)", tenant: tenant, body: PatchServiceAccountDTO(subject: "new@clients"))
            #expect(try patched.content.decode(ServiceAccountDTO.self).subject == "new@clients")
            #expect(try await access(old) == .forbidden)
            #expect(try await access(new) == .ok)

            for _ in 0..<2 {
                #expect(try await webhookRequest(app, .POST, "service-accounts/\(accountID)/disable", tenant: tenant).status == .noContent)
            }
            #expect(try await access(new) == .forbidden)
            let disabled = try #require(try await ServiceAccount.find(accountID, on: app.db))
            #expect(disabled.$disabledBy.id == tenant.userID)

            #expect(try await webhookRequest(app, .DELETE, "service-accounts/\(accountID)", tenant: tenant).status == .noContent)
            #expect(try await access(new) == .forbidden)
            #expect(try await webhookRequest(app, .GET, "service-accounts", tenant: tenant).content.decode(Page<ServiceAccountDTO>.self).metadata.total == 0)
            #expect(try await GroupMember.query(on: app.db).join(OrganizationUser.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
                .filter(OrganizationUser.self, \.$user.$id == accountID).count() == 0)
            #expect(try await Company.query(on: app.db).filter(\.$code == "BOT").first()?.$createdBy.id == accountID)
            #expect(try await webhookRequest(app, .POST, "service-accounts", tenant: tenant,
                body: CreateServiceAccountDTO(name: "Reused", subject: "new@clients")).status == .ok)
        }
    }
}
