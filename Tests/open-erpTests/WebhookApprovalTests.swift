@testable import open_erp
import Fluent
import SQLKit
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Organization emergency shutdown retains the actual operator attribution")
    func webhookOperatorShutdownAttribution() async throws {
        try await withApp { app in
            let fixture = try await webhookDeliveryFixture(app)
            let tenant = fixture.tenant
            _ = try await app.db.auditedTransaction(AuditContext(actorType: .operator, actorName: "fixture operator")) { db in
                try await ProposedChange.organizationDelete(id: tenant.organizationID, before: .init(code: "WORKER", name: "WORKER"))
                    .apply(on: db, actorID: tenant.userID, organizationID: tenant.organizationID)
            }
            let subscription = try #require(try await WebhookSubscription.find(fixture.subscription.id, on: app.db))
            #expect(subscription.disabledActorType == .operator && subscription.disabledActorName == "fixture operator")
            #expect(subscription.disabledBy == nil)
        }
    }
    @Test("Held activation checks revisions, source authority, field policies and final-approval races")
    func webhookApprovals() async throws {
        try await withApp { app in
            let tenant = try await webhookTenant(app)
            let approver = try await createMember(on: app.db, organizationID: tenant.organizationID, email: "approver@example.com",
                subject: "approver", permissions: [.approvalRequestRead])
            let reviewer = WebhookTestTenant(organizationID: tenant.organizationID, userID: try approver.requireID(), token: try await signAccessToken(on: app, subject: "approver"))
            let group = try #require(try await AccessGroup.query(on: app.db, organizationID: tenant.organizationID).filter(\.$name == "permissions-approver@example.com").first())
            let create = try await webhookRequest(app, .POST, "webhook-subscriptions", tenant: tenant,
                body: CreateWebhookSubscriptionDTO(name: "Approval", url: "https://receiver.example", eventTypes: [.groupCreated], companyIds: []))
            let subscription = try create.content.decode(WebhookSubscriptionDTO.self)
            let definition = ApprovalPolicyDefinition(name: "Integration activation", permission: Permission.webhookSubscriptionUpdate.rawValue,
                fields: ["enabled"], companyId: nil, stages: [.init(slots: [.init(groupId: try group.requireID(), required: 1)])])
            _ = try await app.db.auditedTransaction(AuditContext(actorType: .user, actorID: tenant.userID)) { db in
                try await ProposedChange.approvalPolicyCreate(definition).apply(on: db, actorID: tenant.userID, organizationID: tenant.organizationID)
            }
            let heldResponse = try await webhookRequest(app, .PATCH, "webhook-subscriptions/\(subscription.id)", tenant: tenant,
                body: PatchWebhookSubscriptionDTO(expectedRevisionId: subscription.currentRevisionId, enabled: true))
            #expect(heldResponse.status == .accepted)
            let held = try heldResponse.content.decode(GetApprovalRequestDTO.self)
            #expect(try await WebhookSubscriptionRevision.query(on: app.db).count() == 1)
            #expect(!heldResponse.body.string.contains("whsec_") && !heldResponse.body.string.contains("ciphertext"))
            let nameResponse = try await webhookRequest(app, .PATCH, "webhook-subscriptions/\(subscription.id)", tenant: tenant,
                body: PatchWebhookSubscriptionDTO(expectedRevisionId: subscription.currentRevisionId, name: "New name"))
            #expect(nameResponse.status == .ok) // A name change does not match the enabled-field policy.
            var current = try nameResponse.content.decode(WebhookSubscriptionDTO.self)
            let stale = try await webhookRequest(app, .POST, "approval-requests/\(try #require(held.id))/approve", tenant: reviewer)
            #expect(try stale.content.decode(GetApprovalRequestDTO.self).status == "failed")
            #expect(try await WebhookSubscription.find(subscription.id, on: app.db)?.currentRevisionID == current.currentRevisionId)
            let enable = try await webhookRequest(app, .PATCH, "webhook-subscriptions/\(subscription.id)", tenant: tenant,
                body: PatchWebhookSubscriptionDTO(expectedRevisionId: current.currentRevisionId, enabled: true))
            let requestID = try #require(try enable.content.decode(GetApprovalRequestDTO.self).id)
            async let first = webhookRequest(app, .POST, "approval-requests/\(requestID)/approve", tenant: reviewer)
            async let second = webhookRequest(app, .POST, "approval-requests/\(requestID)/approve", tenant: reviewer)
            let results = try await [first, second]
            #expect(Set(results.map(\.status)) == [.ok, .conflict])
            #expect(try await WebhookSubscriptionRevision.query(on: app.db).count() == 3)
            let shown = try await webhookRequest(app, .GET, "webhook-subscriptions/\(subscription.id)", tenant: tenant)
            current = try shown.content.decode(WebhookSubscriptionDTO.self)
            #expect(current.enabled)
            // Disable bypasses the ordinary enabled-field approval policy.
            #expect(try await webhookRequest(app, .POST, "webhook-subscriptions/\(subscription.id)/disable", tenant: tenant).status == .noContent)
            let again = try await webhookRequest(app, .PATCH, "webhook-subscriptions/\(subscription.id)", tenant: tenant,
                body: PatchWebhookSubscriptionDTO(expectedRevisionId: current.currentRevisionId, enabled: true))
            let lostRequest = try #require(try again.content.decode(GetApprovalRequestDTO.self).id)
            try await app.db.requireSQL().raw("UPDATE role_permissions SET deleted_at = now() WHERE organization_id = \(bind: tenant.organizationID) AND permission = 'webhook_payload:read'").run()
            let lost = try await webhookRequest(app, .POST, "approval-requests/\(lostRequest)/approve", tenant: reviewer)
            #expect(try lost.content.decode(GetApprovalRequestDTO.self).status == "failed")
            #expect(try await WebhookSubscription.find(subscription.id, on: app.db)?.disabledReason == .emergency)
            // Held mutation serialization contains configuration and preconditions, never generated secrets.
            let json = try JSONEncoder().encode(held.change)
            #expect(try JSONDecoder().decode(ProposedChange.self, from: json) == held.change)
        }
    }

    @Test("URL changes cancel rather than redirect; name and rotation preserve authorized queued work")
    func webhookRevocation() async throws {
        try await withApp { app in
            let fixture = try await webhookDeliveryFixture(app, events: 2)
            let tenant = fixture.tenant
            var current = fixture.subscription
            let first = try #require(try await fixture.sender.claim(on: app.db))
            let name = try await webhookRequest(app, .PATCH, "webhook-subscriptions/\(current.id)", tenant: tenant,
                body: PatchWebhookSubscriptionDTO(expectedRevisionId: current.currentRevisionId, name: "Renamed", rotateSecret: true))
            current = try name.content.decode(WebhookSubscriptionDTO.self)
            #expect(try await WebhookDelivery.query(on: app.db).filter(\.$state == .pending).count() == 1)
            let newSecret = try await webhookRequest(app, .POST, "webhook-subscriptions/\(current.id)/secret", tenant: tenant)
            let disclosed = try newSecret.content.decode(WebhookSecretDTO.self)
            let queued = try #require(try await fixture.sender.claim(on: app.db))
            #expect(queued.secretID == disclosed.secretId && queued.secretID != first.secretID)
            try await fixture.sender.send(queued, on: app.db) { _, body, headers in
                let secret = try #require(Data(base64Encoded: String(disclosed.secret.dropFirst(6))))
                let timestamp = try #require(headers.first(name: "webhook-timestamp").flatMap(Int64.init))
                #expect(headers.first(name: "webhook-signature") == StandardWebhookSignature.sign(key: secret,
                    eventID: queued.eventID.uuidString, timestamp: timestamp, body: body))
                return .init(status: 500, retryAfter: nil)
            }
            let url = try await webhookRequest(app, .PATCH, "webhook-subscriptions/\(current.id)", tenant: tenant,
                body: PatchWebhookSubscriptionDTO(expectedRevisionId: current.currentRevisionId, url: "https://other.example/events"))
            #expect(url.status == .ok)
            #expect(try await WebhookDelivery.find(queued.deliveryID, on: app.db)?.state == .cancelled)
            #expect(try await WebhookDelivery.find(first.deliveryID, on: app.db)?.state == .inFlight)
            try await fixture.sender.finish(first, outcome: .acknowledged, status: 200, on: app.db)
            #expect(try await WebhookDelivery.find(first.deliveryID, on: app.db)?.state == .acknowledged)
            #expect(try await WebhookDeliveryEntry.query(on: app.db).filter(\.$kind == .cancellation).count() == 1)
        }
    }

    @Test("Organization delete and restore never revive integrations or queued work")
    func webhookOrganizationLifecycle() async throws {
        try await withApp { app in
            let fixture = try await webhookDeliveryFixture(app, events: 2)
            let tenant = fixture.tenant
            #expect(try await webhookRequest(app, .DELETE, "organization", tenant: tenant).status == .noContent)
            #expect(try await WebhookDelivery.query(on: app.db).filter(\.$state == .cancelled).count() == 2)
            #expect(try await WebhookSubscription.find(fixture.subscription.id, on: app.db)?.disabledReason == .emergency)
            _ = try await createUser(on: app.db, email: "platform@example.com", subject: "platform", isPlatformAdmin: true)
            let token = try await signAccessToken(on: app, subject: "platform")
            let restored = try await app.testing().sendRequest(.POST, "platform/organizations/\(tenant.organizationID)/restore", beforeRequest: {
                authorize(&$0, token: token)
                try $0.content.encode(RestoreOrganizationDTO(reason: "Test restoration"))
            })
            #expect(restored.status == .ok)
            _ = try await WebhookDispatcher.dispatchBatch(on: app.db)
            #expect(try await WebhookDelivery.query(on: app.db).count() == 2)
            #expect(try await fixture.sender.claim(on: app.db) == nil)
            let state = try await webhookRequest(app, .GET, "webhook-subscriptions/\(fixture.subscription.id)", tenant: tenant)
            #expect(try state.content.decode(WebhookSubscriptionDTO.self).enabled == false)
        }
    }
}
