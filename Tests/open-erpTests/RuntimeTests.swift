@testable import open_erp
import Crypto
import Fluent
import FluentPostgresDriver
import Foundation
import JWT
import Logging
import Testing
import VaporTesting

struct RuntimeTests {
    @Test func missingServeConfiguration() async throws {
        try await withRuntimeApp(.production) { app in
            await #expect(throws: MissingEnvironmentVariable.self) {
                do {
                    try await configureAuthentication(app) { _ in nil }
                } catch {
                    #expect(String(describing: error) == "Missing OIDC_ISSUER")
                    throw error
                }
            }
        }
    }

    @Test func keyRotationAndFailures() async throws {
        try await withRuntimeApp { app in
            let oldKey = try ES256PrivateKey(backing: P256.Signing.PrivateKey())
            let newKey = try ES256PrivateKey(backing: P256.Signing.PrivateKey())
            let oldJWK = try jwk(oldKey, kid: "old")
            let newJWK = try jwk(newKey, kid: "new")
            let signer = JWTKeyCollection()
            await signer.add(ecdsa: oldKey, kid: "old")
            await signer.add(ecdsa: newKey, kid: "new")
            let token = AccessToken(issuer: "issuer", subject: "subject", audience: .init(value: "audience"), expiration: .init(value: .distantFuture))
            let oldToken = try await signer.sign(token, kid: "old")
            let newToken = try await signer.sign(token, kid: "new")

            app.initializeSigningKeyState()
            await JWKSRefresher { try encoded([oldJWK]) }.refresh(app)
            #expect(app.signingKeysLoaded)
            _ = try await app.jwt.keys.verify(oldToken, as: AccessToken.self)

            await JWKSRefresher { try encoded([oldJWK, newJWK]) }.refresh(app)
            _ = try await app.jwt.keys.verify(oldToken, as: AccessToken.self)
            _ = try await app.jwt.keys.verify(newToken, as: AccessToken.self)

            await JWKSRefresher { try encoded([newJWK]) }.refresh(app)
            await #expect(throws: JWTError.self) {
                _ = try await app.jwt.keys.verify(oldToken, as: AccessToken.self)
            }
            let retained = app.jwt.keys
            await JWKSRefresher { throw Abort(.badGateway) }.refresh(app)
            #expect(app.jwt.keys === retained)
            await JWKSRefresher { try encoded([]) }.refresh(app)
            #expect(app.jwt.keys === retained)
            await JWKSRefresher { try encoded([.rsa(.rsaOAEP, identifier: "encryption", modulus: nil, exponent: nil)]) }.refresh(app)
            #expect(app.jwt.keys === retained)
            _ = try await app.jwt.keys.verify(newToken, as: AccessToken.self)
        }
    }

    @Test func unusableEntriesDoNotBlockRotation() async throws {
        try await withRuntimeApp { app in
            let capture = CapturingLogHandler()
            app.logger = Logger(label: "runtime") { _ in capture }
            let oldKey = try ES256PrivateKey(backing: P256.Signing.PrivateKey())
            let newKey = try ES256PrivateKey(backing: P256.Signing.PrivateKey())
            let signer = JWTKeyCollection()
            await signer.add(ecdsa: oldKey, kid: "old")
            await signer.add(ecdsa: newKey, kid: "new")
            let token = AccessToken(issuer: "issuer", subject: "subject", audience: .init(value: "audience"), expiration: .init(value: .distantFuture))
            let oldToken = try await signer.sign(token, kid: "old")
            let newToken = try await signer.sign(token, kid: "new")
            let unusable = [
                #"{"kty":"RSA","alg":"RSA-OAEP-256","use":"enc","kid":"enc","n":"AQAB","e":"AQAB"}"#,
                #"{"kty":"oct","kid":"symmetric","k":"AQAB"}"#,
                #"{"kty":"EC","crv":"secp256k1","kid":"k1","x":"AQAB","y":"AQAB"}"#,
                String(decoding: try JSONEncoder().encode(JWK.rsa(.rs256, identifier: nil, modulus: "AQAB", exponent: "AQAB")), as: UTF8.self),
            ]
            func keySet(_ key: JWK) throws -> Data {
                let good = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
                return Data(#"{"keys":[\#((unusable + [good]).joined(separator: ","))]}"#.utf8)
            }
            let first = try keySet(try jwk(oldKey, kid: "old"))
            let second = try keySet(try jwk(newKey, kid: "new"))

            app.initializeSigningKeyState()
            await JWKSRefresher { first }.refresh(app)
            #expect(app.signingKeysLoaded)
            _ = try await app.jwt.keys.verify(oldToken, as: AccessToken.self)
            #expect(capture.lines.last == #"Ignored unusable JWKS entries ["ignored": 4]"#)

            await JWKSRefresher { second }.refresh(app)
            _ = try await app.jwt.keys.verify(newToken, as: AccessToken.self)
            await #expect(throws: JWTError.self) {
                _ = try await app.jwt.keys.verify(oldToken, as: AccessToken.self)
            }
        }
    }

    @Test func refreshFailuresLogTheirReason() async throws {
        try await withRuntimeApp { app in
            let capture = CapturingLogHandler()
            app.logger = Logger(label: "runtime") { _ in capture }
            app.initializeSigningKeyState()
            await JWKSRefresher { throw AuthenticationConfigurationError(message: "JWKS request returned status 404") }.refresh(app)
            #expect(capture.lines.last?.contains("status 404") == true)
            await JWKSRefresher { try encoded([]) }.refresh(app)
            #expect(capture.lines.last?.contains("no usable keys") == true)
            #expect(!app.signingKeysLoaded)
        }
    }

    @Test func requestsBeforeKeysLoad() async throws {
        try await withRuntimeApp { app in
            try configureAPI(app)
            for (method, path) in [(HTTPMethod.GET, "me"), (.POST, "auth/logout")] {
                try await app.testing().test(method, path, beforeRequest: { req in
                    authorize(&req, token: "bearer")
                }, afterResponse: { res async throws in
                    #expect(res.status == .serviceUnavailable)
                    #expect(try res.content.decode(Problem.self, as: .json).code == .authenticationUnavailable)
                    #expect(res.headers[.wwwAuthenticate].isEmpty)
                })
                try await app.testing().test(method, path, afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                    #expect(res.headers[.wwwAuthenticate] == ["Bearer"])
                })
            }
            let capture = CapturingLogHandler()
            app.logger = Logger(label: "runtime") { _ in capture }
            try await app.testing().test(.GET, "health", afterResponse: checkUnavailable)
            #expect(capture.lines.last?.contains("Signing keys are not loaded") == true)
            for path in ["/", "/hello"] {
                try await app.testing().test(.GET, path, afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                    #expect(try res.content.decode(Problem.self, as: .json).code == .notFound)
                })
            }
        }
    }

    @Test func readiness() async throws {
        try await withRuntimeApp { app in
            try await configure(app)
            for headers: HTTPHeaders in [[:], ["X-Organization-ID": UUID().uuidString]] {
                try await app.testing().test(.GET, "health", headers: headers, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(try res.content.decode([String: String].self) == ["status": "ok"])
                })
            }
        }
        try await withRuntimeApp { app in
            try configureAPI(app)
            try await configureAuthentication(app)
            app.databases.use(.postgres(configuration: .init(
                hostname: "127.0.0.1", port: 1, username: "unused", password: nil, database: nil, tls: .disable
            )), as: .psql)
            let capture = CapturingLogHandler()
            app.logger = Logger(label: "runtime") { _ in capture }
            try await app.testing().test(.GET, "health", afterResponse: checkUnavailable)
            #expect(capture.lines.last?.contains("Database probe failed: PSQLError code=") == true)
        }
    }

    private func checkUnavailable(_ res: TestingHTTPResponse) async throws {
        #expect(res.status == .serviceUnavailable)
        #expect(res.headers.contentType == .problemJSON)
        let problem = try res.content.decode(Problem.self, as: .json)
        #expect(problem.code == .internalError)
        #expect(problem.detail == "Something went wrong.")
    }

    private func encoded(_ keys: [JWK]) throws -> Data {
        try JSONEncoder().encode(JWKS(keys: keys))
    }

    private func jwk(_ key: ES256PrivateKey, kid: JWKIdentifier) throws -> JWK {
        let coordinates = try #require(key.parameters)
        return .ecdsa(.es256, identifier: kid, x: coordinates.x, y: coordinates.y, curve: .p256)
    }

    private func withRuntimeApp(
        _ environment: Environment = .testing,
        _ body: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(environment)
        app.webhookEncryptionKey = try WebhookEncryptionKey(base64: Data(repeating: 19, count: 32).base64EncodedString())
        do {
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
