## Context

`DatabaseSettings.postgresConfiguration()` sets `trustRoots = .file(path)` and builds an `NIOSSLContext` to validate it. NIOSSL's `loadVerifyLocations` accepts a directory as a CA directory, so a directory passes startup. A demo against the current code gave these results:

| `DATABASE_CA_FILE` | `.file` in `NIOSSLContext` (current) | `NIOSSLCertificate.fromPEMFile` |
| --- | --- | --- |
| Garbage file | Rejected | Throws `failedToLoadCertificate` |
| Empty file | Rejected | Throws `failedToLoadCertificate` |
| Directory | **Accepted** | Throws `failedToLoadCertificate` |
| Missing path | Rejected | Throws `failedToLoadCertificate` |

A second demo sent real failures through `ProblemMiddleware`, with a row value in each:

| Failure | Logged `error` | Row value in log |
| --- | --- | --- |
| Fluent model with the wrong field type | `FluentError.invalidField column=email` | No |
| `SQLRow.decode` with the wrong type | `PostgresDecodingError column=n` | No |

The redaction works, but no test protects either branch.

## Goals / Non-Goals

**Goals:**
- Fail at startup for every invalid `DATABASE_CA_FILE`, as the spec requires.
- Protect CA loading and database log redaction with tests that fail if the behavior regresses.
- Record evidence for hostname verification, which the previous demo table did not cover.

**Non-Goals:**
- See the proposal's Non-goals.

## Decisions

### 1. Load the CA bundle with `NIOSSLCertificate.fromPEMFile`

Set `trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(path))`. The demo above shows it rejects all four invalid inputs with one code path, and a single `NIOSSLContext` can then be built for `require`, removing `customContext`. The file is still loaded in `disable` mode, so a bad path never waits for a later switch to `require` to surface. Vapor's [Fluent overview](https://docs.vapor.codes/fluent/overview/) shows the `tls:` parameter but not trust roots, so the demos are the evidence.

Rejected:
- Check for a directory, then keep `.file`: this adds a second validation path beside NIOSSL's own.
- Keep accepting directories: the variable is documented as a file, and the spec calls for a PEM bundle.

### 2. Test redaction with real failures

Tests trigger a decoding failure through a route, using a test model that maps `users.email` to `Int` and a `SQLRow.decode` of text as `Int`. Each asserts the status, the safe diagnostic and the absence of the row value. Constructing the errors by hand would not prove what Fluent and PostgresKit actually throw.

Rejected:
- Rely on the existing unique-constraint test: it only reaches the `PSQLError` branch.

### 3. Verify hostnames by demo

Hostname checks need a TLS Postgres with a certificate for a different name, which the release-image demos already set up. Adding this to `swift test` would make the suite depend on TLS containers and certificate generation for one scenario.

Rejected:
- Automated TLS container test: too much machinery for a setting that the code does not implement itself.

### 4. Remove the `fetch` parameter

Every `JWKSRefresher.fetch` closure ignores its `Application`, so it becomes `@Sendable () async throws -> Data`.

## Risks / Trade-offs

- [`.certificates` behaves differently from `.file` for a multi-certificate bundle] → NIOSSL adds each certificate as a root. The demo repeats the private-CA connection and loads the shipped RDS bundle.
- [A deployment already uses a CA directory] → It now fails at startup with `Invalid DATABASE_CA_FILE`, which is visible and fixed by naming one bundle. Rollback is a redeploy of the previous image.

## Migration Plan

Archive `fix-api-deployment-blockers` before archiving this change. No deployment steps apply unless `DATABASE_CA_FILE` names a directory.

## Verification

Built the release image and ran `migrate --env production --yes` as its default
`vapor` user against a disposable PostgreSQL 18 server with a private CA. The
server had two Docker DNS names, and its certificate covered only
`open-erp-followups-tls-db`.

| Scenario | Result |
| --- | --- |
| Private CA, wrong hostname | TLS rejected `wrong-followups-host` with `failedToValidateHostname`. |
| Private CA, matching hostname | Migrations completed successfully. |
| Bundled RDS CA, matching hostname | Startup loaded the bundle. The database connection failed with `CERTIFICATE_VERIFY_FAILED`. |
| CA path set to `/app/certs` | Startup failed with `Invalid DATABASE_CA_FILE`. |

The initial release image gave `/app/certs` mode `0644`. The Dockerfile now
sets it to `0755` so the `vapor` user can traverse it and read the bundle.

Both decoding tests passed with their diagnostics branches present. Removing
each branch separately caused its test to fail on the expected diagnostic
assertion. Both branches were restored. The OpenAPI exports matched byte for
byte.

The full Swift suite passed 88 tests against a separate disposable PostgreSQL 18 database.
