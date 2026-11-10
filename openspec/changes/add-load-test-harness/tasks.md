## 1. Stack

- [x] 1.1 Add `LoadTests/compose.yml` with project name `open-erp-loadtest`, its own db volume, app/worker/k6/oidc-stub services, CPU and memory limits, and `grafana/k6` pinned by digest
- [x] 1.2 Add `LoadTests/reports/` to `.gitignore`
- [x] 1.3 Add `LoadTests/run.sh`: refuse unless the database is `open_erp_loadtest`, build, start, seed, measure, sample pg, write the report, then tear down (`--keep` skips teardown). Verify a wrong `DATABASE_NAME` exits before any request.

## 2. OIDC stub

- [x] 2.1 Create the `LoadTests/OIDCStub` Swift package (Vapor + JWTKit) serving JWKS, `POST /token` and `/userinfo`
- [x] 2.2 Verify the production-mode API accepts a stub token on `GET /me` and rejects a token signed by a second, unpublished key with 401

## 3. Seeding

- [x] 3.1 Write `k6/seed.js`: platform admin via CLI, organizations, invitation acceptance, members with a reduced-permission role, companies, subscriptions to `.invalid` hosts, event-producing writes
- [x] 3.2 Run the worker until the dispatch backlog is empty, then stop it. Verify that deliveries and failed attempts exist and that seeded companies have audit events naming the seeding actor.
- [x] 3.3 Read dataset sizes from `LoadTests/config.json`

## 4. Scenarios

- [x] 4.1 Write `k6/lib/steps.js`: build step scenarios with `constant-arrival-rate` and `startTime`, plus per-step tagged thresholds (p95 budget, error rate under 1%, sent arrivals at least 95%)
- [x] 4.2 Add the user scenarios (6 routes)
- [x] 4.3 Add the company scenarios (5 routes). Delete creates its own company in the same iteration; only the delete is tagged `measured`.
- [x] 4.4 Add the webhook scenarios (17 routes). Delete and disable create their own subscription first.
- [x] 4.5 Add list variants: default order with page size 100, plus one declared filter each
- [x] 4.6 Add the mixed weighted scenario
- [x] 4.7 Add the coverage check against `/openapi.json`. Verify that removing one scenario fails the run and names the route.

## 5. Isolation checks

- [x] 5.1 Add the background negative scenario: wrong organization header, cross-tenant IDs, missing permission, invalid or expired token, with an `isolation_failures` counter thresholded at `count==0`
- [x] 5.2 Verify a deliberately mis-scoped expectation (for example, expecting 200 on a cross-tenant ID) fails the run

## 6. Report

- [x] 6.1 Write `handleSummary`: supported RPS per endpoint (with "≥" when no step failed), the first failing step, p50/p95/p99 and error rate per step, and generator-bound marking
- [x] 6.2 Merge peak runtime-role connections from the pg sampler, git SHA, limits, host CPU count, pool setting and dataset sizes
- [x] 6.3 Verify both report files contain no `whsec_` value or bearer token

## 7. Documentation

- [x] 7.1 Add a README "Load testing" section: prerequisites, the one command, how to read supported RPS, what the harness doesn't cover, and the macOS Docker caveat
