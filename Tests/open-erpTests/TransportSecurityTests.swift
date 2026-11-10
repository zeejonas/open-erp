@testable import open_erp
import Crypto
import Foundation
import JWT
import Logging
import NIOSSL
import Testing
import VaporTesting

@Suite("Transport security")
struct TransportSecurityTests {
    @Test("HSTS covers success and problem responses, and 0 turns it off")
    func strictTransportSecurity() async throws {
        for (value, expected) in [("600", ["max-age=600"]), ("0", [])] {
            try await withApplication(.testing) { app in
                try configureAPI(app) { ["HSTS_MAX_AGE_SECONDS": value][$0] }
                for (path, status) in [("openapi.json", HTTPStatus.ok), ("me", .unauthorized), ("unknown-route", .notFound)] {
                    try await app.testing().test(.GET, path, afterResponse: { response in
                        #expect(response.status == status)
                        #expect(response.headers[.strictTransportSecurity] == expected)
                    })
                }
            }
        }
        #expect(try HSTSMiddleware.configured(testing: false) { _ in nil }?.maxAge == 31_536_000)
        #expect(try HSTSMiddleware.configured(testing: true) { _ in nil } == nil)
    }

    @Test("Invalid HSTS max-age fails startup", arguments: ["-1", "1.5", "+5", ""])
    func invalidMaxAge(value: String) {
        expectError("Invalid HSTS_MAX_AGE_SECONDS") {
            _ = try HSTSMiddleware.configured(testing: false) { ["HSTS_MAX_AGE_SECONDS": value][$0] }
        }
    }

    @Test("Incomplete or unreadable TLS files fail startup without leaking contents")
    func invalidServerTLS() async throws {
        let (cert, key) = try fixturePaths()
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try Data("not a pem secret".utf8).write(to: URL(fileURLWithPath: garbage))
        defer { try? FileManager.default.removeItem(atPath: garbage) }
        let cases: [([String: String], String)] = [
            (["HTTP_TLS_CERT_FILE": cert], "Missing HTTP_TLS_KEY_FILE"),
            (["HTTP_TLS_KEY_FILE": key], "Missing HTTP_TLS_CERT_FILE"),
            (["HTTP_TLS_CERT_FILE": garbage, "HTTP_TLS_KEY_FILE": key], "Invalid HTTP_TLS_CERT_FILE"),
            (["HTTP_TLS_CERT_FILE": cert, "HTTP_TLS_KEY_FILE": garbage], "Invalid HTTP_TLS_KEY_FILE"),
        ]
        try await withApplication(.testing) { app in
            for (values, message) in cases {
                expectError(message) { try configureServerTLS(app) { values[$0] } }
            }
            try configureServerTLS(app) { _ in nil }
            #expect(app.http.server.configuration.tlsConfiguration == nil)
        }
    }

