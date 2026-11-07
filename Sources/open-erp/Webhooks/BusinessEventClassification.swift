/// Each audited table is classified deliberately. Aggregate detail writes publish at the owning
/// semantic operation; attribution saves and held invitation preparation never publish separately.
enum BusinessEventClassification {
    static let eventResourcesByTable: [String: BusinessResourceType] = [
        "organizations": .organization, "companies": .company, "roles": .role, "groups": .group,
        "group_members": .groupMember, "group_roles": .groupRole, "group_companies": .groupCompany,
        "organization_users": .organizationUser, "organization_invitations": .invitation,
        "approval_policies": .approvalPolicy, "approval_requests": .approvalRequest,
        "approval_decisions": .approvalRequest,
    ]
    static let nonEventReasonsByTable: [String: String] = [
        "users": "Global identity and profile data are not public business events",
        "company_users": "Company membership has no supported public mutation operation in v1",
        "revoked_access_tokens": "Global authentication credentials",
        "organization_restorations": "Restoration evidence; the operation emits organization.restored",
        "role_permissions": "Aggregate detail; role operations emit one role event",
        "approval_policy_slots": "Aggregate detail; policy operations emit one policy event",
        "approval_policy_versions": "Immutable policy evidence; no separate public transition",
        "approval_request_tracks": "Internal approval progression; decisions and outcomes are the public contract",
        "business_event_streams": "Internal revision allocation",
        "business_events": "Public event evidence must not publish recursively",
        "business_event_dispatches": "Operational fan-out queue",
        "webhook_subscriptions": "Integration authority; no public event in the v1 catalog",
        "webhook_subscription_revisions": "Integration authority evidence",
        "webhook_secret_reveals": "Secret disclosure evidence",
        "webhook_deliveries": "Internal delivery scheduling",
        "webhook_delivery_entries": "Internal delivery evidence",
    ]
}
