## Why

Every schema change adds a migration because the migration list was treated as an audit record. Before release there is no tenant data and git already records every change, so the extra migrations only add files, ordering rules, and revert code. There are 12 today, and add-user-groups brings that to 18 even though two of its migrations exist only to undo earlier ones.

## What Changes

- Until the first production release, each table has exactly one `Create<Table>` migration that builds its current shape. Schema changes edit that migration in place, and dropped tables delete theirs.
- Fold the migrations that alter other tables into the create migrations they modify: `AddUserAuthFields` goes into `CreateUser`, and `ScopeOrganizationUserUniquenessToActiveRows` into `CreateOrganizationUser`. Do the same for the alter and drop migrations from add-user-groups, which lands first.
- Delete helpers left unused afterwards (`Database.dropIndex`).
- Record the policy and how it ends in `openspec/config.yaml`, so future designs follow it instead of rule 10 of the archived design. At the first production release, the migration set is frozen and later changes are new additive migrations again.
- **BREAKING (developers only)**: Existing local databases have to be dropped and migrated from scratch. Fluent skips migrations whose names are already recorded, so edits in place are never applied to them.

## Non-goals

- Changing the resulting schema: every table, column, constraint, and index stays the same apart from generated constraint names.
- Combining tables into a single migration file.
- Defining the post-release migration process beyond "additive from the release baseline".
- Squashing tooling, schema dumps, or SQL-file migrations.

## SOX / SOC Impact

- **Audit trail**: No change to how the application audits activity. `created_by`, `deleted_by`, soft deletes, and timestamps stay on every table. Schema change history remains in git and in reviewed changes, which is what SOX IT general controls rely on for change management. The migration list never served as that evidence.
- **Change management**: Pre-release databases hold no financial data, so they are out of scope for IT general controls. The policy ends at the first production release. After that, every schema change is a new, reviewed, reversible migration, so production schema history can be reproduced from the release baseline.
- **Access control and segregation of duties**: Unchanged. Constraints that enforce tenant isolation and active-row uniqueness carry over intact.

## Capabilities

### New Capabilities
- `database-schema`: How the schema is defined and migrated, including one create migration per table before release, a clean apply and full revert, and additive migrations after release.

### Modified Capabilities
None. No API or access behavior changes.

## Impact

- **Migrations**: The 18 migrations expected after add-user-groups drop to 12, one per table. From then on the count grows only when a table is added.
- **Code**: `configure.swift` migration registration and ordering, `ActiveUniqueIndex.swift`, and `openspec/config.yaml`.
- **Tests**: No new tests. Every test already applies and fully reverts the schema through `withApp`, and `SchemaTests` keeps its constraint checks.
- **Developers**: Drop and recreate local databases once (for example `docker compose down -v`), then run `migrate`.
- **Sequencing**: Implement after add-user-groups is applied, because its migrations are part of what gets folded.
