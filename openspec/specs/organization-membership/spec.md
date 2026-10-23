# organization-membership

## Purpose

Tenant selection, per-request membership checks, invitations, and member listing and removal.

## Requirements

### Requirement: Tenant selection and membership verification
Every organization-scoped route SHALL require an `X-Organization-ID` header containing a UUID and SHALL verify, on every request, that the authenticated user has an active (not soft-deleted) membership in that organization and that the organization is not soft-deleted. The header selects the tenant; it SHALL NOT grant access by itself.

#### Scenario: Missing or malformed header
- **WHEN** an authenticated request to an organization-scoped route omits `X-Organization-ID` or sends a non-UUID value
- **THEN** the system responds `400 Bad Request`

#### Scenario: Not a member
- **WHEN** an authenticated user sends the ID of an organization they are not a member of
- **THEN** the system responds `403 Forbidden`

#### Scenario: Unknown organization
- **WHEN** an authenticated user sends the ID of an organization that does not exist
- **THEN** the system responds `403 Forbidden`, indistinguishable from not being a member

#### Scenario: Removed membership
- **WHEN** a user's membership has been soft-deleted
- **THEN** their next request to that organization responds `403 Forbidden`

#### Scenario: Deleted organization
- **WHEN** the organization has been soft-deleted
- **THEN** requests to it respond `403 Forbidden`

### Requirement: Tenant isolation of queries
Every read and write of organization-owned data SHALL be filtered by the verified organization ID. Records belonging to another organization SHALL be indistinguishable from nonexistent records.

#### Scenario: Cross-organization read
- **WHEN** a member of organization B requests a company belonging to organization A by ID
- **THEN** the system responds `404 Not Found`

#### Scenario: Cross-organization write
- **WHEN** a member of organization B attempts to update or delete a company belonging to organization A
- **THEN** the system responds `404 Not Found` and the company is unchanged

### Requirement: List my organizations
The system SHALL expose `GET /me/organizations`, which requires authentication but no organization header, and returns the organizations in which the user has an active membership.

#### Scenario: Multiple memberships
- **WHEN** a user is an active member of organizations A and B and a removed member of C
- **THEN** the response contains A and B only

### Requirement: Organization invitations
Members with `organization_invitation:create` SHALL be able to invite a person by email, first name, last name, and an optional active group from the same organization. The system SHALL return a single-use token once, store only its SHA-256 hash, and expire the invitation after 7 days. Members with `organization_invitation:read` SHALL be able to list pending invitations, and members with `organization_invitation:delete` SHALL be able to revoke them.

#### Scenario: Create invitation
- **WHEN** a member with `organization_invitation:create` invites `bea@acme.com`
- **THEN** the system returns the invitation and a token, and persists only the token's hash

#### Scenario: Group from another organization
- **WHEN** the invitation references a group that belongs to another organization or is deleted
- **THEN** the system responds `400 Bad Request`

#### Scenario: Revoke invitation
- **WHEN** a member with `organization_invitation:delete` revokes a pending invitation
- **THEN** the invitation can no longer be accepted

### Requirement: Invitation acceptance
The system SHALL expose `POST /invitations/accept`, which requires a valid access token but no organization header and no existing user. The system SHALL fetch the caller's claims from the configured OIDC userinfo endpoint and SHALL accept only when `email_verified` is true and the email matches the invitation's email case-insensitively. On acceptance, in one transaction, the system SHALL find or create the user, bind `auth_subject` if unbound, create a new membership, add it to the invitation's group if present, and mark the invitation accepted with `accepted_by` and `accepted_at`. A removed membership SHALL NOT be restored, so a returning member belongs only to the group on the new invitation. Invitations to a soft-deleted organization SHALL NOT be accepted. This is the only path that creates users.

#### Scenario: First-time user accepts
- **WHEN** a person with no user record accepts a valid invitation with a verified matching email
- **THEN** a user is created with the invitation's name and email, bound to the token's `sub`, and made a member of the organization

#### Scenario: Invitation with a group
- **WHEN** a person accepts a valid invitation that names the "Organization Viewers" group
- **THEN** their new membership belongs to that group, with `created_by` set to the accepting user

#### Scenario: Invitation group deleted before acceptance
- **WHEN** the invitation's group was soft-deleted after the invitation was created
- **THEN** the system responds `400 Bad Request` and nothing is persisted

#### Scenario: Existing user joins another organization
- **WHEN** an existing user bound to the token's `sub` accepts a valid invitation from a second organization
- **THEN** a membership in the second organization is created and no new user is created

#### Scenario: Unverified email
- **WHEN** userinfo returns `email_verified` false
- **THEN** the system responds `403 Forbidden` and nothing is persisted

#### Scenario: Email mismatch
- **WHEN** the verified email differs from the invitation's email
- **THEN** the system responds `403 Forbidden` and nothing is persisted

#### Scenario: Email bound to another subject
- **WHEN** a user with the invitation's email already exists and is bound to a different `auth_subject`
- **THEN** the system responds `409 Conflict`

#### Scenario: Expired, accepted, or revoked invitation
- **WHEN** the token belongs to an invitation that is expired, already accepted, revoked, or for a deleted organization
- **THEN** the system responds `404 Not Found`

#### Scenario: Removed member is re-invited
- **WHEN** a removed member accepts a new invitation with no group
- **THEN** a new membership is created, the removed membership keeps its `deleted_by`, and the member's previous groups grant nothing

#### Scenario: Already a member
- **WHEN** the user already has an active membership in the organization
- **THEN** the system responds `409 Conflict`

### Requirement: Member listing and removal
Members with `organization_user:read` SHALL be able to list and view the organization's active members via `GET /users` and `GET /users/:userID`. Members with `organization_user:delete` SHALL be able to remove a member via `DELETE /organization-users/:userID`, which soft-deletes the membership and every group membership held through it, recording `deleted_by` on each. Linking an existing user by UUID SHALL NOT be possible.

#### Scenario: List members
- **WHEN** a member with `organization_user:read` calls `GET /users`
- **THEN** only active members of the organization are returned

#### Scenario: Remove member
- **WHEN** a member with `organization_user:delete` removes another member
- **THEN** the membership and each of its group memberships are soft-deleted with `deleted_by` set, and the removed user loses access to the organization

#### Scenario: Link by UUID removed
- **WHEN** a client calls `POST /organization-users`
- **THEN** the system responds `404 Not Found`
