## Why

No endpoint has a measured throughput. The README says to measure before changing `DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP`, replica counts or webhook limits, but there is no repeatable way to do that. Operators need a supported RPS figure per endpoint, the point where the connection pool saturates, and evidence that tenant isolation holds under concurrency.

## What Changes

- Add an on-demand load-test harness under `LoadTests/`, run against the production image in a Compose project isolated from development data. It is not part of `swift test` or CI.
- Cover every user, company and webhook endpoint (28 routes) with its own step-load scenario, plus one mixed workload.
- Seed tenants, members, companies, subscriptions, events and deliveries through the real API and CLI, so audit triggers, RBAC and event production run exactly as they do in production.
- Add a local OIDC stub that publishes a JWKS, mints tokens for seeded subjects and answers userinfo during seeding.
- Write a report per run: supported RPS, latency percentiles and error rate per endpoint, peak database connections, the dataset size and the configuration under test.
- Under load, assert that cross-tenant and unauthorized requests are always refused.

## Capabilities

### New Capabilities

- `load-testing`: Endpoint coverage, the supported-RPS definition, isolated seeding, the report contents, and isolation and authorization checks under load.

### Modified Capabilities

None. The harness drives the existing API contract.

## Impact

- New `LoadTests/` directory: a Compose override, a small Swift OIDC stub package, k6 scripts and a run script. The application target is unchanged.
- New tooling dependency: the `grafana/k6` container image, pinned by digest. Nothing is installed on the host apart from Docker.
- Reports go to `LoadTests/reports/`, which is git-ignored.
- SOX/SOC: no change to access control, audit or segregation of duties. Seeding uses the normal platform-admin, invitation and RBAC paths, so every seeded row is attributed and audited. The harness refuses to run against anything except its own Compose project and database. Load results become capacity-planning evidence, which supports SOC 2 availability criteria (A1.1).

## Non-goals

- CI performance gates or regression thresholds. Shared runners are too noisy.
- Load-testing the webhook worker's outbound delivery throughput. The worker only runs during seeding.
- Routes outside users, companies and webhooks: organizations, groups, roles, approvals, audit, platform and invitations.
- Production or staging load tests, and distributed load generation.
- Adding pool or latency metrics to the application.
