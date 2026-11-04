## ADDED Requirements

### Requirement: Organization restoration
The system SHALL expose `POST /platform/organizations/:organizationID/restore` only to authenticated platform administrators, requiring a non-empty `reason`. In one transaction it SHALL record an append-only restoration holding the organization, its original `deleted_at` and `deleted_by`, the restoring administrator, the reason, and the time, then clear the deletion and set `updated_by`. It SHALL return the organization. It SHALL leave memberships, groups, roles, and invitations as they were, SHALL NOT grant the administrator tenant access, and SHALL log the restore. Restoration records SHALL reject updates and deletes.

#### Scenario: Restore a deleted organization
- **WHEN** a platform administrator restores a deleted organization with a reason
- **THEN** its members regain access with their groups intact, and a restoration records the original deletion and the reason

#### Scenario: Reason required
- **WHEN** a restore has no reason or an empty one
- **THEN** the system responds `400` and nothing changes

#### Scenario: Not deleted
- **WHEN** the organization is active
- **THEN** the system responds `409 Conflict`

#### Scenario: Unknown organization
- **WHEN** the ID is malformed or matches no organization
- **THEN** the system responds `404`

#### Scenario: Not a platform administrator
- **WHEN** a person who is not a platform administrator calls restore, including a former member
- **THEN** the system responds `403 Forbidden` and nothing changes

#### Scenario: No tenant access granted
- **WHEN** a platform administrator who is not a member restores an organization and then calls `GET /companies` for it
- **THEN** the system responds `403 Forbidden`

#### Scenario: Concurrent restores
- **WHEN** two administrators restore the same organization at the same time
- **THEN** one succeeds, the other responds `409`, and one restoration is recorded

#### Scenario: Evidence cannot change
- **WHEN** anything updates or deletes a restoration record
- **THEN** the database rejects it

#### Scenario: Deleted again
- **WHEN** a restored organization is deleted and restored again
- **THEN** a second restoration is recorded and the first is unchanged

## MODIFIED Requirements

### Requirement: Platform organization directory
The system SHALL expose `GET /platform/organizations` only to authenticated platform administrators, without requiring `X-Organization-ID` or organization membership. It SHALL list non-deleted organizations, or only deleted organizations when boolean `deleted` is true, in the standard `{items, metadata: {page, per, total}}` envelope. It SHALL accept `page` and `per` under list-endpoints rules, literal case-insensitive substring filters `code` and `name`, and booleans `onboarded` and `deleted`, decoded with Vapor's standard query boolean parsing, where true means `onboardedAt` is non-null. Filters SHALL combine with AND before counting and paging. It SHALL order by organization `updatedAt` descending, then ID ascending. Items SHALL expose ID, code, name, creation/update actor IDs and timestamps, `onboardedAt`, `deletedAt`, and `deletedById`; they SHALL NOT expose invitation tokens, token hashes, tenant business data, or invitation history. Directory visibility SHALL NOT grant tenant access.

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

#### Scenario: Find deleted organizations
- **WHEN** an authorized platform administrator requests `GET /platform/organizations?deleted=true`
- **THEN** only deleted organizations are counted and paged, each with `deletedAt` and `deletedById`

#### Scenario: Deleted organizations hidden by default
- **WHEN** an authorized platform administrator requests `GET /platform/organizations` or `?deleted=false`
- **THEN** no deleted organization is listed
