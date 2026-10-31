import Fluent
import Vapor
import VaporToOpenAPI

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("auth", "logout", use: self.logout)
            .openAPI(
                summary: "Log out this ERP access token",
                description: "Revokes only the presented bearer token at this ERP. No body, query parameters, or X-Organization-ID. Repeated logout of a valid token is idempotent; provider refresh and SSO cleanup are separate operations.",
                responseDescription: "Revocation committed",
                statusCode: 204,
                auth: .bearer()
            )
            .problemResponses(.badRequest, excluding: [.forbidden])
    }

    /// Accepts an already revoked token and needs no user binding, so invitation recipients
    /// and removed users can revoke their tokens.
    @Sendable
    func logout(req: Request) async throws -> HTTPStatus {
        guard (req.body.data?.readableBytes ?? 0) == 0, req.url.query == nil,
              !req.headers.contains(name: OrganizationMiddleware.headerName) else {
            throw Abort(.badRequest, reason: "Logout accepts only the Authorization Bearer token, without a body, query, or tenant selector.")
        }
        let (bearer, token) = try await req.verifiedAccessTokenIgnoringRevocation()
        let record = RevokedAccessToken(bearer: bearer, claims: token)
        let inserted: Bool
        do {
            inserted = try await record.insertIfAbsent(on: req.db)
        } catch {
            // Never expose database errors, which can contain credential fingerprints.
            throw ProblemAbort(status: .serviceUnavailable, code: .authenticationUnavailable)
        }
        if inserted {
            req.logger.notice("Access token revoked", metadata: [
                "issuer": .string(record.issuer), "subject": .string(record.subject),
                "revoked_at": .string(record.revokedAt.ISO8601Format()),
            ])
        }
        return .noContent
    }
}
