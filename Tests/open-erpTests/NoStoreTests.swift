@testable import open_erp
import Testing
import VaporTesting

@Suite("Response cache policy")
struct NoStoreTests {
    @Test("Global policy covers documentation and errors and replaces competing cache headers")
    func responsePolicy() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            app.get("cacheable") { _ in
                Response(headers: ["Cache-Control": "public, max-age=3600"])
            }
            app.get("failure") { _ -> HTTPStatus in
                throw Abort(.internalServerError, headers: ["Cache-Control": "public"])
            }
            let cases: [(String, HTTPStatus)] = [
                ("docs", .ok), ("openapi.json", .ok), ("unknown-route", .notFound),
                ("me", .unauthorized), ("cacheable", .ok), ("failure", .internalServerError),
            ]
            for (path, status) in cases {
                try await app.testing().test(.GET, path, afterResponse: { response in
                    #expect(response.status == status)
                    #expect(response.headers[.cacheControl] == ["no-store"])
                })
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
