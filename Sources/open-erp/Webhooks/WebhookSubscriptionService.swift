import Fluent
import Foundation
import SQLKit
import Vapor

enum WebhookDestination {
    static func validate(_ value: String) throws -> URLComponents {
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
            let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty, host.count <= 253,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            url.port == nil || url.port == 443, url.url != nil,
            host.contains("."), !host.allSatisfy({ $0.isNumber || $0 == "." }),
            host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            })
        else { throw Abort(.badRequest, reason: "url must be HTTPS on port 443 with a hostname and no credentials, query or fragment") }
        return url
    }
}

enum WebhookSubscriptionService {
    static func require(_ id: UUID, organizationID: UUID, lock: Bool = false, on db: any Database) async throws -> (WebhookSubscription, WebhookSubscriptionRevision) {
        if lock {
            _ = try await db.requireSQL().raw("SELECT id FROM webhook_subscriptions WHERE id = \(bind: id) AND organization_id = \(bind: organizationID) AND deleted_at IS NULL FOR NO KEY UPDATE").all()
        }
        guard let subscription = try await WebhookSubscription.query(on: db).filter(\.$id == id)
            .filter(\.$organization.$id == organizationID).first(),
            let revision = try await WebhookSubscriptionRevision.find(subscription.currentRevisionID, on: db)
        else { throw Abort(.notFound) }
        return (subscription, revision)
    }

    static func validate(_ config: WebhookConfiguration, organizationID: UUID, on db: any Database) async throws {
        guard (1...100).contains(config.name.count), !config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "name must be 1–100 characters")
        }
        _ = try WebhookDestination.validate(config.url)
        guard !config.eventTypes.isEmpty else { throw Abort(.badRequest, reason: "eventTypes must not be empty") }
        let companies = Set(config.companyIds)
        if !companies.isEmpty {
            guard config.eventTypes.allSatisfy(\.supportsCompanyFilter) else {
                throw Abort(.badRequest, reason: "companyIds requires eventTypes with company context")
            }
            let count = try await Company.query(on: db, organizationID: organizationID).filter(\.$id ~~ Array(companies)).count()
            guard count == companies.count else { throw Abort(.badRequest, reason: "companyIds must reference active companies in this organization") }
        }
    }

    static func authorize(_ config: WebhookConfiguration, payloadRequired: Bool, requesterID: UUID, organizationID: UUID, permission: Permission, on db: any Database) async throws {
        let permissions = try await loadPermissions(userID: requesterID, organizationID: organizationID, on: db)
        let required = Set(config.eventTypes.map(\.sourceReadPermission)).union([permission])
            .union(payloadRequired ? [.webhookPayloadRead] : [])
        guard required.isSubset(of: permissions) else { throw Abort(.forbidden, reason: "Missing required webhook management, source-read or payload permission") }
    }

    static func create(_ config: WebhookConfiguration, organizationID: UUID, actorID: UUID, on db: any Database) async throws -> WebhookSubscriptionDTO {
        let id = UUID(), revisionID = UUID()
        let now = try await transactionTime(on: db)
        let subscription = WebhookSubscription()
        subscription.id = id
        subscription.$organization.id = organizationID
        subscription.currentRevisionID = revisionID
        subscription.createdBy = actorID
        subscription.createdAt = now
        subscription.updatedAt = now
        try await subscription.create(on: db)
        var config = config
        config.enabled = false
        let revision = try await append(config, to: subscription, prior: nil, rotate: true, actorID: actorID, on: db)
        return try .init(subscription, revision: revision)
    }

    static func append(_ config: WebhookConfiguration, to subscription: WebhookSubscription, prior: WebhookSubscriptionRevision?, rotate: Bool, actorID: UUID, on db: any Database) async throws -> WebhookSubscriptionRevision {
        let revision = WebhookSubscriptionRevision()
        revision.id = subscription.currentRevisionID
        revision.$organization.id = subscription.$organization.id
        revision.$subscription.id = try subscription.requireID()
        revision.name = config.name
        revision.url = config.url
        revision.eventTypes = Array(Set(config.eventTypes)).sorted { $0.rawValue < $1.rawValue }
        revision.companyIDs = Array(Set(config.companyIds)).sorted { $0.uuidString < $1.uuidString }
        revision.enabled = config.enabled
        revision.schemaVersion = 1
        revision.version = (prior?.version ?? 0) + 1
        if rotate || prior == nil {
            revision.secretID = UUID()
            revision.secretCiphertext = try WebhookEncryptionKey.load().encrypt(WebhookSigningSecret(), organizationID: subscription.$organization.id,
                subscriptionID: subscription.requireID(), secretID: revision.secretID)
        } else if let prior {
            revision.secretID = prior.secretID
            revision.secretCiphertext = prior.secretCiphertext
        }
        let metadata = try await db.requireSQL().raw("SELECT txid_current() AS transaction_id, nextval('webhook_capture_order') AS capture_order, NULLIF(current_setting('audit.context', true), '')::jsonb ->> 'approval_request_id' AS approval_request_id").first()
        guard let metadata else { throw BusinessEventWriter.InvalidTransaction() }
        revision.transactionID = try metadata.decode(column: "transaction_id", as: Int64.self)
        revision.captureOrder = try metadata.decode(column: "capture_order", as: Int64.self)
        revision.approvalRequestID = try metadata.decode(column: "approval_request_id", as: String?.self).flatMap(UUID.init(uuidString:))
        revision.createdBy = actorID
        revision.createdAt = try await transactionTime(on: db)
        try await revision.create(on: db)
        return revision
    }

    static func transactionTime(on db: any Database) async throws -> Date {
        guard let row = try await db.requireSQL().raw("SELECT transaction_timestamp() AS time").first() else { throw BusinessEventWriter.InvalidTransaction() }
        return try row.decode(column: "time", as: Date.self)
    }
}
