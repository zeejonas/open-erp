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
