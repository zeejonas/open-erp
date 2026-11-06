## Why

`created_by`, `updated_by`, and `deleted_by` show only the latest actor, and logs are not atomic with the data they describe. SOX and SOC reviews need durable, tamper-resistant evidence of who changed what, from where, and with what values. Nothing is deployed yet, so this can still be built into the create migrations.

## What Changes

- Add an append-only `audit.audit_events` table, populated by a Postgres trigger on every application table in the same transaction as the write.
- Record the operation, old and new values, changed fields, and tenant, excluding credential columns from stored values.
- Pass actor, IP, request ID, and approval request ID explicitly into each write transaction. Non-owner database roles that write without this context are rejected.
- Add `GET /audit-events` for tenants and `GET /platform/audit-events` for global records, with a new `audit_event:read` permission.
- Add `organization_id` to the 9 tenant-owned tables without one, with composite foreign keys that reject cross-tenant references. `users`, `organizations`, and `revoked_access_tokens` remain global.
- Separate the database roles that own the schema and serve the API. The API refuses to start in production as a superuser or schema owner.
- Add a shared coverage check, used by a test and an `audit-verify` command, that fails when a table is unclassified or lacks an enabled audit trigger.
- Derive client IPs from the socket and a configured number of trusted proxies, because `req.peerAddress` trusts client-supplied headers.
- **BREAKING**: `platform-admin` requires `--operator`.
- **BREAKING**: Docker Compose runs migrations and the API under different roles, so local databases must be recreated.

## Non-goals

- Webhook delivery, subscriptions, or an outbox. This design keeps them additive.
- Logging denied requests, failed logins, or sensitive reads, tracked separately.
- Row-level security. Tenant columns make it possible later.
- Purging or archiving audit events, or partitioning the table.
- Deployment-specific RDS Proxy work.

## SOX/SOC Impact

- **Audit trail**: every committed write produces evidence atomically, including CLI and direct database writes.
- **Access control**: the API role cannot alter audit events or disable triggers. Tenant reads require an explicit permission and only return that tenant's events.
- **Segregation of duties**: schema ownership is separated from runtime access, and applied approvals link to their approval request. Owners and superusers keep the ability to change triggers, so those credentials need deployment controls.

## Capabilities

### New Capabilities

- `audit-trail`: Change capture, attribution, sensitive-value exclusion, coverage verification, and audit read APIs.
- `database-access-control`: Owner and runtime database roles, least-privilege grants, and the startup guard.

### Modified Capabilities

- `database-schema`: Tenant-owned tables carry `organization_id` with composite tenant foreign keys, and create migrations install audit triggers.
- `organization-rbac`: Adds `audit_event:read` to the permission catalog and route permissions.
- `service-runtime`: Adds trusted-proxy client IP resolution.

## Impact

- **Migrations**: all create migrations are edited in place and `CreateAuditEvent` is registered first.
- **Code**: models and write paths for the 9 tables, every write transaction, approval actions, and operational commands.
- **API**: two new read endpoints in the OpenAPI document and one new permission.
- **Operations**: new `TRUSTED_PROXY_COUNT`, role bootstrap SQL required before migrating, separate migration credentials, a CI job, Compose and README updates.
- **Storage**: audit events are retained indefinitely, so the table grows without an automatic purge.
