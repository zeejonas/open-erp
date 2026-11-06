# audit-trail

## Purpose

Durable, attributed evidence of every application-table change, with coverage checks and read APIs.

## Requirements

### Requirement: Atomic change capture
The system SHALL record an audit event in `audit.audit_events` for every committed row insert, update, and delete on every application table, in the same transaction as the change. Each event SHALL contain ID, server time as `created_at`, nullable organization ID, table name, nullable record ID, operation, changed fields, old values, new values, actor type, nullable actor ID, nullable actor name, nullable IP address, nullable request ID, nullable approval request ID, session database user, and transaction ID. Operation SHALL be `create`, `update`, `delete`, `soft_delete`, or `restore`. An update that changes no column SHALL NOT record an event.

#### Scenario: Update records values
- **WHEN** a company's name changes
- **THEN** one `update` event contains the old and new rows and lists `name` in changed fields

#### Scenario: Rollback leaves no event
- **WHEN** a transaction writes a row and then rolls back
- **THEN** neither the row nor an audit event exists

#### Scenario: Soft delete classified
- **WHEN** a row's `deleted_at` changes from null to a value
- **THEN** the event operation is `soft_delete`

#### Scenario: Soft-delete helper records both writes
- **WHEN** a row is soft-deleted through the helper that first saves `deleted_by`
- **THEN** an `update` event and then a `soft_delete` event are recorded in one transaction

#### Scenario: Restore classified
- **WHEN** a row's `deleted_at` changes from a value to null
- **THEN** the event operation is `restore`

#### Scenario: Unchanged update ignored
- **WHEN** an update writes the same value to every column
- **THEN** no audit event is recorded

#### Scenario: Non-Fluent write captured
- **WHEN** a token revocation is inserted through SQLKit
- **THEN** an audit event is recorded

### Requirement: Evidence is append-only
Audit events SHALL NOT be updated, deleted, or truncated, and no API route or command SHALL remove them. Retention SHALL be indefinite until a later change defines otherwise. `prune-revoked-tokens` SHALL record audit events for deleted revocations and SHALL NOT delete audit events.

#### Scenario: Update rejected
- **WHEN** any role runs an update against an audit event while its trigger is enabled
- **THEN** the database rejects it

#### Scenario: Truncate rejected
- **WHEN** any role truncates `audit.audit_events` while its trigger is enabled
- **THEN** the database rejects it

### Requirement: Explicit write attribution
Each application write SHALL run inside a transaction with audit context. HTTP context SHALL include request ID, resolved client IP, and the authenticated actor. Requests from platform administrator routes SHALL use actor type `platform_admin`, and other authenticated requests SHALL use `user`. A verified identity with no bound user SHALL use actor type `user`, a null actor ID, and its OIDC subject as actor name. During invitation acceptance, binding or creating the user SHALL use that verified identity, and later writes SHALL use the resolved user. Operational commands SHALL use actor type `operator` with the supplied operator name, and automated commands SHALL use `system` with the command name. Applying an approved or overridden request SHALL record the approval request ID.

#### Scenario: Direct write attributed
- **WHEN** an authenticated user directly creates a company from an IP address
- **THEN** the event records the user, IP, and request ID

#### Scenario: Approved write links evidence
- **WHEN** the final approver's approval applies a held company update
- **THEN** the company event records the approver as actor and links the approval request

#### Scenario: Held write does not change target
- **WHEN** a company update returns `202`
- **THEN** approval records have events and the company has no `update` event

#### Scenario: Unbound token revocation attributed
- **WHEN** a verified identity with no bound user logs out
- **THEN** the revocation event records actor type `user`, no actor ID, and the OIDC subject as actor name

#### Scenario: Invitation acceptance attributed
- **WHEN** a verified identity with no bound user accepts an invitation
- **THEN** the user event records the OIDC subject with no actor ID, and the membership event records the resolved user as actor ID

#### Scenario: Override attributed to operator
- **WHEN** `approval-override` completes a request
- **THEN** resulting events record actor type `operator`, the operator name, and the approval request

#### Scenario: Platform administrator command attributed
- **WHEN** `platform-admin` runs with `--operator`
- **THEN** resulting events record actor type `operator` and that name

#### Scenario: Platform administrator command without operator
- **WHEN** `platform-admin` runs without `--operator`
- **THEN** the command fails without writes

### Requirement: Missing context fails closed
A write with no audit context SHALL fail and roll back when the session role is neither a superuser nor a member of the audit table's owner role. For a superuser or owner-member session, the event SHALL use actor type `database` and SHALL record the session user.

