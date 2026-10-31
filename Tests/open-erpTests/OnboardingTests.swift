@testable import open_erp
import Fluent
import SQLKit
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Create, reissue, accept and permanently reject further platform recovery")
    func onboardingRecoveryFlow() async throws {
        try await withApp { app in
            let admin = try await createUser(on: app.db, email: "ops@example.com", subject: "ops", isPlatformAdmin: true)
            let token = try await signAccessToken(on: app, subject: "ops")
            let recipient = try await signAccessToken(on: app, subject: "recipient")
            var created: ProvisionOrganizationResponse?
            try await app.testing().test(.POST, "platform/organizations", beforeRequest: { req in
                authorize(&req, token: token)
                try req.content.encode(ProvisionOrganizationDTO(code: "ACME", name: "Acme LLC",
                    adminEmail: "first@acme.com", adminFirstName: "First", adminLastName: "Admin"))
            }, afterResponse: { response in
                #expect(response.status == .ok)
                created = try response.content.decode(ProvisionOrganizationResponse.self)
            })
            let original = try #require(created)
            let id = try #require(original.organization.id)
            let path = "platform/organizations/\(id)/admin-invitation/reissue"
            try await app.testing().test(.POST, path, beforeRequest: { req in
                authorize(&req, token: token)
                try req.content.encode(["email": "changed@example.com"])
            }, afterResponse: { #expect($0.status == .badRequest) })
            var latest = original
            for state in ["live", "expired", "revoked"] {
                let prior = try #require(try await OrganizationInvitation.onboarding(organizationID: id, on: app.db))
                if state == "expired" {
                    prior.expiresAt = Date().addingTimeInterval(-1)
                    try await prior.save(on: app.db)
                }
                if state == "revoked" { try await prior.softDelete(by: try admin.requireID(), \.$deletedBy, on: app.db) }
                let oldToken = latest.invitationToken
                try await app.testing().test(.POST, path, beforeRequest: { authorize(&$0, token: token) }, afterResponse: { response in
                    #expect(response.status == .ok)
                    #expect(response.headers.first(name: .cacheControl) == "no-store")
                    latest = try response.content.decode(ProvisionOrganizationResponse.self)
                    #expect(latest.invitation.email == original.invitation.email)
                    #expect(latest.invitation.groupId == original.invitation.groupId)
                    #expect(latest.invitation.createdById == admin.id)
                    #expect(abs(latest.invitation.expiresAt.timeIntervalSinceNow - InvitationToken.lifetime) < 10)
                    #expect(latest.invitationToken != oldToken)
                })
                let history = try await OrganizationInvitation.query(on: app.db).withDeleted().filter(\.$id == prior.requireID()).first()
                #expect(history?.deletedAt != nil)
                #expect(history?.$deletedBy.id == admin.id)
                try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                    authorize(&req, token: recipient)
                    try req.content.encode(AcceptInvitationDTO(token: oldToken))
                }, afterResponse: { #expect($0.status == .notFound) })
            }
            stubUserInfo(app, email: "first@acme.com", emailVerified: false)
            try await acceptOnboarding(app, access: recipient, invitation: latest.invitationToken, status: .forbidden)
            #expect(try await Organization.find(id, on: app.db)?.onboardedAt == nil)
            stubUserInfo(app, email: "first@acme.com", emailVerified: true)
            try await acceptOnboarding(app, access: recipient, invitation: latest.invitationToken, status: .ok)
            let completed = try #require(try await Organization.find(id, on: app.db)?.onboardedAt)
            let membership = try #require(try await OrganizationUser.query(on: app.db, organizationID: id).first())
            try await membership.delete(on: app.db)
            try await app.testing().test(.POST, path, beforeRequest: { authorize(&$0, token: token) }, afterResponse: { #expect($0.status == .conflict) })
            #expect(try await Organization.find(id, on: app.db)?.onboardedAt == completed)
            #expect(try await OrganizationInvitation.query(on: app.db, organizationID: id).withDeleted().count() == 4)
        }
    }
}

extension OpenERPTests {
    @Test("Query logging never emits invitation tokens or their hashes")
    func invitationQueryLogsRedactBinds() async throws {
        try await withApp { app in
            let capture = CapturingLogHandler()
            app.logger = Logger(label: "test") { _ in RedactingLogHandler(base: capture) }
            let org = try await createOrganization(on: app.db, code: "LOGS", name: "Log tenant")
            let (invitation, token) = try await OrganizationInvitation.issue(
                organizationID: try org.requireID(), email: "first@logs.com", firstName: "First", lastName: "Admin",
                groupID: nil, createdByID: nil, on: app.db)
            // Acceptance looks the invitation up by its hash.
            _ = try await OrganizationInvitation.query(on: app.db).filter(\.$tokenHash == invitation.tokenHash).first()
            let lines = capture.lines
            #expect(lines.contains { $0.contains("organization_invitations") && $0.contains("[redacted]") })
            #expect(!lines.contains { $0.contains(invitation.tokenHash) || $0.contains(token) })
        }
    }
}

private final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    var lines: [String] { lock.withLock { captured } }
    func log(event: LogEvent) {
        lock.withLock { captured.append("\(event.message) \(event.metadata ?? [:])") }
    }
}

private func acceptOnboarding(_ app: Application, access: String, invitation: String, status: HTTPStatus) async throws {
    try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
        authorize(&req, token: access)
        try req.content.encode(AcceptInvitationDTO(token: invitation))
    }, afterResponse: { #expect($0.status == status) })
}

extension OpenERPTests {
    @Test("Recovery fails closed and replacement/acceptance errors roll back every write")
    func onboardingFailureBoundaries() async throws {
        try await withApp { app in
            let admin = try await createUser(on: app.db, email: "ops@example.com", subject: "ops", isPlatformAdmin: true)
            let actorID = try admin.requireID()
            let access = try await signAccessToken(on: app, subject: "ops")
            let recipient = try await signAccessToken(on: app, subject: "recipient")
            let org = try await createOrganization(on: app.db, code: "FAIL", name: "Failure checks")
            let id = try org.requireID()
            let path = "platform/organizations/\(id)/admin-invitation/reissue"
            let group = AccessGroup(organizationID: id, name: "Original", createdByID: actorID)
            try await group.save(on: app.db)
            let (initial, token) = try await OrganizationInvitation.issue(
                organizationID: id, email: "admin@example.com", firstName: "A", lastName: "B",
                groupID: try group.requireID(), createdByID: actorID, isOnboarding: true, on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("""
                CREATE FUNCTION reject_replacement() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN RAISE EXCEPTION 'injected replacement failure'; END; $$
                """).run()
            try await sql.raw("CREATE TRIGGER reject_replacement BEFORE INSERT ON organization_invitations FOR EACH ROW EXECUTE FUNCTION reject_replacement()").run()
            try await app.testing().test(.POST, path, beforeRequest: { authorize(&$0, token: access) }, afterResponse: { #expect($0.status == .internalServerError) })
            try await app.testing().test(.POST, "platform/organizations", beforeRequest: { req in
                authorize(&req, token: access)
                try req.content.encode(ProvisionOrganizationDTO(code: "ROLL", name: "Rollback tenant",
                    adminEmail: "new@example.com", adminFirstName: "A", adminLastName: "B"))
            }, afterResponse: { #expect($0.status == .internalServerError) })
            #expect(try await Organization.query(on: app.db).filter(\.$code == "ROLL").count() == 0)
            #expect(try await Role.query(on: app.db).count() == 0)
            #expect(try await AccessGroup.query(on: app.db).count() == 1)
            #expect(try await OrganizationInvitation.find(initial.requireID(), on: app.db) != nil)
            #expect(try await OrganizationInvitation.query(on: app.db, organizationID: id).withDeleted().count() == 1)
            try await sql.raw("DROP TRIGGER reject_replacement ON organization_invitations").run()
            try await sql.raw("DROP FUNCTION reject_replacement()").run()

            stubUserInfo(app, email: "other@example.com", emailVerified: true)
            try await acceptOnboarding(app, access: recipient, invitation: token, status: .forbidden)
            stubUserInfo(app, email: "admin@example.com", emailVerified: true)
            try await sql.raw("""
                CREATE FUNCTION reject_completion() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN IF NEW.onboarded_at IS NOT NULL THEN RAISE EXCEPTION 'injected completion failure'; END IF; RETURN NEW; END; $$
                """).run()
            try await sql.raw("CREATE TRIGGER reject_completion BEFORE UPDATE ON organizations FOR EACH ROW EXECUTE FUNCTION reject_completion()").run()
            try await acceptOnboarding(app, access: recipient, invitation: token, status: .internalServerError)
            #expect(try await OrganizationUser.query(on: app.db, organizationID: id).count() == 0)
            #expect(try await GroupMember.query(on: app.db).count() == 0)
            #expect(try await OrganizationInvitation.find(initial.requireID(), on: app.db)?.acceptedAt == nil)
            #expect(try await Organization.find(id, on: app.db)?.onboardedAt == nil)
            #expect(try await User.find(email: "admin@example.com", on: app.db) == nil)
            try await sql.raw("DROP TRIGGER reject_completion ON organizations").run()
            try await sql.raw("DROP FUNCTION reject_completion()").run()

            let change = ProposedChange.organizationInvitationCreate(InvitationDraft(
                email: initial.email, firstName: initial.firstName, lastName: initial.lastName,
                groupId: initial.$group.id, invitationId: nil))
            let approval = ApprovalRequest(organizationID: id, permission: change.permission.rawValue,
                targetID: nil, change: change, status: ApprovalRequestStatus.pending.rawValue, requestedByID: actorID)
            try await approval.save(on: app.db)
            initial.$approvalRequest.id = try approval.requireID()
            try await initial.save(on: app.db)
            try await acceptOnboarding(app, access: recipient, invitation: token, status: .conflict)
            #expect(try await Organization.find(id, on: app.db)?.onboardedAt == nil)
            initial.$approvalRequest.id = nil
            try await initial.save(on: app.db)

            // Identity binding remains in force.
            let bound = try await createUser(on: app.db, email: "admin@example.com", subject: "different")
            try await acceptOnboarding(app, access: recipient, invitation: token, status: .conflict)
            try await bound.delete(force: true, on: app.db)
            let another = try await createOrganization(on: app.db, code: "OTHR", name: "Other tenant")
            let foreign = AccessGroup(organizationID: try another.requireID(), name: "Foreign", createdByID: actorID)
            try await foreign.save(on: app.db)
            initial.$group.id = try foreign.requireID()
            try await initial.save(on: app.db)
            try await acceptOnboarding(app, access: recipient, invitation: token, status: .badRequest)
            try await app.testing().test(.POST, path, beforeRequest: { authorize(&$0, token: access) }, afterResponse: { #expect($0.status == .conflict) })
            initial.$group.id = try group.requireID()
            try await initial.save(on: app.db)
            try await group.delete(on: app.db)
            try await app.testing().test(.POST, path, beforeRequest: { authorize(&$0, token: access) }, afterResponse: { #expect($0.status == .conflict) })
            try await acceptOnboarding(app, access: recipient, invitation: token, status: .badRequest)
            // Accepted history without permanent completion is inconsistent and unavailable.
            initial.acceptedAt = Date()
            initial.$acceptedBy.id = actorID
            try await initial.save(on: app.db)
            try await app.testing().test(.POST, path, beforeRequest: { authorize(&$0, token: access) }, afterResponse: { #expect($0.status == .conflict) })
            let unknown = "platform/organizations/\(try another.requireID())/admin-invitation/reissue"
            try await app.testing().test(.POST, unknown, beforeRequest: { authorize(&$0, token: access) }, afterResponse: { #expect($0.status == .conflict) })
            try await org.delete(on: app.db)
            try await app.testing().test(.POST, path, beforeRequest: { authorize(&$0, token: access) }, afterResponse: { #expect($0.status == .notFound) })
        }
    }

    @Test("Ordinary invitations never set or clear permanent onboarding completion")
    func onboardingOrdinaryInvitations() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORDN", name: "Ordinary invitations")
            let id = try org.requireID()
            let recipient = try await signAccessToken(on: app, subject: "recipient")
            stubUserInfo(app, email: "admin@example.com", emailVerified: true)
            let (_, token) = try await OrganizationInvitation.issue(
                organizationID: id, email: "admin@example.com", firstName: "A", lastName: "B",
                groupID: nil, createdByID: nil, on: app.db)
            try await acceptOnboarding(app, access: recipient, invitation: token, status: .ok)
            #expect(try await Organization.find(id, on: app.db)?.onboardedAt == nil)
            org.onboardedAt = Date(timeIntervalSince1970: 1_700_000_000)
            try await org.save(on: app.db)
            let (_, next) = try await OrganizationInvitation.issue(
                organizationID: id, email: "other@example.com", firstName: "C", lastName: "D",
                groupID: nil, createdByID: nil, on: app.db)
            let other = try await signAccessToken(on: app, subject: "other")
            stubUserInfo(app, email: "other@example.com", emailVerified: true)
            try await acceptOnboarding(app, access: other, invitation: next, status: .ok)
            #expect(try await Organization.find(id, on: app.db)?.onboardedAt == org.onboardedAt)
        }
    }
}

