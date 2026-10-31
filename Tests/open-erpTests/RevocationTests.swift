@testable import open_erp
import Fluent
import JWT
import Logging
import SQLKit
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Logout is durable across instances/restarts and rejects replay on every route class")
    func durableLogout() async throws {
        try await withApp { app in
            let a = try await createOrganization(on: app.db, code: "REVA", name: "A")
            let b = try await createOrganization(on: app.db, code: "REVB", name: "B")
            let aID = try a.requireID(), bID = try b.requireID()
            let user = try await createMember(on: app.db, organizationID: aID, email: "rev@example.com",
                                              subject: "rev", permissions: [.companyRead], isPlatformAdmin: true)
            try await OrganizationUser(organizationID: bID, userID: try user.requireID()).save(on: app.db)
            let token = try await signAccessToken(on: app, subject: "rev")
            let other = try await signAccessToken(on: app, subject: "rev", expiration: Date().addingTimeInterval(1800))
            #expect(RevokedAccessToken.fingerprint(token) != RevokedAccessToken.fingerprint(other))
            let capture = CapturingLogHandler()
            app.logger = Logger(label: "revocations") { _ in RedactingLogHandler(base: capture) }
            app.logger.logLevel = .trace
            try await authorizedGet(app, "me", token: token) { #expect($0.status == .ok) }
            // Two separately configured applications share Postgres, but never rerun/revert migrations.
            try await withRevocationPeer(app) { peer in
                peer.logger = app.logger
                async let first: Void = logout(app, token: token)
                async let second: Void = logout(peer, token: token)
                _ = try await (first, second)
                let record = try #require(try await RevokedAccessToken.find(RevokedAccessToken.fingerprint(token), on: peer.db))
                #expect(record.issuer == app.oidc.issuer)
                #expect(record.subject == "rev")
                #expect(record.revokedAt <= Date())
                #expect(record.expiresAt > record.revokedAt)
                try await logout(peer, token: token)
                let retry = try #require(try await RevokedAccessToken.find(record.id, on: app.db))
                #expect(retry.revokedAt == record.revokedAt)
                #expect(try await RevokedAccessToken.query(on: app.db).count() == 1)
                for current in [app, peer] {
                    for (path, org) in [("me", nil), ("companies", aID), ("companies", bID)] {
                        try await authorizedGet(current, path, token: token, organizationID: org) {
                            try expectRevocationProblem($0, status: .unauthorized, code: .accessTokenRevoked)
                        }
                    }
                    for path in ["platform/organizations", "invitations/accept"] {
                        try await current.testing().test(.POST, path, beforeRequest: { authorize(&$0, token: token) }, afterResponse: {
                            try expectRevocationProblem($0, status: .unauthorized, code: .accessTokenRevoked)
                        })
                    }
                    try await authorizedGet(current, "me", token: other) { #expect($0.status == .ok) }
                    try await authorizedGet(current, "companies", token: other, organizationID: aID) { #expect($0.status == .ok) }
                    try await authorizedGet(current, "companies", token: other, organizationID: bID) { #expect($0.status == .forbidden) }
                }
            }
            // Fresh application after the peer shuts down still reads the committed record.
            try await withRevocationPeer(app) { restarted in
                try await authorizedGet(restarted, "me", token: token) {
                    try expectRevocationProblem($0, status: .unauthorized, code: .accessTokenRevoked)
                }
            }
            let events = capture.lines.filter { $0.contains("Access token revoked") }
            #expect(events.count == 1)
            for line in capture.lines {
                #expect(!line.contains(token))
                #expect(!line.contains(RevokedAccessToken.fingerprint(token)))
            }
        }
    }

    @Test("Logout validates all standard claims and rejects unsupported inputs without writes")
    func logoutValidation() async throws {
        try await withApp { app in
            let token = try await signAccessToken(on: app, subject: "unbound")
            for invalid in [
                try await signAccessToken(on: app, subject: "x", untrustedKey: true),
                try await signAccessToken(on: app, subject: "x", issuer: "https://wrong.example"),
                try await signAccessToken(on: app, subject: "x", audience: "wrong"),
                try await signAccessToken(on: app, subject: "x", expiration: .distantPast),
                "not-a-jwt",
            ] {
                try await logout(app, token: invalid, status: .unauthorized, code: .invalidAccessToken)
            }
            try await app.testing().test(.POST, "auth/logout", afterResponse: {
                try expectRevocationProblem($0, status: .unauthorized, code: .unauthorized)
            })
            for path in ["auth/logout?token=synthetic", "auth/logout?x=1"] {
                try await app.testing().test(.POST, path, beforeRequest: { authorize(&$0, token: token) }, afterResponse: {
                    try expectRevocationProblem($0, status: .badRequest, code: .badRequest)
                })
            }
            try await app.testing().test(.POST, "auth/logout", beforeRequest: {
                authorize(&$0, token: token)
                $0.body = ByteBuffer(string: " ")
            }, afterResponse: { try expectRevocationProblem($0, status: .badRequest, code: .badRequest) })
            try await app.testing().test(.POST, "auth/logout", beforeRequest: {
                authorize(&$0, token: token, organizationID: UUID())
            }, afterResponse: { try expectRevocationProblem($0, status: .badRequest, code: .badRequest) })
            #expect(try await RevokedAccessToken.query(on: app.db).count() == 0)
            let capture = CapturingLogHandler()
            app.logger = Logger(label: "logout-audit") { _ in RedactingLogHandler(base: capture) }
            let before = Date()
            try await logout(app, token: token)
            let first = try #require(try await RevokedAccessToken.query(on: app.db).first())
            #expect(first.subject == "unbound")
            #expect(first.revokedAt >= before)
            #expect(try await User.query(on: app.db).count() == 0)
            try await logout(app, token: token)
            let event = try #require(capture.lines.first { $0.contains("Access token revoked") })
            #expect(event.contains("unbound"))
            #expect(event.contains(app.oidc.issuer))
            #expect(event.contains("revoked_at"))
            #expect(capture.lines.filter { $0.contains("Access token revoked") }.count == 1)
            #expect(!capture.lines.contains { $0.contains(token) || $0.contains(first.id!) })
            let removed = try await createUser(on: app.db, email: "removed@example.com", subject: "removed")
            try await removed.delete(on: app.db)
            let removedToken = try await signAccessToken(on: app, subject: "removed")
            try await logout(app, token: removedToken)
        }
    }

    @Test("Revocation read/write failures fail closed and never leak credentials")
    func revocationFailures() async throws {
        try await withApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let token = try await signAccessToken(on: app, subject: "unbound")
            let capture = CapturingLogHandler()
            app.logger = Logger(label: "revocation-failures") { _ in RedactingLogHandler(base: capture) }
            app.logger.logLevel = .trace
            // Keep the table readable to prove a nonduplicate insert error is not swallowed.
            try await sql.raw("ALTER TABLE revoked_access_tokens ADD CONSTRAINT reject_revocation CHECK (subject <> 'unbound')").run()
            try await logout(app, token: token, status: .serviceUnavailable, code: .authenticationUnavailable)
            #expect(try await RevokedAccessToken.query(on: app.db).count() == 0)
            try await sql.raw("ALTER TABLE revoked_access_tokens DROP CONSTRAINT reject_revocation").run()
            try await sql.raw("ALTER TABLE revoked_access_tokens RENAME TO unavailable_revocations").run()
            do {
                try await authorizedGet(app, "me", token: token) {
                    try expectRevocationProblem($0, status: .serviceUnavailable, code: .authenticationUnavailable)
                    #expect(!$0.body.string.contains(token))
                    #expect(!$0.body.string.contains(RevokedAccessToken.fingerprint(token)))
                }
                try await logout(app, token: token, status: .serviceUnavailable, code: .authenticationUnavailable)
            } catch {
                try await sql.raw("ALTER TABLE unavailable_revocations RENAME TO revoked_access_tokens").run()
                throw error
            }
            try await sql.raw("ALTER TABLE unavailable_revocations RENAME TO revoked_access_tokens").run()
            try await logout(app, token: token)
            #expect(!capture.lines.contains { $0.contains(token) || $0.contains(RevokedAccessToken.fingerprint(token)) })
        }
    }

    @Test("Fresh revocation schema enforces required fields and primary key; prune retains unexpired rows")
    func revocationSchemaAndPrune() async throws {
        try await withApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let now = Date()
            let token = try await signAccessToken(on: app, subject: "active")
            let claims = AccessToken(issuer: .init(value: app.oidc.issuer), subject: .init(value: "active"),
                                     audience: .init(value: app.oidc.audience), expiration: .init(value: now.addingTimeInterval(3600)))
            let active = RevokedAccessToken(bearer: token, claims: claims)
            #expect(try await active.insertIfAbsent(on: app.db))
            let duplicate = RevokedAccessToken(bearer: token, claims: claims, revokedAt: now.addingTimeInterval(100))
            #expect(try await !duplicate.insertIfAbsent(on: app.db))
            let stored = try #require(try await RevokedAccessToken.find(active.id, on: app.db))
            #expect(abs(stored.revokedAt.timeIntervalSince(active.revokedAt)) < 0.001)
            for field in ["fingerprint", "issuer", "subject", "expires_at", "revoked_at"] {
                do {
                    try await sql.raw("UPDATE revoked_access_tokens SET \(ident: field) = NULL").run()
                    Issue.record("Required field accepted NULL: \(field)")
                } catch {}
            }
            var expiredClaims = claims
            expiredClaims.expiration = .init(value: now)
            let expired = RevokedAccessToken(bearer: "synthetic-expired", claims: expiredClaims)
            try await expired.create(on: app.db)
            do {
                try await RevokedAccessToken(bearer: token, claims: claims).create(on: app.db)
                Issue.record("Duplicate fingerprint accepted")
            } catch {}
            #expect(try await PruneRevokedTokensCommand.prune(on: app.db, now: now) == 1)
            #expect(try await PruneRevokedTokensCommand.prune(on: app.db, now: now) == 0)
            // Exercise the native command, including its reported cleanup count.
            expiredClaims.expiration = .init(value: now.addingTimeInterval(-60))
            try await RevokedAccessToken(bearer: "synthetic-command-expired", claims: expiredClaims).create(on: app.db)
            let capture = CapturingLogHandler()
            app.logger = Logger(label: "prune-audit") { _ in RedactingLogHandler(base: capture) }
            var context = CommandContext(console: app.console, input: CommandInput(arguments: ["prune-revoked-tokens"]))
            context.application = app
            try await PruneRevokedTokensCommand().run(using: &context)
            let cleanup = try #require(capture.lines.first { $0.contains("revocations pruned") })
            #expect(cleanup.contains("count") && cleanup.contains("1"))
            #expect(!capture.lines.contains { $0.contains(token) || $0.contains(RevokedAccessToken.fingerprint(token)) })
            #expect(try await RevokedAccessToken.query(on: app.db).count() == 1)
            try await authorizedGet(app, "me", token: token) {
                try expectRevocationProblem($0, status: .unauthorized, code: .accessTokenRevoked)
            }
            // Exercise the owning create migration's revert and re-create on the fresh test schema.
            try await CreateRevokedAccessToken().revert(on: app.db)
            try await CreateRevokedAccessToken().prepare(on: app.db)
            #expect(try await RevokedAccessToken.query(on: app.db).count() == 0)
        }
    }

    @Test("Revocation covers every signature encoding of the token")
    func revocationIgnoresSignatureEncoding() async throws {
        try await withApp { app in
            let token = try await signAccessToken(on: app, subject: "malleable")
            let variants = [trailingBitsVariant(of: token), highSVariant(of: token)]
            for variant in variants {
                #expect(variant != token)
                // Unbound subject: 403 proves the variant passes verification.
                try await authorizedGet(app, "me", token: variant) { #expect($0.status == .forbidden) }
            }
            try await logout(app, token: token)
            for variant in variants {
                try await authorizedGet(app, "me", token: variant) {
                    try expectRevocationProblem($0, status: .unauthorized, code: .accessTokenRevoked)
                }
                try await logout(app, token: variant)
            }
            #expect(try await RevokedAccessToken.query(on: app.db).count() == 1)
        }
    }
}

private func withRevocationPeer(_ source: Application, _ test: (Application) async throws -> Void) async throws {
    let peer = try await Application.make(.testing)
    do {
        try await configure(peer)
        peer.jwt.keys = source.jwt.keys
        try await test(peer)
    } catch {
        try await peer.asyncShutdown()
        throw error
    }
    try await peer.asyncShutdown()
}

private func logout(_ app: Application, token: String, status: HTTPStatus = .noContent, code: ProblemCode? = nil) async throws {
    try await app.testing().test(.POST, "auth/logout", beforeRequest: { authorize(&$0, token: token) }, afterResponse: {
        #expect($0.status == status)
        if let code { try expectRevocationProblem($0, status: status, code: code) }
        else { #expect($0.body.readableBytes == 0) }
    })
}

private func expectRevocationProblem(_ response: TestingHTTPResponse, status: HTTPStatus, code: ProblemCode) throws {
    #expect(response.status == status)
    #expect(response.headers.contentType == .problemJSON)
    let problem = try response.content.decode(Problem.self, as: .json)
    #expect(problem.code == code)
    #expect(problem.status == status.code)
    #expect(problem.type == "urn:open-erp:problem:\(code.rawValue)")
    #expect(problem.title == status.reasonPhrase)
    if code == .accessTokenRevoked { #expect(response.headers[.wwwAuthenticate] == [#"Bearer error="invalid_token""#]) }
    if status == .serviceUnavailable { #expect(problem.detail == "Something went wrong.") }
}

private let base64URLAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

/// Flips an unused trailing bit of the 64-byte ES256 signature's final base64url character.
private func trailingBitsVariant(of token: String) -> String {
    let last = base64URLAlphabet.firstIndex(of: token.last!)!
    return token.dropLast() + String(base64URLAlphabet[last ^ 1])
}

/// Replaces ECDSA `s` with `n − s`, which also verifies.
private func highSVariant(of token: String) -> String {
    let parts = token.split(separator: ".")
    var base64 = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    var signature = [UInt8](Data(base64Encoded: base64)!)
    let order: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
    ]
    var borrow = 0
    for i in (0..<32).reversed() {
        let difference = Int(order[i]) - Int(signature[32 + i]) - borrow
        signature[32 + i] = UInt8((difference + 256) % 256)
        borrow = difference < 0 ? 1 : 0
    }
    let encoded = Data(signature).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "\(parts[0]).\(parts[1]).\(encoded)"
}
