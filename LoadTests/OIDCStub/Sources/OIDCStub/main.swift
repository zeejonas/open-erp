import JWTKit
import Vapor

/// Minimal identity provider for the load-test harness: a published ES256 JWKS, token minting
/// for seeded subjects, and userinfo for invitation acceptance. A second key is never published,
/// so tokens it signs must be rejected.
struct Claims: JWTPayload {
    var iss: IssuerClaim
    var sub: SubjectClaim
    var aud: AudienceClaim
    var exp: ExpirationClaim
    var email: String

    func verify(using _: some JWTAlgorithm) throws {
        try exp.verifyNotExpired()
    }
}

struct UserInfo: Content {
    var sub: String
    var email: String
    var email_verified: Bool
}

struct TokenRequest: Content {
    var sub: String
    var email: String
    /// Negative values mint an already expired token.
    var expiresIn: Int?
    var unpublishedKey: Bool?
}

func base64URL(_ base64: String) -> String {
    base64.replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let issuer = Environment.get("OIDC_ISSUER") ?? "http://oidc-stub:8081"
let audience = Environment.get("OIDC_AUDIENCE") ?? "open-erp-loadtest"

let published = ES256PrivateKey()
let unpublished = ES256PrivateKey()
let publishedKID = JWKIdentifier(string: "loadtest-published")
let unpublishedKID = JWKIdentifier(string: "loadtest-unpublished")
let keys = await JWTKeyCollection()
    .add(ecdsa: published, kid: publishedKID)
    .add(ecdsa: unpublished, kid: unpublishedKID)

guard let parameters = published.parameters else { fatalError("Key has no public parameters") }
let jwks: [String: [[String: String]]] = ["keys": [[
    "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": publishedKID.string,
    "x": base64URL(parameters.x), "y": base64URL(parameters.y),
]]]

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = try await Application.make(env)

app.get(".well-known", "jwks.json") { _ in jwks }

app.post("token") { req async throws -> [String: String] in
    let body = try req.content.decode(TokenRequest.self)
    let claims = Claims(
        iss: .init(value: issuer),
        sub: .init(value: body.sub),
        aud: .init(value: [audience]),
        exp: .init(value: Date().addingTimeInterval(TimeInterval(body.expiresIn ?? 3600))),
        email: body.email
    )
    let kid = body.unpublishedKey == true ? unpublishedKID : publishedKID
    return ["access_token": try await keys.sign(claims, kid: kid)]
}

app.get("userinfo") { req async throws -> UserInfo in
    guard let bearer = req.headers.bearerAuthorization?.token,
          let claims = try? await keys.verify(bearer, as: Claims.self)
    else { throw Abort(.unauthorized) }
    return UserInfo(sub: claims.sub.value, email: claims.email, email_verified: true)
}

do {
    try await app.execute()
} catch {
    app.logger.report(error: error)
    try? await app.asyncShutdown()
    throw error
}
try await app.asyncShutdown()
