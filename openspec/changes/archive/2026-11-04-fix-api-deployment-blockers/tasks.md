## 1. Database settings and TLS

- [x] 1.1 Add `DatabaseSettings` parsing required variables, port, pool size, TLS mode and CA file from a lookup closure, with testing defaults; unit test missing, invalid and unknown values, and that errors contain no configured password
- [x] 1.2 Use `DatabaseSettings` in `configureServices` with `.require` or `.disable`, `trustRoots = .file(...)` when a CA file is set, and `maxConnectionsPerEventLoop`; log a warning when TLS is disabled outside testing
- [x] 1.3 Add `DATABASE_TLS_MODE: disable` to `docker-compose.yml`, and document the new variables in `.env.example`
- [x] 1.4 Add the RDS global bundle to the Dockerfile's run image at `/app/certs/rds-global-bundle.pem` using `ADD --checksum`, after confirming with the user that the bundle may be downloaded to compute the checksum
- [x] 1.5 Demo with the release image against disposable Postgres containers, recording each result: private-CA TLS without `DATABASE_CA_FILE` fails; with it, `migrate` succeeds; non-TLS Postgres under `require` fails; a missing CA file fails startup; unset `DATABASE_HOST` fails naming the variable

## 2. Authentication lifecycle

- [x] 2.1 Split `configureAuthentication` so OIDC settings load only when serving, and update `entrypoint.swift`; test that the serve path fails naming a missing variable
- [x] 2.2 Demo that `migrate --yes` and `prune-revoked-tokens` run from the release image with no OIDC variables
- [x] 2.3 Add a JWKS refresher with an injected fetch that replaces the whole key set on success and keeps the last good set on failure or an empty response; unit test added keys, removed keys, failures and empty responses
- [x] 2.4 Register the refresher as a serve-only `LifecycleHandler` with a 30-second retry until first success, then a 5-minute interval, a bounded fetch timeout, and cancellation at shutdown
- [x] 2.5 Return 503 `authentication_unavailable` for a bearer request while no keys have loaded, including logout, keeping 401 for a missing token; test with the flag unset, and confirm no WWW-Authenticate challenge
- [x] 2.6 Demo that a server started with an unreachable JWKS stays up, returns 503 for a bearer token, and starts verifying after the JWKS becomes reachable, without a restart

## 3. Health and public routes

- [x] 3.1 Add `GET /health` excluded from OpenAPI, returning 200 or a generic 503 problem; test ready, database failure and keys-not-loaded, and that `X-Organization-ID` does not change the response
- [x] 3.2 Remove `GET /` and `GET /hello`, update `APIDocumentationTests` route allowances, and test that both return the 404 problem
- [x] 3.3 Confirm `export-openapi` output is unchanged from the current contract

## 4. Log safety

- [x] 4.1 Add a failing test in which a real unique-constraint violation reaches `ProblemMiddleware`, proving the submitted email appears in the logged diagnostics today
- [x] 4.2 Add the allowlisted diagnostics helper for `PSQLError` and `PostgresDecodingError`, and make the test pass with SQLSTATE and constraint present and the value absent; keep the existing `InternalFailure` assertions passing

## 5. Pool default

- [x] 5.1 Run a concurrency demo with the release image at `--cpus=1`, comparing 1 and 4 connections per event loop under concurrent approval writes and reads, and record the results in this change
- [x] 5.2 Confirm or change the default based on the demo, and resolve the design's open question

## 6. Documentation and verification

- [x] 6.1 Update `README.md`: new variables, RDS setup including the bundle path and RDS Proxy note, pool formula, operational commands without OIDC, JWKS refresh window, `/health`, the route table, and the `authentication_unavailable` recovery text
- [x] 6.2 Run `swift test` against a disposable Postgres, never the local development database
- [x] 6.3 Run `openspec validate fix-api-deployment-blockers --strict`
- [x] 6.4 Run the `open-erp-ui` Playwright suite against the new binary from a disposable copy with `DATABASE_TLS_MODE=disable`, and report the one-line environment change that repo needs

## 7. Review fixes

- [x] 7.1 Decode and add JWKS entries one at a time so an unusable entry cannot block rotation; test unsupported algorithm, key type and curve, and a key without a `kid`
- [x] 7.2 Log the reason for a failed refresh and the count of ignored entries
- [x] 7.3 Log `PSQLError.code` and the `/health` failure reason, keeping the `/health` response generic
