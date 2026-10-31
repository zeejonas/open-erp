@testable import open_erp
import Fluent
import SQLKit
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("A failed race fixture removes its function and triggers before the next run")
    func onboardingRaceFixtureCleanup() async throws {
        do {
            try await withOnboardingRaceApp { app in
                let sql = try #require(app.db as? any SQLDatabase)
                try await sql.raw("CREATE TRIGGER onboarding_test_gate BEFORE INSERT ON organization_invitations FOR EACH ROW EXECUTE FUNCTION onboarding_test_gate()").run()
                throw CancellationError()
            }
            Issue.record("Expected the injected fixture failure")
        } catch is CancellationError {}
        // Creating the same function again fails if error-path cleanup left it behind.
        try await withOnboardingRaceApp { _ in }
    }

    @Test("Postgres serializes acceptance-first and concurrent onboarding reissues")
    func onboardingDatabaseRaces() async throws {
        try await withOnboardingRaceApp { app in
            let admin = try await createUser(on: app.db, email: "ops@example.com", subject: "ops", isPlatformAdmin: true)
            let access = try await signAccessToken(on: app, subject: "ops")
            let recipient = try await signAccessToken(on: app, subject: "recipient")
            let sql = try #require(app.db as? any SQLDatabase)
            // These triggers are only test barriers. They pause a write after its organization lock.
            try await sql.raw("CREATE TRIGGER onboarding_test_gate BEFORE UPDATE ON organizations FOR EACH ROW WHEN (NEW.onboarded_at IS NOT NULL) EXECUTE FUNCTION onboarding_test_gate()").run()
            let (org, initial) = try await raceFixture(app, actor: admin, code: "RACE")
            let id = try org.requireID()
            stubUserInfo(app, email: "recipient@example.com", emailVerified: true)
            _ = try await runDatabaseRace(app, first: {
                try await raceAccept(app, access: recipient, token: initial, expected: .ok)
            }, second: {
                try await raceReissue(app, access: access, id: id, expected: .conflict)
            })
            #expect(try await Organization.find(id, on: app.db)?.onboardedAt != nil)
            #expect(try await OrganizationInvitation.query(on: app.db, organizationID: id).withDeleted().count() == 1)
            try await sql.raw("DROP TRIGGER onboarding_test_gate ON organizations").run()

            let (second, _) = try await raceFixture(app, actor: admin, code: "TWIN")
            let secondID = try second.requireID()
            try await sql.raw("CREATE TRIGGER onboarding_test_gate BEFORE INSERT ON organization_invitations FOR EACH ROW WHEN (NEW.is_onboarding) EXECUTE FUNCTION onboarding_test_gate()").run()
            let replacements = try await runDatabaseRace(app, first: {
                try await raceReissue(app, access: access, id: secondID, expected: .ok)
            }, second: {
                try await raceReissue(app, access: access, id: secondID, expected: .ok)
            })
            let first = try #require(replacements.0)
            let last = try #require(replacements.1)
            try await raceAccept(app, access: recipient, token: first.invitationToken, expected: .notFound)
            // Use a distinct identity/email for the second tenant's first administrator.
            try await raceAccept(app, access: recipient, token: last.invitationToken, expected: .ok)
            let history = try await OrganizationInvitation.query(on: app.db, organizationID: secondID).withDeleted().all()
            #expect(history.count == 3)
            #expect(history.filter { $0.deletedAt == nil }.count == 1)
            #expect(history.allSatisfy { $0.$createdBy.id == admin.id })
            #expect(history.filter { $0.deletedAt != nil }.allSatisfy { $0.$deletedBy.id == admin.id })
            try await sql.raw("DROP TRIGGER onboarding_test_gate ON organization_invitations").run()
        }
    }

    @Test("Postgres serializes expired onboarding recovery with deletion of the original group")
    func onboardingGroupDeletionRace() async throws {
        try await withOnboardingRaceApp { app in
            let admin = try await createUser(on: app.db, email: "ops@example.com", subject: "ops", isPlatformAdmin: true)
            let access = try await signAccessToken(on: app, subject: "ops")
            let sql = try #require(app.db as? any SQLDatabase)

            // Each race pauses one write after it holds the group lock, then starts the other.
            func race(code: String, trigger: SQLQueryString, recoveryFirst: Bool) async throws -> UUID {
                let (org, _) = try await raceFixture(app, actor: admin, code: code)
                let id = try org.requireID()
                // An expired invitation is not pending, so it alone does not block group deletion.
                try await sql.raw("UPDATE organization_invitations SET expires_at = now() - interval '1 day' WHERE organization_id = \(bind: id)").run()
                let groupID = try #require(try await AccessGroup.query(on: app.db, organizationID: id).filter(\.$name == "Original group").first()?.requireID())
                _ = try await createMember(on: app.db, organizationID: id, email: "\(code)@example.com", subject: code, permissions: [.groupDelete])
                let tenantAdmin = try await signAccessToken(on: app, subject: code)
                let deleteGroup = { @Sendable (expected: HTTPStatus) in
                    _ = try await app.testing().test(.DELETE, "groups/\(groupID)", beforeRequest: {
                        authorize(&$0, token: tenantAdmin, organizationID: id)
                    }, afterResponse: { #expect($0.status == expected) })
                }
                try await sql.raw(trigger).run()
                _ = try await runDatabaseRace(app, first: {
                    if recoveryFirst { _ = try await raceReissue(app, access: access, id: id, expected: .ok) }
                    else { try await deleteGroup(.noContent) }
                }, second: {
                    if recoveryFirst { try await deleteGroup(.conflict) }
                    else { _ = try await raceReissue(app, access: access, id: id, expected: .conflict) }
                })
                return id
            }

            let recovered = try await race(
                code: "KEEP",
                trigger: "CREATE TRIGGER onboarding_test_gate BEFORE INSERT ON organization_invitations FOR EACH ROW WHEN (NEW.is_onboarding) EXECUTE FUNCTION onboarding_test_gate()",
                recoveryFirst: true)
            #expect(try await OrganizationInvitation.pending(on: app.db).filter(\.$organization.$id == recovered).count() == 1)
            #expect(try await AccessGroup.query(on: app.db, organizationID: recovered).filter(\.$name == "Original group").count() == 1)
            try await sql.raw("DROP TRIGGER onboarding_test_gate ON organization_invitations").run()

            let deleted = try await race(
                code: "DROP",
                trigger: "CREATE TRIGGER onboarding_test_gate BEFORE UPDATE ON groups FOR EACH ROW WHEN (NEW.deleted_at IS NOT NULL) EXECUTE FUNCTION onboarding_test_gate()",
                recoveryFirst: false)
            #expect(try await OrganizationInvitation.query(on: app.db, organizationID: deleted).withDeleted().count() == 1)
            #expect(try await AccessGroup.query(on: app.db, organizationID: deleted).filter(\.$name == "Original group").count() == 0)
            try await sql.raw("DROP TRIGGER onboarding_test_gate ON groups").run()
        }
    }

    @Test("Reissue during external userinfo fetch rejects the stale token without membership")
    func onboardingUserInfoRace() async throws {
        try await withApp { app in
            let admin = try await createUser(on: app.db, email: "ops@example.com", subject: "ops", isPlatformAdmin: true)
            let access = try await signAccessToken(on: app, subject: "ops")
            let recipient = try await signAccessToken(on: app, subject: "recipient")
            let (org, initial) = try await raceFixture(app, actor: admin, code: "INFO")
            let id = try org.requireID()
            let entered = RaceSignal()
            let release = RaceSignal()
            app.userInfoFetcher.fetch = { _ in
                await entered.signal()
                await release.wait()
                return UserInfo(email: "recipient@example.com", emailVerified: true)
            }
            let acceptance = Task { try await raceAccept(app, access: recipient, token: initial, expected: .notFound) }
            do {
                try await waitForSignal(entered)
                let replacement = try #require(try await raceReissue(app, access: access, id: id, expected: .ok))
                await release.signal()
                try await acceptance.value
                #expect(try await OrganizationUser.query(on: app.db, organizationID: id).count() == 0)
                #expect(try await Organization.find(id, on: app.db)?.onboardedAt == nil)
                stubUserInfo(app, email: "recipient@example.com", emailVerified: true)
                try await raceAccept(app, access: recipient, token: replacement.invitationToken, expected: .ok)
                _ = try await raceReissue(app, access: access, id: id, expected: .conflict)
            } catch {
                await release.signal()
                _ = try? await acceptance.value
                throw error
            }
        }
    }
}

private actor RaceSignal {
    private(set) var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signaled = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private func raceFixture(_ app: Application, actor: User, code: String) async throws -> (Organization, String) {
    let org = try await createOrganization(on: app.db, code: code, name: "Race tenant")
    let id = try org.requireID()
    let group = AccessGroup(organizationID: id, name: "Original group", createdByID: try actor.requireID())
    try await group.save(on: app.db)
    let (_, token) = try await OrganizationInvitation.issue(
        organizationID: id, email: "recipient@example.com", firstName: "First", lastName: "Admin",
        groupID: try group.requireID(), createdByID: try actor.requireID(), isOnboarding: true, on: app.db)
    return (org, token)
}

private func raceAccept(_ app: Application, access: String, token: String, expected: HTTPStatus) async throws {
    try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
        authorize(&req, token: access)
        try req.content.encode(AcceptInvitationDTO(token: token))
    }, afterResponse: { #expect($0.status == expected) })
}

private func raceReissue(_ app: Application, access: String, id: UUID, expected: HTTPStatus) async throws -> ProvisionOrganizationResponse? {
    var result: ProvisionOrganizationResponse?
    try await app.testing().test(.POST, "platform/organizations/\(id)/admin-invitation/reissue", beforeRequest: {
        authorize(&$0, token: access)
    }, afterResponse: { response in
        #expect(response.status == expected)
        if response.status == .ok { result = try response.content.decode(ProvisionOrganizationResponse.self) }
    })
    return result
}

/// Remove the function and its triggers before withApp reverts the tables, including on failure.
private func withOnboardingRaceApp(_ body: (Application) async throws -> Void) async throws {
    try await withApp { app in
        let sql = try #require(app.db as? any SQLDatabase)
        try await sql.raw("""
            CREATE FUNCTION onboarding_test_gate() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN PERFORM pg_advisory_xact_lock(941027); RETURN NEW; END; $$
            """).run()
        do {
            try await body(app)
        } catch {
            try? await sql.raw("DROP FUNCTION onboarding_test_gate() CASCADE").run()
            throw error
        }
        try await sql.raw("DROP FUNCTION onboarding_test_gate() CASCADE").run()
    }
}

/// Release the gate and join both requests before fixture cleanup, even when a barrier times out.
private func runDatabaseRace<First: Sendable, Second: Sendable>(
    _ app: Application,
    first: @escaping @Sendable () async throws -> First,
    second: @escaping @Sendable () async throws -> Second
) async throws -> (First, Second) {
    try await app.db.withConnection { connection in
        let gate = try #require(connection as? any SQLDatabase)
        let sql = try #require(app.db as? any SQLDatabase)
        try await gate.raw("SELECT pg_advisory_lock(941027)").run()
        let firstTask = Task { try await first() }
        var secondTask: Task<Second, any Error>?
        do {
            try await waitForDatabaseLock(sql, advisory: true)
            let last = Task { try await second() }
            secondTask = last
            try await waitForDatabaseLock(sql, advisory: false)
            try await gate.raw("SELECT pg_advisory_unlock(941027)").run()
            return try await (firstTask.value, last.value)
        } catch {
            try await gate.raw("SELECT pg_advisory_unlock(941027)").run()
            _ = try? await firstTask.value
            _ = try? await secondTask?.value
            throw error
        }
    }
}

/// Wait for observable server lock state, never a guessed scheduling delay.
private func waitForDatabaseLock(_ sql: any SQLDatabase, advisory: Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        let query: SQLQueryString = advisory
            ? "SELECT count(*) AS total FROM pg_locks WHERE locktype = 'advisory' AND objid = 941027 AND NOT granted"
            : "SELECT count(*) AS total FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query ~ 'FOR (NO KEY )?UPDATE'"
        let row = try #require(try await sql.raw(query).first())
        if try row.decode(column: "total", as: Int.self) > 0 { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw LockWaitTimedOut()
}
/// Bounded so a request that never reaches the barrier fails instead of hanging.
private func waitForSignal(_ signal: RaceSignal) async throws {
    let deadline = Date().addingTimeInterval(10)
    while await !signal.signaled {
        guard Date() < deadline else { throw LockWaitTimedOut() }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private struct LockWaitTimedOut: Error {}
