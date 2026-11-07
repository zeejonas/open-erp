import Crypto
import Foundation
import Vapor

struct WebhookEncryptionKey: Sendable, CustomStringConvertible {
    static let variable = "WEBHOOK_KEY_ENCRYPTION_KEY"
    private let material: Data
    var description: String { "WebhookEncryptionKey([redacted])" }

    struct InvalidConfiguration: Error, CustomStringConvertible {
        var description: String { "Missing or invalid WEBHOOK_KEY_ENCRYPTION_KEY" }
    }
    struct InvalidSecret: Error, CustomStringConvertible {
        var description: String { "Webhook signing secret unavailable" }
    }

    init(base64: String?) throws {
        guard let base64, let bytes = Data(base64Encoded: base64), bytes.count == 32 else { throw InvalidConfiguration() }
        material = bytes
    }

    static func load() throws -> Self { try Self(base64: Environment.get(variable)) }

    func encrypt(_ secret: WebhookSigningSecret, organizationID: UUID, subscriptionID: UUID, secretID: UUID) throws -> Data {
        guard let combined = try AES.GCM.seal(secret.bytes, using: SymmetricKey(data: material),
            authenticating: binding(organizationID, subscriptionID, secretID)).combined else { throw InvalidSecret() }
        return combined
    }

    func decrypt(_ ciphertext: Data, organizationID: UUID, subscriptionID: UUID, secretID: UUID) throws -> WebhookSigningSecret {
        do {
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: material),
                authenticating: binding(organizationID, subscriptionID, secretID))
            return try WebhookSigningSecret(bytes: bytes)
        } catch { throw InvalidSecret() }
    }

    private func binding(_ organization: UUID, _ subscription: UUID, _ secret: UUID) -> Data {
        Data("open-erp.webhook.v1.\(organization).\(subscription).\(secret)".utf8)
    }
}

struct WebhookSigningSecret: Sendable, CustomStringConvertible {
    fileprivate let bytes: Data
    var description: String { "WebhookSigningSecret([redacted])" }
    var disclosedValue: String { "whsec_" + bytes.base64EncodedString() }

    init() { bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    init(bytes: Data) throws {
        guard bytes.count == 32 else { throw WebhookEncryptionKey.InvalidSecret() }
        self.bytes = bytes
    }

    /// Standard Webhooks v1 signs retained bytes, never a decoded/re-encoded body.
    func signature(eventID: String, timestamp: Int64, body: Data) -> String {
        StandardWebhookSignature.sign(key: bytes, eventID: eventID, timestamp: timestamp, body: body)
    }
}

enum StandardWebhookSignature {
    static func sign(key: Data, eventID: String, timestamp: Int64, body: Data) -> String {
        var signed = Data("\(eventID).\(timestamp).".utf8)
        signed.append(body)
        let digest = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: key))
        return "v1," + Data(digest).base64EncodedString()
    }
}

private struct WebhookEncryptionKeyStorage: StorageKey { typealias Value = WebhookEncryptionKey }
extension Application {
    var webhookEncryptionKey: WebhookEncryptionKey? {
        get { storage[WebhookEncryptionKeyStorage.self] }
        set { storage[WebhookEncryptionKeyStorage.self] = newValue }
    }
}
