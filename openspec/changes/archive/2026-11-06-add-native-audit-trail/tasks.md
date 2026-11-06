## 1. Prove the mechanism

- [x] 1.1 Prove with a disposable SQL demo, since removed, that `set_config(..., true)` is visible to a trigger, is empty or missing after commit, and `session_user` remains the caller in a `SECURITY DEFINER` function
- [x] 1.2 Prove that a runtime role can write through the trigger but cannot insert directly into `audit.audit_events`; update the design if either demo disproves it

## 2. Database roles

- [x] 2.1 Add idempotent role and `audit` schema bootstrap SQL with `public` `CREATE` grants and schema-scoped default privileges; CI runs it twice and migrates as the owner
- [x] 2.2 Update Compose so `migrate` and `revert` use the owner role and `app` uses the runtime role; verify from an empty volume
- [x] 2.3 Add the production startup guard and non-production warning, with tests for owner and runtime connections
- [x] 2.4 Document bootstrap, the `_fluent_migrations` revoke, separate credentials, and the RDS Proxy pinning check in the README

## 3. Tenant columns

- [x] 3.1 Add parent `UNIQUE (organization_id, id)` constraints and required `organization_id` to the 9 listed create migrations, using composite foreign keys
- [x] 3.2 Convert `approval_policies.company_id`, `organization_invitations.group_id`, and `organization_invitations.approval_request_id` to composite foreign keys
- [x] 3.3 Update models and all write paths to store the tenant, including onboarding, role, group, and approval flows
- [x] 3.4 Add `organization_id` to append-only protected columns where applicable
- [x] 3.5 Add schema tests for cross-tenant and mismatched-parent rejection, and for empty optional parents

## 4. Change capture

- [x] 4.1 Rename `createAuditTrigger` to `createAppendOnlyTrigger` and extend it to reject `TRUNCATE`
- [x] 4.2 Add `CreateAuditEvent`, the capture function, `createChangeTrigger(on:redact:)`, and read indexes; register the migration first
- [x] 4.3 Install change capture in every create migration with the specified exclusions
- [x] 4.4 Test values, operation classification including helper soft deletes, rollback, no-op updates, SQLKit writes, append-only behavior, full revert, and grants after revert and migrate
- [x] 4.5 Test sensitive-value exclusion for invitations, users, and revocations

## 5. Attribution

- [x] 5.1 Add `TRUSTED_PROXY_COUNT` and client IP resolution, with spoofing and hop-count tests
- [x] 5.2 Add `AuditContext`, `Request.auditContext`, and `db.auditedTransaction`
- [x] 5.3 Wrap controller and model write paths, including `PATCH /me`, invitations, logout, and platform routes
- [x] 5.4 Pass context through approval submit, approve, reject, withdraw, override, and failure recording, with approval request IDs on applied changes
- [x] 5.5 Add required `--operator` to `platform-admin`; give `approval-override` operator context and `prune-revoked-tokens` system context
- [x] 5.6 Test the actor recorded on every direct write path and command, including a final approver and an unbound logout
- [x] 5.7 Test fail-closed writes through a real runtime-role connection, and `database` attribution for an owner edit

## 6. Coverage

- [x] 6.1 Add the catalog-based `auditCoverageProblems(on:)` check with the named global list
- [x] 6.2 Add a test requiring no problems, and negative cases for a missing trigger, disabled trigger, and unclassified table
- [x] 6.3 Add the `audit-verify` command with a non-zero exit on problems, including unsafe role grants

## 7. Read APIs

- [x] 7.1 Add `audit_event:read`, update templates, and test template membership
- [x] 7.2 Add `GET /audit-events` with DTO visibility rules, filters, paging, order, and OpenAPI documentation
- [x] 7.3 Test permission failure, non-membership, tenant isolation, hidden global events, hidden platform IP, and invalid filters
- [x] 7.4 Add `GET /platform/audit-events` with OpenAPI documentation, and test global-only results and non-administrator rejection

## 8. Finish

- [x] 8.1 Run the full test suite and regenerate the published OpenAPI output if the repository tracks it
- [x] 8.2 Add a CI job that bootstraps twice, runs the tests as the owner, migrates, and runs `audit-verify`
