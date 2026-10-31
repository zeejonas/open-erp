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
