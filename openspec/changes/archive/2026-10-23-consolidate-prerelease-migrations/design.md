## Context

Rule 10 of the archived add-oidc-auth-and-org-rbac design said schema changes are new migrations, so the history stays an audit record. Two migrations alter earlier tables today: `AddUserAuthFields` changes `users`, and `ScopeOrganizationUserUniquenessToActiveRows` replaces the uniqueness constraint on `organization_users`. The add-user-groups change applies the same rule. It adds `ReplaceInvitationRoleWithGroup`, and `DropRoleAssignments`, which removes two tables that this change will delete outright. Tests apply and revert the full schema around each test through `withApp`. The product has no production deployment.

## Goals / Non-Goals

**Goals:**
- One readable create migration per table, so each file reads as the table's current definition.
- The same schema as before. Only generated constraint names may differ.
- A written policy, with an end date, that future changes follow.

**Non-Goals:**
- Schema redesign, a single-file baseline, or new migration tooling.
- Preserving existing local databases.

## Decisions

### 1. Edit create migrations in place until the first production release
Fluent's `migrate` command only runs migrations "registered since it was last run" (https://docs.vapor.codes/fluent/migration/#migrate), keyed by migration name. An in-place edit is therefore invisible to an existing database and correct for a fresh one. Before release, every database is disposable, so the only cost is a one-time local reset. Git and reviewed changes keep the schema history.

*Rejected:* continuing to add alter migrations (the count grows with every change, and revert code exists only for history); renaming migrations to force a re-run (changes nothing for databases that already have the tables).

### 2. One migration per table, not one baseline
Each table keeps its own `Create<Table>` file and struct name. The schema builder expresses each table in one `create()` call (https://docs.vapor.codes/fluent/schema/), and `revert` stays a single `delete()`. Indexes the builder can't express, such as active-unique partial indexes, stay in the same migration through `createActiveUniqueIndex`, as the role tables already do.

*Rejected:* a single `CreateSchema` migration (one long file, and every table change edits the same file).

### 3. Folds
Expected after add-user-groups is applied:
- `CreateUser` declares `auth_subject` (unique, optional) and `is_platform_admin` (required, default `false`). `AddUserAuthFields` is deleted.
- `CreateOrganizationUser` drops `.unique(on: "organization_id", "user_id")` and creates the `organization_users_active_member` active-unique index. `ScopeOrganizationUserUniquenessToActiveRows` is deleted, and so is `Database.dropIndex`, which only it used.
- `CreateOrganizationInvitation` declares `group_id` instead of `role_id`. `ReplaceInvitationRoleWithGroup` is deleted.
- `CreateOrganizationRoleAssignment`, `CreateCompanyRoleAssignment`, and `DropRoleAssignments` are deleted.

Any other alter or drop migration that add-user-groups ends up adding is folded by the same rule.

### 4. Registration order follows foreign keys
Migrations "should be listed in order of dependency" (https://docs.vapor.codes/fluent/migration/#register). Folding `group_id` into invitations makes `CreateOrganizationInvitation` depend on `CreateGroup`, so it moves after the group tables. The final order is: users, organizations, companies, organization users, company users, roles, role permissions, groups, group members, group roles, group companies, and invitations. `autoRevert` runs the list in reverse, so the revert order needs no extra work.

### 5. Verify equivalence once, then rely on existing tests
Before and after the fold, dump the schema of a freshly migrated database with `pg_dump --schema-only` and diff the two dumps. The only expected differences are the removed migration rows and Fluent-generated constraint names. Fluent names a unique constraint differently in `create()` and `update()`, as the existing `AddUserAuthFields.revert` comment notes. The dump is a review artifact and is not committed. Ongoing coverage comes from `withApp`, which applies and fully reverts the schema in every test. One new `SchemaTests` case covers the `organization_users` fold, the only one that changes a constraint's form.

*Rejected:* a permanent schema-snapshot test (it has to be updated on every pre-release schema edit and tests Postgres more than our code).

### 6. Policy lives in `openspec/config.yaml`
The add-user-groups design took its rule from an archived design, so the replacement has to sit where every future artifact reads it. That place is the `context` block of `openspec/config.yaml`, and `AGENTS.md` gets a one-line pointer. The `database-schema` spec states the testable parts.

## Risks / Trade-offs

- [A developer keeps an old local database] → Their schema silently diverges. Mitigation: the proposal and change summary give the reset step, and the first request to touch a new column fails loudly.
- [The fold changes the schema by mistake] → Caught by the one-time `pg_dump` diff and by the full test suite running against a fresh schema.
- [The policy outlives pre-release] → `config.yaml` names the end condition, the first production release, and the `database-schema` spec requires additive migrations from then on.
- [Conflicts with in-flight add-user-groups work] → Implementation starts only after add-user-groups is applied. The fold list in Decision 3 is checked against the migrations that change actually registered.

## Migration Plan

1. Apply add-user-groups first.
2. On a fresh database, migrate the pre-fold build and save `pg_dump --schema-only`.
3. Fold the migrations, migrate a fresh database, dump again, and diff.
4. Every developer drops their local database once (for example `docker compose down -v`, which wipes the `db_data` volume) and runs `migrate`.

Rollback: revert the commit and reset local databases again.

## Open Questions

- What counts as the "first production release" that freezes the baseline: a tagged version, or the first deployment holding a real tenant's data? This change assumes the latter, since that is when data must be preserved.
