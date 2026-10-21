import JWT
import Vapor

/// Standard OIDC access-token claims. `iss` and `aud` depend on configuration,
/// so `Request.verifiedAccessToken()` checks them against `app.oidc`.
struct AccessToken: JWTPayload {
    var issuer: IssuerClaim
    var subject: SubjectClaim
    var audience: AudienceClaim
    var expiration: ExpirationClaim

    enum CodingKeys: String, CodingKey {
        case issuer = "iss"
        case subject = "sub"
        case audience = "aud"
        case expiration = "exp"
    }

    var subjectID: String { subject.value }

    func verify(using _: some JWTAlgorithm) async throws {
        try expiration.verifyNotExpired()
    }
}
