@testable import open_erp
import Logging
import Testing
import VaporTesting

@Suite("Problem details")
struct ProblemTests {
    @Test("Status fallbacks preserve headers and wording; internal details are logged but never returned")
    func statusFallbacks() async throws {
        for environment in [Environment.testing, .development, .production] {
            let app = try await Application.make(environment)
            do {
                configureProblemMiddleware(app)
                let capture = CapturingLogHandler()
                app.logger = Logger(label: "problems") { _ in capture }
                app.logger.logLevel = .warning
                let cases: [(HTTPStatus, ProblemCode)] = [
                    (.badRequest, .badRequest), (.unauthorized, .unauthorized), (.forbidden, .forbidden),
                    (.notFound, .notFound), (.conflict, .conflict), (.payloadTooLarge, .payloadTooLarge),
                    (.unsupportedMediaType, .unsupportedMediaType), (.tooManyRequests, .tooManyRequests),
                    (.unprocessableEntity, .httpError), (.internalServerError, .internalError), (.badGateway, .internalError),
                ]
                for (status, _) in cases {
                    app.get("failure", "\(status.code)") { _ -> HTTPStatus in
                        throw Abort(status, headers: ["Retry-After": "60", "X-Test": "preserved"], reason: "private diagnostic")
                    }
                }
                struct InternalFailure: Error {}
                app.get("internal") { _ -> HTTPStatus in throw InternalFailure() }
                app.get("challenge") { _ -> HTTPStatus in
                    throw Abort(.unauthorized, headers: ["WWW-Authenticate": "Bearer realm=\"api\""])
                }
                for (status, code) in cases {
                    try await app.testing().test(.GET, "failure/\(status.code)", afterResponse: { res async throws in
                        let problem = try checkProblem(res, status: status, code: code)
                        #expect(problem.detail == (status.code >= 500 ? "Something went wrong." : "private diagnostic"))
                        #expect(res.headers.first(name: "Retry-After") == "60")
                        #expect(res.headers.first(name: "X-Test") == "preserved")
                        if status == .unauthorized { #expect(res.headers[.wwwAuthenticate] == ["Bearer"]) }
                    })
                    // Client error reasons stay out of logs; server error diagnostics stay in them.
                    #expect(capture.lines.last?.contains("private diagnostic") == (status.code >= 500))
                }
                try await app.testing().test(.GET, "internal", afterResponse: { res async throws in
                    #expect(try checkProblem(res, status: .internalServerError, code: .internalError).detail == "Something went wrong.")
                })
                #expect(capture.lines.last?.contains("InternalFailure") == true)
                try await app.testing().test(.GET, "challenge", afterResponse: { res async throws in
                    _ = try checkProblem(res, status: .unauthorized, code: .unauthorized)
                    #expect(res.headers[.wwwAuthenticate] == ["Bearer realm=\"api\""])
                })
                try await app.testing().test(.GET, "missing", afterResponse: { res async throws in
                    _ = try checkProblem(res, status: .notFound, code: .notFound)
                })
            } catch {
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    @Test("Verification failures and missing tokens are challenged and logged once without credentials")
    func authenticationFailures() async throws {
        let app = try await Application.make(.testing)
        do {
            configureProblemMiddleware(app)
            try await configureAuthentication(app)
            let capture = CapturingLogHandler()
            app.logger = Logger(label: "problems") { _ in capture }
            app.logger.logLevel = .warning
            app.get("verify") { req async throws -> HTTPStatus in
                _ = try await req.verifiedAccessToken()
                return .ok
            }
            let tokens: [String?] = [
                nil, "submitted-secret",
                try await signAccessToken(on: app, subject: "ada", untrustedKey: true),
                try await signAccessToken(on: app, subject: "ada", issuer: "https://wrong.example"),
                try await signAccessToken(on: app, subject: "ada", audience: "wrong"),
                try await signAccessToken(on: app, subject: "ada", expiration: .distantPast),
            ]
            for (index, token) in tokens.enumerated() {
                try await app.testing().test(.GET, "verify?token=submitted-secret", beforeRequest: { req in
                    if let token { authorize(&req, token: token) }
                }, afterResponse: { res async throws in
                    _ = try checkProblem(res, status: .unauthorized, code: token == nil ? .unauthorized : .invalidAccessToken)
                    #expect(res.headers[.wwwAuthenticate] == [token == nil ? "Bearer" : #"Bearer error="invalid_token""#])
                    #expect(!res.body.string.contains("submitted-secret"))
                })
                #expect(capture.lines.count == index + 1)
            }
            #expect(!capture.lines.contains { $0.contains("submitted-secret") || $0.contains("https://wrong.example") })
            for token in tokens.compactMap({ $0 }) {
                #expect(!capture.lines.contains { $0.contains(token) })
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Validation identifies fields without echoing submitted values")
    func validation() async throws {
        let app = try await Application.make(.testing)
        do {
            configureProblemMiddleware(app)
            app.post("validate") { req -> HTTPStatus in
                try CreateCompanyDTO.validate(content: req)
                return .ok
            }
            try await app.testing().test(.POST, "validate", beforeRequest: { req in
                try req.content.encode(CreateCompanyDTO(code: "", name: "submitted-secret"))
            }, afterResponse: { res async throws in
                try expectBadRequest(res, naming: "code")
                #expect(!res.body.string.contains("submitted-secret"))
            })
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

@discardableResult
private func checkProblem(_ response: TestingHTTPResponse, status: HTTPStatus, code: ProblemCode) throws -> Problem {
    #expect(response.status == status)
    #expect(response.headers.contentType == .problemJSON)
    let problem = try response.content.decode(Problem.self, as: .json)
    #expect(problem.status == status.code)
    #expect(problem.code == code)
    #expect(problem.type == "urn:open-erp:problem:\(code.rawValue)")
    #expect(problem.title == status.reasonPhrase)
    return problem
}
