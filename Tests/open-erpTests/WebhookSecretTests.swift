@testable import open_erp
import Crypto
import Foundation
import Testing

@Suite("Webhook secret binding")
struct WebhookSecretTests {
    @Test("Standard Webhooks reference known-answer vectors preserve exact bytes")
    func referenceSignatures() throws {
        // https://github.com/standard-webhooks/standard-webhooks/blob/main/libraries/python/tests/test_webhooks.py
        let key = try #require(Data(base64Encoded: "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"))
        let id = "msg_p5jXN8AQM9LWM0D4loKWxJek"
        let body = Data(#"{"test": 2432232314}"#.utf8)
        #expect(StandardWebhookSignature.sign(key: key, eventID: id, timestamp: 1614265330, body: body) == "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
        let binary = Data((0...255).map(UInt8.init))
        #expect(StandardWebhookSignature.sign(key: key, eventID: id, timestamp: 1614265330, body: binary) == "v1,sEcZ042G8Crqgxbybb3y0eDxQR3TcfYsk11I1XULhSI=")
        #expect(StandardWebhookSignature.sign(key: key, eventID: id, timestamp: 1614265331, body: body) != StandardWebhookSignature.sign(key: key, eventID: id, timestamp: 1614265330, body: body))
        #expect(StandardWebhookSignature.sign(key: key, eventID: id, timestamp: 1614265330, body: body + Data([10])) != StandardWebhookSignature.sign(key: key, eventID: id, timestamp: 1614265330, body: body))
    }
    @Test("Configuration errors name only the variable", arguments: [nil, "", "private-value", Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 1, count: 33).base64EncodedString()])
    func invalidKey(value: String?) {
        #expect(throws: WebhookEncryptionKey.InvalidConfiguration.self) { try WebhookEncryptionKey(base64: value) }
    }

    @Test("AES-GCM authenticates tenant, subscription, secret identity and ciphertext")
    func authenticatedStorage() throws {
        let key = try WebhookEncryptionKey(base64: Data(repeating: 7, count: 32).base64EncodedString())
        let secret = WebhookSigningSecret(), organizationID = UUID(), subscriptionID = UUID(), secretID = UUID()
        let ciphertext = try key.encrypt(secret, organizationID: organizationID, subscriptionID: subscriptionID, secretID: secretID)
        #expect(try key.decrypt(ciphertext, organizationID: organizationID, subscriptionID: subscriptionID, secretID: secretID).disclosedValue == secret.disclosedValue)
        #expect(secret.disclosedValue.hasPrefix("whsec_"))
        #expect(Data(base64Encoded: String(secret.disclosedValue.dropFirst(6)))?.count == 32)
        for (organization, subscription, id) in [(UUID(), subscriptionID, secretID), (organizationID, UUID(), secretID), (organizationID, subscriptionID, UUID())] {
            #expect(throws: WebhookEncryptionKey.InvalidSecret.self) {
                try key.decrypt(ciphertext, organizationID: organization, subscriptionID: subscription, secretID: id)
            }
        }
        var tampered = ciphertext
        tampered[tampered.startIndex] ^= 1
        #expect(throws: WebhookEncryptionKey.InvalidSecret.self) {
            try key.decrypt(tampered, organizationID: organizationID, subscriptionID: subscriptionID, secretID: secretID)
        }
        #expect(!String(describing: key).contains("BwcH"))
        #expect(!String(describing: secret).contains(secret.disclosedValue))
    }
}
