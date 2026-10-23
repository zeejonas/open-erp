## 1. Baseline

- [x] 1.1 Confirm add-user-groups is applied, and list every registered migration that alters or drops a table created by another
- [x] 1.2 Migrate an empty database with the current build and save `pg_dump --schema-only` output outside the repo

## 2. Fold migrations

- [x] 2.1 Fold `AddUserAuthFields` into `CreateUser` and delete it
- [x] 2.2 Fold `ScopeOrganizationUserUniquenessToActiveRows` into `CreateOrganizationUser` (active-unique index instead of the full-table unique), delete it, and delete the now-unused `Database.dropIndex`
- [x] 2.3 Fold `ReplaceInvitationRoleWithGroup` into `CreateOrganizationInvitation` (`group_id` instead of `role_id`) and delete it
- [x] 2.4 Delete `CreateOrganizationRoleAssignment`, `CreateCompanyRoleAssignment`, and `DropRoleAssignments`
- [x] 2.5 Fold any remaining alter or drop migration found in 1.1 by the same rule
- [x] 2.6 Reorder `configure.swift` registrations by foreign-key dependency, with invitations after the group tables

## 3. Verify

- [x] 3.1 Migrate an empty database with the folded build, dump the schema, and diff it against 1.2. The only differences allowed are generated constraint names
- [x] 3.2 Add a `SchemaTests` case: a soft-deleted membership allows a new active one for the same user and organization, and a second active one is rejected
- [x] 3.3 Run `swift build` and `swift test`. Every test applies and fully reverts the schema through `withApp`

## 4. Policy

- [x] 4.1 Add to the `context` in `openspec/config.yaml`: "Pre-release: one create migration per table, edited in place; after the first production release, migrations are frozen and changes are additive"
- [x] 4.2 Add a one-line pointer to that policy in `AGENTS.md`
- [x] 4.3 Confirm `openspec validate consolidate-prerelease-migrations` passes