    @Test("In-process HTTPS serves health, refuses plain HTTP, and identity provider keys need a matching hostname")
    func servedTLS() async throws {
        let (cert, key) = try fixturePaths()
        let signingKey = try ES256PrivateKey(backing: P256.Signing.PrivateKey())
        let coordinates = try #require(signingKey.parameters)
        let jwks = try JSONEncoder().encode(JWKS(keys: [.ecdsa(.es256, identifier: "k", x: coordinates.x, y: coordinates.y, curve: .p256)]))
        let roots = try NIOSSLCertificate.fromPEMFile(cert)

        try await withApplication(.testing) { server in
            let files = ["HTTP_TLS_CERT_FILE": cert, "HTTP_TLS_KEY_FILE": key]
            try await configure(server) { files[$0] ?? Environment.get($0) }
            server.get("jwks") { _ in Response(body: .init(data: jwks)) }
            // The fixture certificate names receiver.example, not 127.0.0.1. The server's own client
            // skips only the hostname check, which isolates what the second application must refuse.
            server.http.client.configuration.tlsConfiguration = clientTLS(roots, verification: .noHostnameVerification)
            try await server.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try #require(server.http.server.shared.localAddress?.port)
            let base = "127.0.0.1:\(port)"

            #expect(try await server.client.get("https://\(base)/health").status == .ok)
            await #expect(throws: (any Error).self) {
                _ = try await server.client.get("http://\(base)/health") { $0.timeout = .seconds(5) }
            }
            server.initializeSigningKeyState()
            await JWKSRefresher { try await fetchJWKS(server.client, from: "https://\(base)/jwks") }.refresh(server)
            #expect(server.signingKeysLoaded)

            try await withApplication(.testing) { app in
                let capture = CapturingLogHandler()
                app.logger = Logger(label: "jwks") { _ in capture }
                app.http.client.configuration.tlsConfiguration = clientTLS(roots, verification: .fullVerification)
                app.initializeSigningKeyState()
                await JWKSRefresher { try await fetchJWKS(app.client, from: "https://\(base)/jwks") }.refresh(app)
                #expect(!app.signingKeysLoaded)
                #expect(capture.lines.last?.contains("failedToValidateHostname") == true)
            }
            await server.server.shutdown()
        }
    }

    @Test("Identity provider URLs must use https outside testing")
    func identityProviderTransport() async throws {
        let base = [
            "OIDC_ISSUER": "https://idp.example", "OIDC_AUDIENCE": "open-erp",
            "OIDC_USERINFO_URL": "https://idp.example/userinfo", "OIDC_JWKS_URL": "https://idp.example/jwks",
        ]
        let refused: [([String: String], String)] = [
            (["OIDC_JWKS_URL": "http://idp.example/jwks"], "Invalid OIDC_JWKS_URL"),
            (["OIDC_USERINFO_URL": "http://idp.example/userinfo"], "Invalid OIDC_USERINFO_URL"),
            (["OIDC_JWKS_URL": "idp.example/jwks"], "Invalid OIDC_JWKS_URL"),
            (["OIDC_JWKS_URL": "http://idp.example/jwks", "OIDC_ALLOW_INSECURE_HTTP": "false"], "Invalid OIDC_JWKS_URL"),
            (["OIDC_ALLOW_INSECURE_HTTP": "yes"], "Invalid OIDC_ALLOW_INSECURE_HTTP"),
        ]
        for (overrides, message) in refused {
            try await withApplication(.production) { app in
                await expectError(message) {
                    try await configureAuthentication(app) { overrides[$0] ?? base[$0] }
                }
            }
        }
        try await withApplication(.production) { app in
            let capture = CapturingLogHandler()
            app.logger = Logger(label: "oidc") { _ in capture }
            let optOut = ["OIDC_JWKS_URL": "http://idp.example/jwks", "OIDC_ALLOW_INSECURE_HTTP": "true"]
            try await configureAuthentication(app) { optOut[$0] ?? base[$0] }
            #expect(capture.lines.contains { $0.contains("not encrypted") && $0.contains("OIDC_JWKS_URL") && !$0.contains("OIDC_USERINFO_URL") })
        }
    }

    @Test("Operational commands read no identity provider or server TLS settings")
    func operationalCommands() async throws {
        let database = [
            "DATABASE_HOST": "database.example", "DATABASE_USERNAME": "app",
            "DATABASE_PASSWORD": "unused", "DATABASE_NAME": "erp", "DATABASE_TLS_MODE": "disable",
        ]
        var read: [String] = []
        try await withApplication(.production) { app in
            try await configure(app, serving: false) { name in
                read.append(name)
                return database[name]
            }
        }
        #expect(!read.isEmpty)
        #expect(!read.contains { $0.hasPrefix("OIDC_") || $0.hasPrefix("HTTP_TLS_") })
    }

    private func fixturePaths() throws -> (cert: String, key: String) {
        let cert = try #require(Bundle.module.url(forResource: "receiver-cert", withExtension: "pem", subdirectory: "Webhooks"))
        let key = try #require(Bundle.module.url(forResource: "receiver-key", withExtension: "pem", subdirectory: "Webhooks"))
        return (cert.path, key.path)
    }

    private func clientTLS(_ roots: [NIOSSLCertificate], verification: CertificateVerification) -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = .certificates(roots)
        configuration.certificateVerification = verification
        return configuration
    }

    private func expectError(_ message: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("Expected \(message)")
        } catch {
            #expect(String(describing: error) == message)
        }
    }

    private func expectError(_ message: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("Expected \(message)")
        } catch {
            #expect(String(describing: error) == message)
        }
    }

    private func withApplication(_ environment: Environment, _ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(environment)
        do {
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
