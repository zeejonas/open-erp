import Fluent
import Foundation

extension ProposedChange {
    func authorizeWebhook(requesterID: UUID, organizationID: UUID, on db: any Database) async throws {
        switch self {
        case .webhookSubscriptionCreate(let config):
            _ = try await lockOrganization(organizationID, on: db)
            try await WebhookSubscriptionService.authorize(config, payloadRequired: true, requesterID: requesterID,
                organizationID: organizationID, permission: .webhookSubscriptionCreate, on: db)
        case .webhookSubscriptionUpdate(_, _, let before, let after, _):
            _ = try await lockOrganization(organizationID, on: db)
            try await WebhookSubscriptionService.authorize(after, payloadRequired: after.expandsAuthority(from: before),
                requesterID: requesterID, organizationID: organizationID, permission: .webhookSubscriptionUpdate, on: db)
        default: break
        }
    }
}
