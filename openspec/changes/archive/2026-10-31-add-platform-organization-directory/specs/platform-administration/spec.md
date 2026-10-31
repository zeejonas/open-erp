## ADDED Requirements

### Requirement: Platform organization directory
The system SHALL expose `GET /platform/organizations` only to authenticated platform administrators, without requiring `X-Organization-ID` or organization membership. It SHALL list non-deleted organizations in the standard `{items, metadata: {page, per, total}}` envelope. It SHALL accept `page` and `per` under list-endpoints rules, literal case-insensitive substring filters `code` and `name`, and boolean `onboarded`, decoded with Vapor's standard query boolean parsing, where true means `onboardedAt` is non-null. Filters SHALL combine with AND before counting and paging. It SHALL order by organization `updatedAt` descending, then ID ascending. Items SHALL expose ID, code, name, creation/update actor IDs and timestamps, and `onboardedAt`; they SHALL NOT expose invitation tokens, token hashes, tenant business data, or invitation history. Directory visibility SHALL NOT grant tenant access.

#### Scenario: Filter and page
- **WHEN** an authorized platform administrator requests `GET /platform/organizations?name=acme&onboarded=false&page=2&per=1`
- **THEN** only matching incomplete non-deleted organizations are counted and paged in the fixed order, without requiring a tenant header

#### Scenario: Literal filters and stable order
- **WHEN** matching organization names contain `%`, `_`, or backslash and several organizations share an update timestamp
- **THEN** these characters match literally and the ID tie-breaker yields no duplicates across pages while data is unchanged

#### Scenario: Empty page
- **WHEN** the requested page exceeds the matching organization count
- **THEN** the response is 200 with empty items and the actual matching total

#### Scenario: Strict filter contract
- **WHEN** a request uses `onboarded=yes`, `onboardedStatus=pending`, `onboardingStatus=expired`, an empty text filter, a repeated parameter, an invalid page/per, or a sort parameter
- **THEN** it returns 400 naming the invalid parameter rather than ignoring or reinterpreting it

#### Scenario: Unauthorized directory access
- **WHEN** no bearer token is supplied or a valid token belongs to a non-platform user
- **THEN** the response is 401 or 403 respectively, without organization metadata

#### Scenario: Directory grants no tenant authority
- **WHEN** a platform administrator can list an organization but has no membership in it and requests its tenant-scoped companies
- **THEN** tenant authorization still returns 403

### Requirement: Platform organization onboarding detail
The system SHALL expose `GET /platform/organizations/{organizationID}` only to authenticated platform administrators without a tenant selector. It SHALL return directory metadata, nullable `onboardingInvitation`, and nullable `onboardingIssue`. It SHALL select the non-deleted onboarding invitation, or otherwise the newest revoked onboarding invitation ordered by createdAt descending then ID descending. Invitation metadata SHALL include ID, recipient name/email, group ID, expiry, acceptance time, revocation time and creator ID, but SHALL NOT include tokens or hashes. For incomplete organizations, issue precedence SHALL be `accepted_without_completion` for any accepted onboarding history, `missing_onboarding_invitation` for absent lineage, then `original_group_unavailable` for a selected invitation without an active same-organization group; otherwise issue SHALL be null. Completed organizations SHALL have null issue. Reads SHALL NOT mutate history or change acceptance/reissue eligibility.

#### Scenario: Pending, expired, or revoked invitation
- **WHEN** an incomplete organization has trustworthy onboarding history and an active original group
- **THEN** completion remains null, issue is null, and invitation expiry/revocation facts distinguish its lifecycle without a combined unavailable status

#### Scenario: Accepted history without completion
- **WHEN** onboardedAt is null but any onboarding invitation was accepted, including a revoked historical row
- **THEN** issue is accepted_without_completion, and the response neither labels onboarding completed nor repairs the record

#### Scenario: Missing lineage or group
- **WHEN** incomplete onboarding has no invitation history, or has a selected invitation with a missing/deleted/foreign-organization group
- **THEN** issue is missing_onboarding_invitation or original_group_unavailable respectively, with no write

#### Scenario: Permanent completion
- **WHEN** onboardedAt exists and later membership or group changes have occurred
- **THEN** completion remains that timestamp and issue is null

#### Scenario: Invalid or unauthorized target
- **WHEN** an authorized administrator supplies a malformed UUID or targets a missing/deleted organization, or a non-platform user targets any organization
- **THEN** the response is 400, 404, or 403 respectively without disclosing protected metadata
