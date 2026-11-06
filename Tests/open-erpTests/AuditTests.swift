@testable import open_erp
import Fluent
import FluentPostgresDriver
import Logging
import NIOCore
import SQLKit
import SwiftOpenAPI
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Audit capture records values and operations atomically")
    func auditCapture() async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "AUDIT", name: "Audit").requireID()
            let userID = try await createUser(on: app.db, email: "audit@example.com").requireID()
            let company = Company(
                code: "AUDIT", name: "Original", organizationID: orgID,
                createdBy: nil, updatedBy: nil, deletedBy: nil
            )
            try await company.save(on: app.db)
            let id = try company.requireID()
            let sql = try app.db.requireSQL()
            try await sql.raw("UPDATE companies SET name = 'Renamed' WHERE id = \(bind: id)").run()
            try await sql.raw("UPDATE companies SET name = name WHERE id = \(bind: id)").run()

            let context = AuditContext(actorType: .user, actorID: userID, requestID: "remove-company")
            try await app.db.auditedTransaction(context) { db in
                try await company.softDelete(by: userID, \.$deletedBy, on: db)
            }
            try await company.restore(on: app.db)
            try await company.delete(force: true, on: app.db)

            let events = try await AuditEvent.query(on: app.db).filter(\.$recordID == id).sort(\.$createdAt).all()
            #expect(events.map(\.operation) == [.create, .update, .update, .softDelete, .restore, .delete])
            let rename = try #require(events.dropFirst().first)
            #expect(rename.oldValues?.values["name"] == "Original")
            #expect(rename.newValues?.values["name"] == "Renamed")
            #expect(rename.changedFields == ["name"])
            #expect(rename.actorType == .database)
            let session = try await sql.raw("SELECT session_user::text AS name").first()
            #expect(rename.databaseUser == (try session?.decode(column: "name", as: String.self)))
            let removal = events.filter { $0.requestID == "remove-company" }
            #expect(removal.map(\.operation) == [.update, .softDelete])
            #expect(Set(removal.map(\.transactionID)).count == 1)
            #expect(removal.allSatisfy { $0.actorID == userID && $0.organizationID == orgID })

            await #expect(throws: RollBackAuditFixture.self) {
                try await app.db.auditedTransaction(context) { db in
                    try await db.requireSQL().raw("UPDATE organizations SET name = 'Rolled back' WHERE id = \(bind: orgID)").run()
                    throw RollBackAuditFixture()
                }
            }
            #expect(try await Organization.find(orgID, on: app.db)?.name == "Audit")
            #expect(try await AuditEvent.query(on: app.db).filter(\.$recordID == orgID).count() == 1)

            for statement: SQLQueryString in [
                "UPDATE audit.audit_events SET operation = operation",
                "DELETE FROM audit.audit_events",
                "TRUNCATE audit.audit_events",
            ] {
                do {
                    try await sql.raw(statement).run()
                    Issue.record("The database accepted a mutation of audit evidence")
                } catch {
                    #expect(String(reflecting: error).contains("append-only"))
                }
            }
        }
    }

    @Test("Sensitive columns stay out of audit values")
    func auditRedaction() async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "SECRET", name: "Secret").requireID()
            let (invite, _) = try await OrganizationInvitation.issue(
                organizationID: orgID, email: "invite@example.com", firstName: "A", lastName: "B",
                groupID: nil, createdByID: nil, on: app.db
            )
            invite.tokenHash = "replacement"
            try await invite.update(on: app.db)
            let user = try await createUser(on: app.db, email: "redact@example.com", subject: "old-subject")
            user.authSubject = "new-subject"
            try await user.update(on: app.db)

            for (table, field) in [("organization_invitations", "token_hash"), ("users", "auth_subject")] {
                let update = try #require(try await AuditEvent.query(on: app.db)
                    .filter(\.$tableName == table).filter(\.$operation == .update).first())
                #expect(update.changedFields.contains(field))
                #expect(update.oldValues?.values["id"] != nil)
                #expect(update.newValues?.values["id"] != nil)
                #expect(update.oldValues?.values[field] == nil)
                #expect(update.newValues?.values[field] == nil)
            }
        }
    }

    @Test("Production rejects the owner and permits a separate runtime login")
    func auditServingRole() async throws {
        try await withApp { app in
            let capture = CapturingLogHandler()
            let logger = Logger(label: "audit-role") { _ in capture }
            await #expect(throws: AuditSafetyError.unsafeDatabaseRole) {
                try await checkServingDatabaseRole(on: app.db, environment: .production, logger: logger)
            }
            try await checkServingDatabaseRole(on: app.db, environment: .development, logger: logger)
            #expect(capture.lines.contains { $0.contains(AuditSafetyError.unsafeDatabaseRole.description) })

            try await checkServingDatabaseRole(on: try runtimeDatabase(app), environment: .production, logger: logger)
        }
    }

    @Test("The runtime role fails closed and cannot alter evidence after a revert and migrate")
    func auditRuntimeRole() async throws {
        try await withApp { app in
            try await app.autoRevert()
            try await app.autoMigrate()
            let runtime = try runtimeDatabase(app)
            let sql = try runtime.requireSQL()
            let id = UUID()
            let insert: SQLQueryString = "INSERT INTO organizations (id, code, name) VALUES (\(bind: id), 'RUNTIME', 'Runtime')"

            await expectDenied(mentioning: "Missing audit context") { try await sql.raw(insert).run() }
            #expect(try await Organization.find(id, on: runtime) == nil)
            #expect(try await AuditEvent.query(on: runtime).filter(\.$recordID == id).count() == 0)

            try await runtime.auditedTransaction(AuditContext(actorType: .system, actorName: "runtime-test")) { db in
                try await db.requireSQL().raw(insert).run()
            }
            let event = try #require(try await AuditEvent.query(on: runtime).filter(\.$recordID == id).first())
            #expect(event.actorType == .system)
            #expect(event.actorName == "runtime-test")
            #expect(event.databaseUser == "open_erp_runtime")

            for statement: SQLQueryString in [
                "INSERT INTO audit.audit_events DEFAULT VALUES",
                "ALTER TABLE organizations DISABLE TRIGGER capture_audit_change",
                "TRUNCATE organizations",
                "CREATE TABLE public.runtime_test (id int)",
                "CREATE TABLE audit.runtime_test (id int)",
            ] {
                await expectDenied { try await sql.raw(statement).run() }
            }
            try await runtime.transaction { db in
                let transaction = try db.requireSQL()
                try await transaction.raw("CREATE TEMP TABLE runtime_forgery (id uuid) ON COMMIT DROP").run()
                await expectDenied {
                    try await transaction.raw("""
                        CREATE TRIGGER forged AFTER INSERT ON runtime_forgery
                        FOR EACH ROW EXECUTE FUNCTION audit.capture_change()
                        """).run()
                }
            }
        }
    }

    @Test("Audit verification reports unsafe grants and fails the command")
    func auditGrants() async throws {
        try await withApp { app in
            var context = CommandContext(console: app.console, input: CommandInput(arguments: ["audit-verify"]))
            context.application = app
            await #expect(throws: AuditSafetyError.verificationFailed) {
                try await AuditVerifyCommand().run(using: &context)
            }
            await #expect(throws: RollBackAuditFixture.self) {
                try await app.db.transaction { db in
                    let sql = try db.requireSQL()
                    #expect(try await auditGrantProblems(on: db) == [runtimeGrantProblem("public._fluent_migrations")])
                    try await sql.raw("REVOKE ALL ON public._fluent_migrations FROM open_erp_runtime").run()
                    #expect(try await auditGrantProblems(on: db).isEmpty)
                    try await sql.raw("GRANT INSERT ON audit.audit_events TO open_erp_runtime").run()
                    try await sql.raw("GRANT TRUNCATE ON companies TO open_erp_runtime").run()
                    #expect(try await auditGrantProblems(on: db) == [runtimeGrantProblem("audit.audit_events"), runtimeGrantProblem("public.companies")])
                    throw RollBackAuditFixture()
                }
            }
        }
    }

    @Test("Audit verification detects missing and disabled triggers and unclassified tables")
    func auditCoverage() async throws {
        try await withApp { app in
            let sql = try app.db.requireSQL()
            #expect(try await auditCoverageProblems(on: app.db).isEmpty)
            await #expect(throws: RollBackAuditFixture.self) {
                try await app.db.transaction { db in
                    let transaction = try db.requireSQL()
                    try await transaction.raw("ALTER TABLE users DISABLE TRIGGER capture_audit_change").run()
                    try await transaction.raw("DROP TRIGGER capture_audit_change ON companies").run()
                    try await transaction.raw("CREATE TABLE public.unclassified (id UUID)").run()
                    try await db.createChangeTrigger(on: "unclassified")
                    let problems = try await auditCoverageProblems(on: db)
                    #expect(problems.count == 3)
                    #expect(problems.contains { $0.contains("public.users") && $0.contains("enabled") })
                    #expect(problems.contains { $0.contains("public.companies") && $0.contains("enabled") })
                    #expect(problems.contains { $0.contains("public.unclassified") && $0.contains("organization_id") })
                    throw RollBackAuditFixture()
                }
            }
            try await app.autoRevert()
            let objects = try #require(try await sql.raw("""
                SELECT pg_catalog.to_regnamespace('audit') IS NOT NULL
                    AND pg_catalog.to_regclass('audit.audit_events') IS NULL
                    AND pg_catalog.to_regprocedure('audit.capture_change()') IS NULL
                    AND pg_catalog.to_regprocedure('audit.audit_events_append_only()') IS NULL AS reverted
                """).first())
            #expect(try objects.decode(column: "reverted", as: Bool.self))
            try await app.autoMigrate()
            #expect(try await auditCoverageProblems(on: app.db).isEmpty)
        }
    }

    @Test("Audit reads enforce permissions, scope, attribution visibility, and strict paging")
    func auditReadAPIs() async throws {
        try await withApp { app in
            let a = try await createOrganization(on: app.db, code: "AUDITA", name: "A").requireID()
            let b = try await createOrganization(on: app.db, code: "AUDITB", name: "B").requireID()
            let reader = try await createMember(
                on: app.db, organizationID: a, email: "reader@example.com", subject: "reader", permissions: [.auditEventRead]
            )
            _ = try await createMember(
                on: app.db, organizationID: a, email: "denied@example.com", subject: "denied", permissions: []
            )
            let readerToken = try await signAccessToken(on: app, subject: "reader")
            let denied = try await signAccessToken(on: app, subject: "denied")
            let admin = try await createUser(
                on: app.db, email: "platform@example.com", subject: "platform", isPlatformAdmin: true
            )
            let adminID = try admin.requireID()
            let adminToken = try await signAccessToken(on: app, subject: "platform")
            let platformContext = AuditContext(
                actorType: .platformAdmin, actorID: adminID, ipAddress: "203.0.113.7", requestID: "platform-audit"
            )
            try await app.db.auditedTransaction(platformContext) { db in
                try await db.requireSQL().raw("UPDATE organizations SET name = 'A edited' WHERE id = \(bind: a)").run()
            }

            try await authorizedGet(app, "audit-events", token: denied, organizationID: a) { #expect($0.status == .forbidden) }
            try await authorizedGet(app, "audit-events", token: readerToken, organizationID: b) { #expect($0.status == .forbidden) }
            try await authorizedGet(app, "platform/audit-events", token: readerToken) { #expect($0.status == .forbidden) }

            let query = "recordId=\(a)&table=organizations&from=2020-01-01T00:00:00Z&to=2100-01-01T00:00:00Z&per=1"
            try await authorizedGet(app, "audit-events", query: query, token: readerToken, organizationID: a) { response async throws in
                #expect(response.status == .ok)
                let page = try response.content.decode(Page<AuditEventDTO>.self)
                #expect(page.metadata.total == 2)
                let event = try #require(page.items.first)
                #expect(event.organizationId == a)
                #expect(event.actorType == .platformAdmin)
                #expect(event.actorId == adminID)
                #expect(event.ipAddress == nil)
                #expect(event.databaseUser == nil)
                #expect(event.newValues?.values["name"] == "A edited")
            }
            try await authorizedGet(app, "audit-events", query: query + "&page=2", token: readerToken, organizationID: a) { response async throws in
                #expect(try response.content.decode(Page<AuditEventDTO>.self).items.map(\.operation) == [.create])
            }
            for filters in ["recordId=\(b)", "table=users"] {
                try await authorizedGet(app, "audit-events", query: filters, token: readerToken, organizationID: a) { response async throws in
                    let page = try response.content.decode(Page<AuditEventDTO>.self)
                    #expect(page.items.isEmpty)
                    #expect(page.metadata.total == 0)
                }
            }
            for (name, query) in [
                ("operation", "operation=unknown"), ("extra", "extra=x"), ("from", "from=tomorrow"),
                ("per", "per=101"), ("table", "table=users&table=companies"),
            ] {
                try await authorizedGet(app, "audit-events", query: query, token: readerToken, organizationID: a) {
                    try expectBadRequest($0, naming: name)
                }
            }

            try await app.testing().test(.PATCH, "me", beforeRequest: { request in
                authorize(&request, token: readerToken)
                request.headers.replaceOrAdd(name: "X-Request-Id", value: "profile-audit")
                try request.content.encode(PatchMeDTO(firstName: "Renamed", lastName: nil))
            }, afterResponse: { #expect($0.status == .ok) })
            let readerID = try reader.requireID()
            let filter = "table=users&actorId=\(readerID)&operation=update&requestId=profile-audit"
            try await authorizedGet(app, "platform/audit-events", query: filter, token: adminToken) { response async throws in
                let events = try response.content.decode(Page<AuditEventDTO>.self).items
                #expect(events.count == 1)
                let event = try #require(events.first)
                #expect(event.recordId == readerID)
                #expect(event.actorType == .user)
                #expect(event.organizationId == nil)
                #expect(event.databaseUser != nil)
            }
            try await authorizedGet(app, "platform/audit-events", query: "recordId=\(a)", token: adminToken) { response async throws in
                #expect(try response.content.decode(Page<AuditEventDTO>.self).items.isEmpty)
            }
        }
    }

    @Test("Platform-admin requires operator attribution on grants and revocations")
    func platformAdminAudit() async throws {
        try await withApp { app in
            let arguments = ["platform-admin", "operator-test@example.com", "Ada", "Lovelace", "operator-test"]
            var context = CommandContext(console: app.console, input: CommandInput(arguments: arguments))
            context.application = app
            await #expect(throws: PlatformAdminCommandError.self) {
                try await PlatformAdminCommand().run(using: &context)
            }
            #expect(try await User.query(on: app.db).count() == 0)
            for options in [["--operator", "Pat Operator"], ["--operator", "Pat Operator", "--revoke"]] {
                var command = CommandContext(console: app.console, input: CommandInput(arguments: arguments + options))
                command.application = app
                try await PlatformAdminCommand().run(using: &command)
            }
            let events = try await AuditEvent.query(on: app.db).filter(\.$tableName == "users").sort(\.$createdAt).all()
            #expect(events.map(\.operation) == [.create, .update])
            #expect(events.allSatisfy { $0.actorType == .operator && $0.actorName == "Pat Operator" })
        }
    }
}

struct AuditClientIPTests {
    @Test func trustedForwardingHops() async throws {
        let app = try await Application.make(.testing)
        let socket = try SocketAddress(ipAddress: "192.0.2.10", port: 443)
        let request = Request(application: app, remoteAddress: socket, on: app.eventLoopGroup.next())
        request.headers.add(name: "Forwarded", value: "for=198.51.100.1")
        request.headers.add(name: "X-Forwarded-For", value: "198.51.100.9")
        request.headers.add(name: "X-Forwarded-For", value: " 2001:db8::7 , 203.0.113.7")
        for (count, expected) in [(0, "192.0.2.10"), (1, "203.0.113.7"), (2, "2001:db8::7"), (4, "192.0.2.10")] {
            app.storage[TrustedProxyCount.self] = count
            #expect(request.auditClientIP == expected)
        }
        app.storage[TrustedProxyCount.self] = 1
        request.headers.replaceOrAdd(name: "X-Forwarded-For", value: "198.51.100.9, forged")
        #expect(request.auditClientIP == "192.0.2.10")
        try await app.asyncShutdown()
    }

    @Test func trustedProxyCountValidation() throws {
        #expect(try TrustedProxyCount.parse(nil) == 0)
        #expect(try TrustedProxyCount.parse("2") == 2)
        for value in ["-1", "", "one"] {
            #expect(throws: DatabaseSettings.InvalidValue.self) { try TrustedProxyCount.parse(value) }
        }
    }
}

private struct RollBackAuditFixture: Error {}

/// Connects as the runtime role that bootstrap.sql creates.
private func runtimeDatabase(_ app: Application) throws -> any Database {
    let password = try #require(Environment.get("AUDIT_TEST_RUNTIME_PASSWORD"))
    let settings = try DatabaseSettings(testing: true) { name in
        switch name {
        case "DATABASE_USERNAME": "open_erp_runtime"
        case "DATABASE_PASSWORD": password
        default: Environment.get(name)
        }
    }
    let id = DatabaseID(string: "audit-runtime-test")
    app.databases.use(.postgres(configuration: try settings.postgresConfiguration()), as: id)
    return app.db(id)
}

private func runtimeGrantProblem(_ target: String) -> String {
    "Database role open_erp_runtime has unsafe privileges on \(target)"
}

private func expectDenied(mentioning message: String = "42501", _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected the database to deny the statement")
    } catch {
        #expect(String(reflecting: error).contains(message))
    }
}
