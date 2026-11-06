## Context

Writes go through about ten Fluent transactions, plus a few standalone writes such as `PATCH /me` and token revocation. A gated `PATCH` may return `202` while the row changes later during the final approver's request, so HTTP outcomes do not describe data changes. CLI commands also write without HTTP. One superuser currently owns the schema and serves the API in Compose.

## Goals / Non-Goals

**Goals:**
- Atomic, complete change evidence for every application table.
- Reliable attribution for HTTP and operational writes.
- Tenant-readable evidence without cross-tenant exposure.
- A runtime database role that cannot tamper with evidence.
- A CI failure when a new table bypasses this model.

**Non-Goals:**
- Webhook delivery, security event logging, row-level security, purging, partitioning, and RDS Proxy tuning, as listed in the proposal.

## Decisions

### Capture changes with one shared Postgres trigger

An `AFTER INSERT OR UPDATE OR DELETE` row trigger runs one shared function, attached by a `createChangeTrigger(on:redact:)` helper in each create migration. `OLD`/`NEW` provide values, and the event commits or rolls back with the write. [PostgreSQL trigger functions](https://www.postgresql.org/docs/current/plpgsql-trigger.html) expose these records.

The operation is `create`, `update`, `delete`, `soft_delete`, or `restore`. A `deleted_at` transition selects the last two. An update with no column changes records nothing.

Rejected:
- Route middleware: no values, not atomic, wrong for `202` flows, and misses CLI writes.
- [Fluent model middleware](https://docs.vapor.codes/fluent/model/#lifecycle): receives only the model and `Database`, and misses SQLKit writes such as token revocation.

### Pass context explicitly and store it with `set_config`

`Request.auditContext` derives actor, IP, and request ID from data already on the request. Commands construct their own context. `db.auditedTransaction(context) { db in ... }` calls `set_config('audit.context', json, true)`, which [lasts only for the current transaction](https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADMIN-SET), then runs the body. No new middleware is needed.

Invitation acceptance replaces the context once the user is resolved, so only binding or creating that user is attributed to the bare identity. Approval actions accept the context as a parameter and add the approval request ID when applying a held change. Their failure path passes it to its separate transaction too.

Rejected:
- `@TaskLocal`: Fluent starts the async transaction closure from a future callback, so inheritance is not reliable.
- A row-per-transaction context table: avoids a possible RDS Proxy pinning cost, but adds a lookup and table for an unconfirmed deployment.

### Treat RDS Proxy as a deployment check

Nothing is deployed and pinning affects connection reuse, not the correctness of transaction-local settings. [AWS documents](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-pinning.html) that setting variables can pin on PostgreSQL. All use of `set_config` stays in `auditedTransaction`, so the mechanism can change without touching callers. If RDS Proxy is chosen, measure `DatabaseConnectionsCurrentlySessionPinned` before go-live.

### Fail closed for runtime roles

When context is absent:
- The trigger records `actor_type = database` and the session user if that user is a superuser or a member of the audit table's owner role.
- Otherwise it raises an error and the write rolls back.

The function must treat an empty setting as missing because a reverted custom setting can read as an empty string rather than `NULL`. `session_user` is always stored, because it remains the connecting role inside a `SECURITY DEFINER` function.

Rejected: recording null actors for every role, which makes a missing context silent in production.

### Keep tenancy on the row

The 9 tenant-owned tables without `organization_id` gain a required column: `approval_decisions`, `approval_policy_slots`, `approval_policy_versions`, `approval_request_tracks`, `company_users`, `group_companies`, `group_members`, `group_roles`, and `role_permissions`. Parents add a [composite unique constraint](https://docs.vapor.codes/fluent/schema/#unique) on `(organization_id, id)`. Every reference from a tenant-owned table to a tenant-owned parent becomes a composite foreign key, so a child cannot reference another tenant's parent. This includes tables that already have the column: `approval_policies.company_id`, `organization_invitations.group_id`, and `organization_invitations.approval_request_id`. Nullable references stay valid because a composite key with a null column is not checked. The Vapor docs show only single-column foreign keys, so this relies on FluentKit's `foreignKey(_:references:_:)` array overload and is covered by the schema tests.

The trigger reads `organization_id` from the row. For `organizations` it uses `id`. `users` and `revoked_access_tokens` stay global because users can belong to many organizations and revocations belong to an identity.

Rejected:
- `organization_id` on `users`: conflicts with multi-organization membership.
- Tenant from context: a platform or invitation flow could misattribute it, while the row is authoritative.

### Exclude secrets but record that they changed

`createChangeTrigger` takes columns to omit from stored values. Omitted columns still appear in `changed_fields`. The exclusions are `organization_invitations.token_hash`, `users.auth_subject`, and `revoked_access_tokens.fingerprint`.

`record_id` is the row's UUID `id` and is null for `revoked_access_tokens`, whose key is a credential fingerprint.

### Separate schema and runtime roles

An idempotent bootstrap creates the owner and runtime roles, and an `audit` schema owned by the owner. It grants the owner `CREATE` on `public` and revokes `CREATE` from `PUBLIC`, because [PostgreSQL 15 and later do not give ordinary users that privilege by default, while upgraded databases can still have it](https://www.postgresql.org/docs/current/ddl-schemas.html). `CreateAuditEvent` requires that schema and places the table there with [`schema(_:space:)`](https://docs.vapor.codes/fluent/schema/#setting-model-space). The owner has no database-level `CREATE`, so a migration could not create the schema anyway. Reverting drops the table and functions and leaves the schema, which keeps its default privileges and `USAGE` grant. [Schema-scoped default privileges](https://www.postgresql.org/docs/current/sql-alterdefaultprivileges.html) give the runtime role `SELECT, INSERT, UPDATE, DELETE` in `public` and only `SELECT` in `audit`, so migrations do not need role names. `TRUNCATE`, `TRIGGER`, and `REFERENCES` are not granted.

The trigger function is [`SECURITY DEFINER` with a pinned `search_path`](https://www.postgresql.org/docs/current/sql-createfunction.html#SQL-CREATEFUNCTION-SECURITY), so runtime can cause an insert into `audit_events` but cannot insert directly. `audit_events` is also append-only and, like every append-only table, rejects `TRUNCATE`.

The existing `createAuditTrigger`, which enforces immutability, is renamed `createAppendOnlyTrigger` to distinguish it from change capture.

The runtime role receives default DML on `_fluent_migrations` when the table is created. The operator runbook revokes it after the first migration, and `audit-verify` reports it until then.

### Verify coverage against the catalog

`auditCoverageProblems(on:)` queries the Postgres catalog for every base table in `public`. It requires an enabled change trigger, and either a required `organization_id` or membership in the named global list. Only `_fluent_migrations` is exempt. A test requires an empty result. `audit-verify` reports the same problems, for post-deploy drift checks. It also reports any login role outside the owner role, other than a superuser, that can write to `audit.audit_events` has `TRUNCATE` or `TRIGGER` on an application table, or can write to `_fluent_migrations`. This needs no fixed role names.

### Read APIs expose evidence, not a stable schema

`GET /audit-events` returns only the caller's tenant, ordered by `createdAt` descending and then `id`. `GET /platform/audit-events` returns only global events (`organization_id IS NULL`), so platform access still does not expose tenant data. Table and column names appear as stored because they are evidence. Future webhooks will be the stable integration contract.

Tenants see actor name only for `operator` and `system` actors, and IP only for `user` actors. Platform administrator IPs and database session users are not exposed to tenants.

### Resolve IP from trusted hops

`req.peerAddress` trusts `Forwarded` and `X-Forwarded-For` from any client (see `Request.swift` in Vapor) and returns nil for a multi-hop list. `TRUSTED_PROXY_COUNT` defaults to 0, which uses `req.remoteAddress`. A value of N selects the Nth address from the right of `X-Forwarded-For`, and falls back to `remoteAddress` if the header is too short or invalid. `Forwarded` is ignored.

### Retain indefinitely without partitioning

No code path deletes audit events. Indexes on `(organization_id, created_at DESC, id)` and `(organization_id, table_name, record_id)` serve reads. Partitioning is deferred because there is no partition-drop requirement, and a missing partition could block every write.

## Risks / Trade-offs

- [Owner or superuser can disable triggers or edit evidence] → Keep those credentials out of the API, restrict their use, and run `audit-verify` after deployments. Database-platform logging is a deployment control.
- [Tests run as the owner, so a missing context records `database` rather than failing] → Test each direct write path for its actor, and test fail-closed behavior with a real runtime-role connection.
- [Personal data in immutable records conflicts with erasure requests] → Open question; no erasure path ships here.
- [The runtime role can forge `audit.context`] → The API is the trusted writer. A compromised API is not fully contained, but it still cannot rewrite prior evidence.
- [Audit storage grows without bound and doubles writes] → Accepted for retention. Measure before production and revisit partitioning if needed.
- [The soft-delete helper writes `deleted_by` first, so one soft delete records `update` then `soft_delete`] → Accept it as an accurate record. A future webhook mapping must not treat the first event as a public update.
- [`audit_event:read` exposes values from every audited tenant table, including those a reader's other permissions would hide] → Treat it as a sensitive grant and document it. Both organization templates hold it because it is a read permission.
- [Transaction IDs can repeat after a dump and restore] → Use them with event time for grouping only, never as an identifier.
- [New write paths may forget context] → Runtime rejects them in production-like roles, and the path test covers known writes.

## Migration Plan

This is pre-release, so create migrations are edited in place under the migration policy. Developers recreate local databases with `docker compose down -v`. Migrations require the bootstrap. For the first deployment: run the bootstrap as an administrator, migrate as owner, run the documented `_fluent_migrations` revoke, then serve as runtime and run `audit-verify`. Rollback before release is a full migration revert.

## Open Questions

- Should tenants see `users` changes for their members? Global user rows are hidden from tenants for now because a change has no tenant and can predate membership.
- What is the personal-data erasure policy for retained audit events?
- How is a soft-deleted organization's evidence read? Tenant access ends at deletion and the platform API returns only global events, so it is available only through the database for now.
