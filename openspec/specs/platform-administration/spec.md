# platform-administration

## Purpose

Platform administrator bootstrap and organization provisioning, without implicit access to any tenant.

## Requirements

### Requirement: Platform administrator flag
The system SHALL store a non-null `is_platform_admin` boolean on users, defaulting to false. No HTTP endpoint SHALL be able to set or clear it.

#### Scenario: Flag not settable via API
- **WHEN** a user calls `PATCH /me` with `isPlatformAdmin: true`
- **THEN** the flag is unchanged

### Requirement: Platform administrator CLI
The system SHALL provide a `platform-admin` CLI command that, given an email, first name, last name, and OIDC subject, creates or updates the user, binds `auth_subject`, and sets `is_platform_admin` to true. With `--revoke`, it SHALL set the flag to false. The command SHALL log each grant and revocation.

#### Scenario: Bootstrap first platform admin
- **WHEN** an operator runs `platform-admin` with an email and subject not yet in the system
- **THEN** a user is created with that email, bound to that subject, and flagged as platform admin

#### Scenario: Revoke
- **WHEN** an operator runs `platform-admin --revoke` for an existing platform admin
- **THEN** the user's flag is set to false and their next provisioning request responds `403 Forbidden`

#### Scenario: Subject conflict
- **WHEN** the email exists bound to a different subject
- **THEN** the command fails without changes

### Requirement: Organization provisioning
The system SHALL expose `POST /platform/organizations`, available only to authenticated platform administrators, which in one transaction creates the organization, copies all role templates and group templates into it, and creates an invitation for the first administrator into the "Organization Administrators" group. The response SHALL retain the organization and invitationToken fields and additionally include invitation metadata (ID, recipient, and expiry). The initial invitation SHALL be explicitly marked as onboarding. Token-bearing responses SHALL set Cache-Control: no-store. The documented operation summary SHALL be “Create organization.”

#### Scenario: Provision organization
- **WHEN** a platform admin provisions "Acme LLC" with first admin `cfo@acme.com`
- **THEN** the organization, its template roles and groups, and an invitation for `cfo@acme.com` into the Organization Administrators group exist, and the token is returned

#### Scenario: First administrator holds every organization permission
- **WHEN** `cfo@acme.com` accepts the provisioning invitation
- **THEN** they belong to Organization Administrators and hold every organization-level permission

#### Scenario: Non-admin provisioning
- **WHEN** a user without the flag calls `POST /platform/organizations`
- **THEN** the system responds `403 Forbidden` and nothing is created

#### Scenario: Provisioning failure is atomic
- **WHEN** any step of provisioning fails
- **THEN** no organization, role, group, or invitation is persisted

### Requirement: One-time invitation token disclosure
Provisioning and administrator invitation reissue SHALL return the invitation token only in the response that creates it. The system SHALL persist only its hash and SHALL NOT expose an API to retrieve the original token later. Recovering a lost token SHALL require reissue, which invalidates the previous token.

#### Scenario: Lost provisioning or reissue response
- **WHEN** a platform administrator loses the response containing an invitation token
- **THEN** the original token cannot be retrieved, and recovering incomplete onboarding requires reissue

### Requirement: No implicit tenant access
The platform administrator flag SHALL NOT grant membership, permissions, or data access in any organization. Organization-scoped routes SHALL treat platform administrators like any other user.

#### Scenario: Platform admin without membership
- **WHEN** a platform admin who is not a member calls `GET /companies` for an organization
- **THEN** the system responds `403 Forbidden`

### Requirement: Permanent onboarding completion
Accepting the initial onboarding invitation SHALL record the organization's onboardedAt in the same transaction as the membership. Completion SHALL be permanent and SHALL NOT be cleared by later changes to members, groups, roles, or invitations. Ordinary invitations SHALL NOT set or change it.

#### Scenario: Removing the first administrator
- **WHEN** the initial invitation has been accepted and the administrator's membership is later removed
- **THEN** onboardedAt is unchanged and platform onboarding recovery stays prohibited

#### Scenario: Ordinary invitation
- **WHEN** an ordinary invitation is accepted
- **THEN** onboardedAt is neither set nor changed

### Requirement: Initial administrator invitation reissue
POST /platform/organizations/{organizationID}/admin-invitation/reissue SHALL require an authenticated platform administrator and incomplete, trustworthy onboarding lineage. It SHALL accept no request body or recipient changes. For an unaccepted live, expired, or revoked onboarding invitation it SHALL atomically invalidate any previous live onboarding invitation and issue a new seven-day, single-use invitation to the original recipient and original active same-organization group. It SHALL preserve history, record revocation and replacement actor/time attribution, store only the new token hash, and return organization metadata, invitation metadata, and invitationToken once with Cache-Control: no-store. Completed onboarding, accepted onboarding history without completion, missing onboarding lineage, or an unavailable original group SHALL return 409 without writes. Tokens and hashes SHALL NOT be logged.

#### Scenario: Recover a missed token
- **WHEN** a platform admin reissues an incomplete onboarding invitation
- **THEN** the response contains a fresh token, the previous token cannot be accepted, and the recipient/group are unchanged

#### Scenario: Reissue revoked or expired invitation
- **WHEN** onboarding is expired or revoked and its original group remains active in the same organization
- **THEN** replacement succeeds and preserves prior rows

#### Scenario: Completed onboarding or missing group
- **WHEN** reissue targets completed onboarding or an original group that is deleted or not in that organization
- **THEN** it returns 409 and creates no invitation or membership

#### Scenario: Platform access denied or invalid target
- **WHEN** a non-platform-admin calls reissue, or an authorized admin targets a malformed UUID or a missing/deleted organization
- **THEN** the system returns 403, 400, or 404 respectively

#### Scenario: Replacement fails atomically
- **WHEN** creation of the replacement fails after attempted revocation
- **THEN** no replacement persists and the prior invitation state is unchanged

#### Scenario: Concurrent reissues
- **WHEN** two authorized reissues race for the same incomplete organization
- **THEN** they serialize and only the final replacement token remains acceptable, with both replacements attributable

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
