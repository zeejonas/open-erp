## MODIFIED Requirements

### Requirement: Sensitive values excluded
Stored old and new values SHALL exclude `organization_invitations.token_hash`, `users.auth_subject`, `revoked_access_tokens.fingerprint`, `business_events.payload`, and `webhook_subscription_revisions.secret_ciphertext`. Changed fields SHALL still name an excluded column when it changes. Revocation events SHALL have a null record ID.

#### Scenario: Invitation token hash excluded
- **WHEN** an invitation is reissued
- **THEN** its audit values do not contain a token hash

#### Scenario: Excluded change is visible
- **WHEN** a user's `auth_subject` changes
- **THEN** changed fields include `auth_subject` and neither value is stored

#### Scenario: Revocation fingerprint excluded
- **WHEN** a token is revoked
- **THEN** the event has a null record ID and its values do not contain the fingerprint

#### Scenario: Webhook secret excluded
- **WHEN** a subscription revision is created with an encrypted signing secret
- **THEN** audit rows name that changed column but store neither ciphertext nor plaintext secret

#### Scenario: Business body not duplicated into audit
- **WHEN** a business event is inserted
- **THEN** its audit row retains event ID, tenant, type and digest but not its payload, and payload inspection still requires its dedicated permission

### Requirement: Atomic change capture
The system SHALL record an audit event in `audit.audit_events` for every committed row insert, update, and delete on every application table, in the same transaction as the change, except where Operational queue capture scope narrows it. Each event SHALL contain ID, server time as `created_at`, nullable organization ID, table name, nullable record ID, operation, changed fields, old values, new values, actor type, nullable actor ID, nullable actor name, nullable IP address, nullable request ID, nullable approval request ID, session database user, and transaction ID. Operation SHALL be `create`, `update`, `delete`, `soft_delete`, or `restore`. An update that changes no column SHALL NOT record an event.

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

### Requirement: Audit coverage verification
The system SHALL fail a test when any base table in `public`, other than `_fluent_migrations`, lacks an enabled change trigger with the events required by Operational queue capture scope, or has a trigger on a table that scope exempts, or lacks a required `organization_id` and is not listed as global. The global list SHALL be `users`, `organizations`, and `revoked_access_tokens`. The `audit-verify` command SHALL run the same check, and SHALL also report any login role outside the owner role, other than a superuser, that can write to `audit.audit_events` or `_fluent_migrations`, or has `TRUNCATE` or `TRIGGER` on an application table. It SHALL exit non-zero when it finds a problem.

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

#### Scenario: Queue trigger scope enforced
- **WHEN** `webhook_deliveries` has a change trigger that captures updates, or `business_event_dispatches` has any change trigger
- **THEN** the coverage test fails and names the table

## ADDED Requirements

### Requirement: Operational queue capture scope
`webhook_deliveries` SHALL have a change trigger that captures inserts and deletes but not updates, because its scheduling updates are reconstructable from the append-only delivery ledger. `business_event_dispatches` SHALL have no change trigger, because it holds only a reference to an audited business event and is removed once dispatched. Both tables SHALL still require `organization_id`. Every other application table SHALL keep insert, update and delete capture. No other table SHALL be exempted without a later specification change.

#### Scenario: Delivery scheduling churn not captured
- **WHEN** a worker leases, retries and acknowledges a delivery
- **THEN** the delivery's creation has one audit event, its scheduling updates have none, and each attempt appears in the append-only ledger

#### Scenario: Delivery deletion captured
- **WHEN** a privileged role deletes a delivery row
- **THEN** an audit event records the deletion
