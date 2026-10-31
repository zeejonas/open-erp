import Fluent
import Foundation
import JWT
import SQLKit
import Vapor

/// Security state independent of ERP users and organizations. Never expose this model as Content.
final class RevokedAccessToken: Model, @unchecked Sendable {
    static let schema = "revoked_access_tokens"

    @ID(custom: "fingerprint", generatedBy: .user)
    var id: String?

    @Field(key: "issuer") var issuer: String
    @Field(key: "subject") var subject: String
    @Field(key: "expires_at") var expiresAt: Date
    @Field(key: "revoked_at") var revokedAt: Date

    init() {}

    init(bearer: String, claims: AccessToken, revokedAt: Date = Date()) {
        id = Self.fingerprint(bearer)
        issuer = claims.issuer.value
        subject = claims.subjectID
        expiresAt = claims.expiration.value
        self.revokedAt = revokedAt
    }

    /// Hashes the signed `header.payload`, not the signature: unused base64url bits and ECDSA `(r, n − s)`
    /// let many signature encodings verify as the same token.
    static func fingerprint(_ bearer: String) -> String {
        sha256Hex(bearer[..<(bearer.lastIndex(of: ".") ?? bearer.endIndex)])
    }

    /// Ignores only a fingerprint conflict. RETURNING distinguishes the first committed insert
    /// from retries without updating its original evidence.
    func insertIfAbsent(on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        let rows = try await sql.insert(into: Self.schema)
            .columns("fingerprint", "issuer", "subject", "expires_at", "revoked_at")
            .values(SQLBind(try requireID()), SQLBind(issuer), SQLBind(subject), SQLBind(expiresAt), SQLBind(revokedAt))
            .ignoringConflicts(with: "fingerprint")
            .returning("revoked_at")
            .all()
        return !rows.isEmpty
    }
}