#### Scenario: Runtime write without context
- **WHEN** the runtime role writes a business row without audit context
- **THEN** the write fails and neither the row nor an event is stored

#### Scenario: Direct owner edit captured
- **WHEN** an owner role edits a row directly without context
- **THEN** the edit is recorded with actor type `database` and that session user

### Requirement: Sensitive values excluded
Stored old and new values SHALL exclude `organization_invitations.token_hash`, `users.auth_subject`, and `revoked_access_tokens.fingerprint`. Changed fields SHALL still name an excluded column when it changes. Revocation events SHALL have a null record ID.

#### Scenario: Invitation token hash excluded
- **WHEN** an invitation is reissued
- **THEN** its audit values do not contain a token hash

#### Scenario: Excluded change is visible
- **WHEN** a user's `auth_subject` changes
- **THEN** changed fields include `auth_subject` and neither value is stored

#### Scenario: Revocation fingerprint excluded
- **WHEN** a token is revoked
- **THEN** the event has a null record ID and its values do not contain the fingerprint

### Requirement: Audit coverage verification
The system SHALL fail a test when any base table in `public`, other than `_fluent_migrations`, lacks an enabled change trigger, or lacks a required `organization_id` and is not listed as global. The global list SHALL be `users`, `organizations`, and `revoked_access_tokens`. The `audit-verify` command SHALL run the same check, and SHALL also report any login role outside the owner role, other than a superuser, that can write to `audit.audit_events` or `_fluent_migrations`, or has `TRUNCATE` or `TRIGGER` on an application table. It SHALL exit non-zero when it finds a problem.

#### Scenario: New table without trigger
- **WHEN** a migration adds a table without a change trigger
- **THEN** the coverage test fails and names the table

#### Scenario: New table without tenant classification
- **WHEN** a table has no required `organization_id` and is not listed as global
- **THEN** the coverage test fails and names the table

#### Scenario: Disabled trigger detected
- **WHEN** an owner disables a change trigger
- **THEN** `audit-verify` exits non-zero and names the table

#### Scenario: Unsafe grant detected
- **WHEN** a non-owner login role is granted `INSERT` on `audit.audit_events`
- **THEN** `audit-verify` exits non-zero and names the role

#### Scenario: Migration history revoke skipped
- **WHEN** the runtime role can still write to `_fluent_migrations`
- **THEN** `audit-verify` exits non-zero and names the role

### Requirement: Tenant audit events API
`GET /audit-events` SHALL require authentication, `X-Organization-ID`, active membership, and `audit_event:read`. It SHALL list only events for that organization under list-endpoints paging rules, ordered by `createdAt` descending and then `id` ascending. Exact filters SHALL be `table`, `recordId`, `actorId`, `operation`, and `requestId`. `from` and `to` SHALL filter `createdAt` inclusively. It SHALL expose actor name only for `operator` and `system` actors and IP only for `user` actors. It SHALL NOT expose session database users.

#### Scenario: Member reads tenant history
- **WHEN** a member with `audit_event:read` filters by a company's record ID
- **THEN** that company's events in the organization are returned newest first

#### Scenario: Missing permission
- **WHEN** a member without `audit_event:read` lists audit events
- **THEN** the system responds `403`

#### Scenario: Non-member organization
- **WHEN** a user supplies an organization where they have no active membership
- **THEN** the system responds `403`

#### Scenario: Other tenant filtered out
- **WHEN** a member filters by a record ID from another organization
- **THEN** the system returns an empty page

#### Scenario: Global events hidden
- **WHEN** a member lists audit events
- **THEN** `users` and `revoked_access_tokens` events are not returned

#### Scenario: Platform action visible without IP
- **WHEN** a platform administrator restores an organization and its member reads the events
- **THEN** the event shows the platform administrator actor without an IP address

#### Scenario: Invalid filter
- **WHEN** a request supplies an unknown parameter or invalid `operation`
- **THEN** the system responds `400`

### Requirement: Platform audit events API
`GET /platform/audit-events` SHALL be available only to authenticated platform administrators. It SHALL list only events with a null organization ID, using the same paging, order, and filters as the tenant API. It SHALL expose all recorded attribution fields and SHALL NOT grant tenant access.

#### Scenario: Administrator reads global event
- **WHEN** a platform administrator lists platform audit events
- **THEN** user profile changes are returned

#### Scenario: Tenant events excluded
- **WHEN** a platform administrator lists platform audit events
- **THEN** organization-scoped events are not returned

#### Scenario: Non-administrator rejected
- **WHEN** a user who is not a platform administrator requests platform audit events
- **THEN** the system responds `403`
