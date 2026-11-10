## Context

The API runs in production mode only with real OIDC configuration (`OIDC_ISSUER`, `OIDC_AUDIENCE`, `OIDC_JWKS_URL`, `OIDC_USERINFO_URL`) and the safe runtime role. Users exist only after accepting an invitation, and organizations come only from `POST /platform/organizations`, which needs a platform administrator. The webhook worker is a separate process. Each process opens at most event loops × `DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP` connections, and the default is 4 per loop. Nothing in the repository measures throughput.

```
 run.sh ──▶ docker compose -p open-erp-loadtest
             ├── db         postgres:18-alpine, own volume
             ├── oidc-stub  JWKS · /token · /userinfo
             ├── app        production image, cpus/mem limited
             ├── worker     seeding only, then stopped
             └── k6         seed.js → scenarios.js → handleSummary
                              │
                 pg sampler ──┴──▶ reports/<timestamp>/report.{md,json}
```

## Goals / Non-Goals

**Goals:**
- A supported-RPS figure for each of the 28 user, company and webhook routes, measured the same way every run
- Results that compare across runs: the same image, CPU limits, dataset and step plan
- Production behavior on every request path: JWT verification, the RBAC middleware, audit triggers and event production

**Non-Goals:**
- CI gates
- Outbound worker throughput
- Routes outside users, companies and webhooks
- Application metrics
- Database TLS in the harness (see Risks)

## Decisions

**k6 in a pinned container drives the load.** The `constant-arrival-rate` executor is open-model: it keeps sending at the target rate however slowly the server responds, so saturation shows up as latency and dropped iterations instead of being hidden (k6 docs: Scenarios → Executors → constant-arrival-rate). Steps are separate scenarios, set apart with `startTime`. Per-step `thresholds` on tagged metrics decide pass or fail. `handleSummary` writes the JSON and Markdown report (k6 docs: Results output → End-of-test summary).
- Rejected: wrk/oha. They are closed-model and can't script multi-step or tenant-aware flows.
- Rejected: Gatling/Locust. They need a JVM or Python toolchain for no added value.
- Rejected: XCTest `measure`. It runs in-process and doesn't exercise the HTTP stack.

**The OIDC stub is a separate Swift package (`LoadTests/OIDCStub`) using jwt-kit and Vapor.** It creates an ES256 key at startup, serves `/.well-known/jwks.json`, mints tokens at `POST /token {sub, email}`, and answers `/userinfo` by echoing the `email` claim of the bearer token it issued. Using the same jwt-kit as the API means the stub signs exactly what the API verifies (Vapor docs: Security → JWT; api.vapor.codes JWTKit `ES256PrivateKey`). The API reaches it over plain HTTP inside the Compose network. If `close-encryption-gaps` lands first, the harness sets that change's explicit insecure-OIDC opt-out.
- Rejected: an Auth0 test tenant. It needs the internet, rate-limits token minting and holds external credentials.
- Rejected: a testing-environment build. `.testing` skips the production role checks and uses the testing key path, so the results wouldn't reflect production.

**Seeding goes through the CLI and the API in `seed.js`, which runs once in k6 `setup()`.** The order is: `platform-admin` (via `docker compose run`) → `POST /platform/organizations` → admin invitation accepted with a stub token → member invitations → companies → subscriptions pointing at `https://loadtest-<n>.invalid/hook` → company writes that produce events. Then the worker runs until the dispatch backlog is empty and is stopped. RFC 6761 guarantees `.invalid` never resolves, so attempts fail locally and are recorded. Seeding through the API keeps it in step with the migrations, which are edited in place before release; a SQL seed would drift silently.
- Rejected: a SQL seed file. It bypasses RBAC and event production, and breaks whenever a create migration is edited.
- Rejected: a `loadtest-seed` app command. That would put test-only code in the production binary.

