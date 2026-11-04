## Context

`configureServices` builds the Postgres connection with `.prefer` TLS, the system trust store and fallback credentials, and always runs `configureAuthentication`, which fetches JWKS once and throws on failure. A local demo with the release image produced these results:

| Scenario | Result |
| --- | --- |
| TLS-only Postgres with a private CA, as RDS uses | `CERTIFICATE_VERIFY_FAILED` |
| Same database, `SSL_CERT_FILE` set | Still fails, so this is not a usable workaround |
| Same database, CA appended to the image's trust bundle | Migration succeeds |
| Postgres without TLS | Migration succeeds in plaintext |
| `DATABASE_*` unset | Tries `localhost` with default credentials |
| JWKS unreachable | Process exits, including for `migrate` |
| `/` with the database paused | 200 |

AWS documents that RDS server certificates come from its own CAs (`rds-ca-rsa2048-g1` by default) and that `rds.force_ssl` defaults to on from PostgreSQL 15. The image's trust store contains the public Amazon roots but no RDS CA.

## Goals / Non-Goals

**Goals:**
- Connect to RDS with verified TLS, and never downgrade silently.
- Fail early and clearly on incomplete database configuration.
- Run operational commands without identity-provider access.
- Survive key rotation and provider outages without a restart, while staying fail-closed.
- Give load balancers a meaningful readiness signal.
- Keep database-reported values out of logs.

**Non-Goals:**
- See the proposal's Non-goals. This design also leaves the existing route, permission and approval behavior alone.

## Decisions

### 1. Explicit TLS mode, defaulting to `require`

