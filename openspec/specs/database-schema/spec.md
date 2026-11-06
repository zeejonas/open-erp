# database-schema

## Purpose

One create migration per table before the first production release, then additive migrations only. Tenant isolation and soft-delete history stay enforced by the schema.

## Requirements

### Requirement: One create migration per table before release
Until the first production release, the system SHALL define each table with exactly one migration that creates the table in its current shape, including its columns, foreign keys, unique constraints, and active-unique indexes. No migration SHALL alter or drop a table created by another migration. A schema change SHALL edit the owning create migration, and removing a table SHALL delete its migration and registration.

#### Scenario: Column added before release
- **WHEN** a pre-release change adds a column to an existing table
- **THEN** the table's create migration declares the column and no new migration is registered

#### Scenario: Table removed before release
- **WHEN** a pre-release change removes a table
- **THEN** its create migration and its registration are deleted and no drop migration is added

#### Scenario: Registered migrations map to tables
- **WHEN** the registered migrations are listed
- **THEN** each one creates exactly one table and no two create the same table

### Requirement: Schema applies and reverts cleanly
Registered migrations SHALL be ordered so that every foreign key's target table is created first. Migrating an empty database SHALL produce the complete schema, and reverting every migration SHALL leave no application tables.

#### Scenario: Fresh database
- **WHEN** all migrations run against an empty database
- **THEN** they succeed and every model can be saved and queried

#### Scenario: Full revert
- **WHEN** every migration is reverted after migrating
- **THEN** the revert succeeds and no application tables remain

### Requirement: Consolidation preserves tenant and history constraints
Consolidating migrations SHALL preserve every constraint that enforces tenant isolation and soft-delete history. Tenant-owned rows SHALL require an existing parent organization or company, and active-unique indexes SHALL apply only to rows where `deleted_at` is null.

#### Scenario: Orphan tenant row rejected
- **WHEN** a row is inserted into a tenant-owned table with an `organization_id` that does not exist
- **THEN** the database rejects the insert

#### Scenario: Removed member can be re-added
- **WHEN** a membership is soft-deleted and the same user is added to the same organization again
- **THEN** the new membership is accepted and the removed row keeps its `deleted_by`

#### Scenario: Duplicate active membership rejected
- **WHEN** a second active membership is inserted for the same user and organization
- **THEN** the database rejects the insert

### Requirement: Additive migrations after release
From the first production release, the set of registered migrations SHALL be frozen as the baseline. Every later schema change SHALL be a new migration with a working `revert`, and released migrations SHALL NOT be edited or removed.

#### Scenario: Column added after release
- **WHEN** a change after the first production release adds a column
- **THEN** it adds a new migration that updates the table, and the released create migration is unchanged

### Requirement: Persist onboarding lineage and completion
The organization create migration SHALL declare nullable onboarded_at. The invitation create migration SHALL declare non-null is_onboarding defaulting to false and enforce at most one non-deleted onboarding invitation per organization. Invitation lineage SHALL retain prior rows and actor/time attribution. These additions SHALL edit the owning create migrations under the pre-release policy without registering an alter migration.

#### Scenario: Fresh onboarding schema
- **WHEN** migrations apply to an empty database
- **THEN** both fields and the active onboarding uniqueness constraint exist and the schema still reverts cleanly

#### Scenario: Duplicate current onboarding invitation
- **WHEN** a second non-deleted onboarding invitation is inserted for one organization
- **THEN** the database rejects it, while replacement after revocation preserves the historical row

### Requirement: Durable access-token revocation records
The system SHALL define revoked_access_tokens with one create migration and a Fluent model. It SHALL store a unique SHA-256 fingerprint of the token's signed header and payload as its primary key, verified issuer and subject, token expiration and first revocation time. All fields SHALL be non-null. It SHALL NOT store raw access or refresh tokens, require a provider-specific token ID, depend on an ERP user row, or belong to a UI or tenant session. Duplicate/concurrent revocations SHALL preserve the first record. The schema SHALL be usable by every serving instance and survive application restarts. Registration and revert SHALL follow the pre-release single-create-migration policy.