**One scenario per route, with a default step plan.** The plan is 25, 50, 100, 200, 400, 800 and 1600 RPS, 30 s per step, with 10 s pauses between scenarios. Latency budgets are 300 ms p95 for reads and 500 ms p95 for writes. All of it can be overridden in `LoadTests/config.json`. A scenario that consumes a resource (delete, disable) creates the resource first in the same iteration, and only the consuming request carries the `measured` tag. The coverage check reads `/openapi.json`, filters to the three route groups, and compares that list with the scenario registry before any load runs.

**Tokens are minted per virtual user in `setup()` with a one-hour lifetime.** Token creation stays outside the measured path, and the API's JWT verification cost is still paid on every request.

**Isolation checks run as their own low-rate scenario (5 RPS) for the whole run,** at the same time as each endpoint step. A failure increments a counter whose threshold is `count==0`, and that failure fails the run.

**A pg sampler reports peak connections.** `run.sh` polls `SELECT count(*) FROM pg_stat_activity WHERE usename = 'open_erp_runtime'` once a second and records the maximum for each scenario window. This shows whether the pool ceiling (cores × 4) was reached without adding any application code (PostgreSQL docs: Monitoring → pg_stat_activity).

**Resource limits are fixed.** The app gets `cpus: 2` and `mem_limit: 1g`, and the database gets `cpus: 2`, set in the Compose override. Event loops follow the CPUs Swift sees, so the report states the effective loop count. The limits can be overridden, and the report records whatever was used.

**Implementation notes.**
- All services share an `internal: true` Compose network. Nothing in the run needs the internet, and seeded deliveries can't reach a resolver outside the host.
- Writes that grow the dataset (company create, subscription create, patch and disable) clean up in the same iteration with an unmeasured delete. This keeps later scenarios on the same dataset and stays under the 100-subscription limit per organization.
- Setup and cleanup requests count toward a step's rate (`requests` per route), so a step's rate is the load the API receives. A smoke run that counted only the measured request sent twice the writes, saturated both app and database CPUs, and made company create and delete look 30× slower than they are alone.
- Subscription writes run at `steps.lowFrequencyRates`. Creates take the organization lock to enforce the 100-subscription limit, so at hundreds of RPS they queue on that lock (about 11 ms mean wait in `pg_stat_statements`) and hit the limit; neither reflects real traffic.
- Reads run before writes, lists use the default page size, and company patches use a row per VU, because concurrent patches of one company correctly return 409. A `per=100` event-list variant stays: full pages cost about 10 ms of app CPU each, which caps that list near 100 RPS per app CPU.
- Seeded actors are administrators (`org_admins`, used for writes and payload or secret reads) and viewers (`org_viewers`, used for reads and the missing-permission checks). Only a few subscriptions are enabled, each filtered to a few companies, so delivery history stays around a thousand rows.
- The worker runs until the dispatch queue is empty and every delivery has at least one attempt.
- Step verdicts come from k6 thresholds, so k6 exits 99 whenever a step saturates. `run.sh` accepts that exit code. A separate `report.js` k6 run merges the pg samples and sets the run verdict: an isolation failure, or a secret disclosure by a non-administrator (counted in the database), fails it.

## Risks / Trade-offs

- [Docker on macOS adds virtualization overhead, so absolute RPS will be lower than on Linux hosts] → The report records host and limits. Compare runs on like hosts, and treat the figures as relative.
- [The harness turns database TLS off, which removes the handshake cost] → Connections are pooled and long-lived, so handshakes are rare. The report records `DATABASE_TLS_MODE`. Postgres TLS in Compose can come later.
- [k6 and the app share the host's CPUs] → k6 runs with its own `cpus` limit. If the step's `dropped_iterations` shows k6 itself saturated, the report marks the step "generator-bound".
- [Seeding through the API is slow for large datasets] → Default sizes are modest (2 orgs × 50 members × 500 companies × 20 subscriptions, plus about 5k events) and can be configured.
- [Secret disclosure under load writes many disclosure records] → They are only in the disposable harness database, which run.sh removes at the end unless `--keep` is passed.

## Migration Plan

This is additive tooling and touches nothing in the application. To roll back, delete `LoadTests/`.

## Open Questions

- Should one baseline report be committed for each release tag as capacity evidence? The default is no: reports stay git-ignored.