Map `DATABASE_TLS_MODE` to `PostgresConnection.Configuration.TLS.require(...)` or `.disable`. `.require` fails when the server lacks TLS, per [postgres-nio's TLS options](https://github.com/vapor/postgres-nio/blob/main/Sources/PostgresNIO/Connection/PostgresConnection%2BConfiguration.swift). Certificate verification stays on through `TLSConfiguration.makeClientConfiguration()`. Vapor's [Fluent overview](https://docs.vapor.codes/fluent/overview/) shows the `tls:` parameter, but does not discuss the modes, so the demo above is the evidence.

Rejected:
- Keep `.prefer`: the demo showed a silent plaintext downgrade.
- Default to `disable` outside production: a forgotten setting would fail open.
- Forbid `disable` in production: `docker-compose.yml` deliberately runs production mode against a local non-TLS database, so a loud warning is used instead.

### 2. CA bundle by path, with the RDS bundle in the image

`DATABASE_CA_FILE` sets `TLSConfiguration.trustRoots = .file(path)`, which replaces the system store. This is narrower than adding to it, and keeps the code provider-neutral. The Dockerfile adds the [RDS global bundle](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html) at `/app/certs/rds-global-bundle.pem` using `ADD --checksum`. Deployments opt in by setting the variable. RDS Proxy uses public ACM certificates, so it needs no CA file.

Rejected:
- Append the bundle to the OS trust store: this works, but it widens trust for every outbound client, including the identity-provider calls.
- `SSL_CERT_FILE`: the demo showed it has no effect.
- Require deployments to mount the bundle: this adds a step to every deployment for a file that rarely changes.

### 3. Validate settings in one small value

A `DatabaseSettings` value parses a lookup closure, which keeps it testable without changing process environment. It follows the existing `requiredEnvironment` pattern and names only the variable in errors. It applies to every environment except testing, which keeps its local defaults.

Rejected:
- `DATABASE_URL`: `SQLPostgresConfiguration(url:)` defaults to `prefer`, and a move to one variable is an unrelated migration.

### 4. Pool setting with a default of 4 per event loop

Pass `maxConnectionsPerEventLoop` to [`DatabaseConfigurationFactory.postgres`](https://docs.vapor.codes/fluent/overview/). The framework default is 1, and NIO's `System.coreCount` honors cgroup CPU limits while Vapor uses it for the event-loop count, so a 1 vCPU task gets one connection. Approval writes hold that connection for a whole transaction. The mixed-load comparison below supports the default of 4. Vapor's event loops multiply it, so the README gives the formula against `max_connections`.

Rejected:
- Keep 1 and scale out: this buys capacity with instances to work around a single setting.
- Fix a higher number without a setting: instance sizes and database limits vary.

### 5. Require OIDC only when serving

`entrypoint.swift` already branches on the command name for `export-openapi`. It extends that branch so services are configured with authentication only when the command is `serve` or absent, which is [Vapor's default command](https://docs.vapor.codes/advanced/commands/). Vapor's `Environment.detect` strips `--env` first, so flag order is not a concern. The testing environment still installs its local key.

Rejected:
- Stub JWKS for commands: this leaves a required secret on tasks that never use it.

### 6. Periodic JWKS refresh in a lifecycle handler

A `LifecycleHandler` ([Vapor services: Lifecycle](https://docs.vapor.codes/advanced/services/)), registered only when serving, starts a task in `didBootAsync` and cancels it in `shutdownAsync`. It retries every 30 seconds until the first success, then refreshes every 5 minutes. Each success builds a new `JWTKeyCollection` and assigns it to `app.jwt.keys`, whose [setter jwt exposes](https://docs.vapor.codes/security/jwt/), so removed keys disappear. Entries are decoded and added one at a time, because `JWKS` decoding and `add(jwk:)` throw on a single unsupported entry; unusable entries are skipped and counted. Each fetch has a bounded timeout. A `signingKeysLoaded` flag backs `/health` and the 503 check, and it is set by the testing key path too.

The 503 check sits in `verifiedAccessTokenIgnoringRevocation` after the missing-token check, so both protected routes and logout share it.

Rejected:
- `EndpointCache` on each request, as `jwt`'s Google helper does: `get(on: request)` calls `download` directly and skips the cache, and on an expired entry a failed fetch fails verification, so there is no outage tolerance.
- Refetch on an unknown `kid`: jwt-kit falls back to the default signer for an unknown `kid`, so misses are not signaled, and a forged header could trigger outbound fetches.
- Fail the refresh on any unusable entry: one key the server cannot use would stop rotation and keep removed keys trusted.
- Keep the startup crash: an identity-provider outage would then block scaling and deployments, and also require a restart to recover.

### 7. One deep `/health` endpoint

The route runs `SELECT 1` and checks `signingKeysLoaded`, responding 200 or a generic 503. It is excluded from OpenAPI. An [ALB fails open](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html) when every target is unhealthy, so a database outage does not remove all routes. The ALB's own timeout (5 seconds by default for IP targets) treats a hung database as failed, so the handler needs no timeout of its own.

Rejected:
- Separate liveness and readiness routes: the runtime image has no HTTP client for an ECS container health check, so only the load balancer would call them.
- Keep `/` as the check: the demo showed it stays 200 with the database paused.

### 8. Allowlisted database diagnostics

`PSQLError`'s plain description is generic by design, while [`String(reflecting:)` includes server fields](https://github.com/vapor/postgres-nio/blob/main/Sources/PostgresNIO/New/PSQLError.swift) such as `detail`, which can carry `Key (email)=(...)`. `PostgresDecodingError` can also reflect row data. A small helper in `ProblemMiddleware` logs only the error class, `PSQLError.code`, SQLSTATE, table, constraint and column fields for these types, and keeps `String(reflecting:)` for all other errors, which the existing tests expect. The code separates connection and TLS failures, which carry no server fields. `/health` puts the same diagnostics in its `Abort` reason, which `ProblemMiddleware` logs and keeps out of 5xx responses.

Rejected:
- Extend `RedactingLogHandler` with `error`: this would remove all diagnostics, not just values.
- Regex-scrub the string: this is fragile against message formats and can miss values.

## Risks / Trade-offs

- [A provider that signs with a new key immediately causes up to 5 minutes of 401s] → Most providers publish a key before signing with it. Otherwise, restarting tasks forces a fetch. The README states this window.
- [A key removed during a provider outage stays trusted until refresh succeeds] → Refresh failures log at error level so they can alert. This is preferred to locking out all users.
- [`/health` and `ProblemMiddleware` log errors on every probe during a database outage] → The volume is bounded by the probe interval, and the signal is useful.
- [A larger pool can exceed `max_connections` at scale] → The setting and the formula are documented, and the load demo informs the default.
- [The pinned RDS bundle checksum needs updating when AWS changes the bundle] → A mismatch fails the image build visibly, and the bundle is a rare, deliberate update.
- [Reduced database diagnostics make some incidents harder to debug] → SQLSTATE, constraint and table identify most failures, and Postgres server logs hold the rest under separate access controls.

## Migration Plan

1. Before pulling this change, add `DATABASE_TLS_MODE=disable` to a local `.env` that uses the non-TLS database. `docker-compose.yml` and `.env.example` are updated in the change.
2. Update the `open-erp-ui` Playwright environment with the same setting.
3. For AWS, set `DATABASE_CA_FILE=/app/certs/rds-global-bundle.pem`, and point the load balancer's health check at `/health`.

Rollback is a redeploy of the previous image. No schema or stored data changes.

## Verification

The release image was tested against disposable PostgreSQL 18 containers.

| Scenario | Result |
| --- | --- |
| Private CA without `DATABASE_CA_FILE` | Rejected with `CERTIFICATE_VERIFY_FAILED`. |
| Private CA supplied | `migrate --yes` succeeded with OIDC variables absent. |
| Plaintext PostgreSQL in `require` mode | Rejected with `sslUnsupported`. |
| Missing CA file | Startup failed with `Invalid DATABASE_CA_FILE`. |
| Unset database host | Startup failed with `Missing DATABASE_HOST`. |
| Pruning without OIDC | `prune-revoked-tokens` succeeded. |
| Serving without OIDC | Startup failed with `Missing OIDC_ISSUER`. |
| JWKS unreachable at startup | The same container returned bearer and health 503s before the provider started, then returned 200 for the signed bearer and for health after retry. |

### Pool comparison

Each run used the release image with `--cpus=1` and 16 concurrent clients.
Each round completed 120 approval detail reads and 120 withdrawal transactions
against fresh approval requests. All 960 measured requests returned HTTP 200.

| Connections per event loop | Wall time (ms) | Read p95 (ms) | Write p95 (ms) |
| --- | ---: | ---: | ---: |
| 1 | 1,122 | 110.7 | 65.1 |
| 4 | 962 | 101.4 | 89.0 |
| 4 | 1,012 | 102.9 | 93.1 |
| 1 | 1,240 | 126.9 | 70.2 |

Keep the default of four. In this mixed workload it improved total completion
time and read tail latency in both rounds, with a higher write p95. Deployments
can tune the setting for their connection budget and workload.

### API and browser suites

The full Swift suite passed all 84 tests against disposable PostgreSQL. The
OpenAPI export matched the baseline byte for byte.

Playwright ran against the new API from a disposable UI copy with
`DATABASE_TLS_MODE=disable` and separate loopback ports. It passed 23 of 25
tests, including all 17 platform scenarios. Two mocked approvals scenarios
failed the axe `label-content-name-mismatch` check on the navigation brand
link. Its visible label is `open-erp` and its accessible name is `Open ERP`.