#### Scenario: Fresh schema and revert
- **WHEN** the registered migrations apply to an empty database and are subsequently reverted
- **THEN** the revocation table is created with required fields and uniqueness and reverts cleanly with the complete schema

#### Scenario: Shared durable record
- **WHEN** one instance commits revocation and another instance or a restarted application checks that fingerprint
- **THEN** the same revocation is visible without any in-memory session state

#### Scenario: Unbound identity attribution
- **WHEN** a verified subject without an ERP user logs out
- **THEN** the record attributes revocation to its verified issuer/subject and server time without creating a user or referencing a tenant

### Requirement: Revocation expiry cleanup and credential-safe evidence
The system SHALL retain an enforceable revocation record until at least the token's verified expiration. The native prune-revoked-tokens command SHALL delete only records whose expiration is not in the future and report a count. First successful revocations SHALL produce security audit events attributable to verified issuer/subject and server time. Tokens, token fingerprints, Authorization values and credentials SHALL NOT appear in logs, public error details, or OpenAPI examples. Cleanup SHALL NOT erase deployment-retained audit logs.

#### Scenario: Cleanup boundary
- **WHEN** cleanup runs with expired and unexpired revocation rows
- **THEN** only expired rows are removed and unexpired logged-out tokens stay rejected

#### Scenario: Credential-safe audit
- **WHEN** logout succeeds, fails, or is retried and cleanup later runs
- **THEN** success attribution and cleanup counts are available without raw tokens or fingerprints in logs or response diagnostics

### Requirement: Tenant ownership on every tenant table
Every tenant-owned table SHALL have a required `organization_id` referencing `organizations`. `approval_decisions`, `approval_policy_slots`, `approval_policy_versions`, `approval_request_tracks`, `company_users`, `group_companies`, `group_members`, `group_roles`, and `role_permissions` SHALL gain this column by editing their create migrations. A reference from a tenant-owned table to a tenant-owned parent SHALL be a composite foreign key that includes `organization_id`, including `approval_policies.company_id`, `organization_invitations.group_id`, and `organization_invitations.approval_request_id`. `users`, `organizations`, and `revoked_access_tokens` SHALL remain global.

#### Scenario: Cross-tenant child rejected
- **WHEN** a `group_members` row names a group in one organization and a membership in another
- **THEN** the database rejects the insert

#### Scenario: Mismatched parent rejected
- **WHEN** a `role_permissions` row has an organization that differs from its role's organization
- **THEN** the database rejects the insert

#### Scenario: Existing tenant table cannot cross tenants
- **WHEN** an invitation names a group from another organization
- **THEN** the database rejects the insert

#### Scenario: Optional parent can be empty
- **WHEN** an invitation has no group
- **THEN** the database accepts the insert

#### Scenario: Tenant value required
- **WHEN** a row is inserted into a listed table without `organization_id`
- **THEN** the database rejects the insert

#### Scenario: Application writes tenant
- **WHEN** an API write creates a child row in a listed table
- **THEN** the row stores the same organization as its parent

### Requirement: Create migrations install audit capture
`CreateAuditEvent` SHALL be registered first and SHALL require the `audit` schema created by bootstrap. Each create migration for an application table SHALL install change capture on that table. Reverting all migrations SHALL remove application tables, audit tables, and audit functions. It SHALL keep the `audit` schema so bootstrap grants survive a revert.

#### Scenario: Fresh schema is audited
- **WHEN** all migrations run on an empty bootstrapped database
- **THEN** the audit coverage check reports no problems

#### Scenario: Full revert removes audit objects
- **WHEN** every migration is reverted
- **THEN** no audit table or capture function remains

#### Scenario: Grants survive revert and migrate
- **WHEN** an owner reverts and reruns all migrations after bootstrap
- **THEN** the runtime role can still read `audit.audit_events` and cannot write to it
