## 1. Database CA loading

- [x] 1.1 Add `DatabaseSettingsTests` cases proving that a garbage file, an empty file, a directory and a missing path each throw `Invalid DATABASE_CA_FILE` in `require` and `disable`, with only the directory case failing today
- [x] 1.2 Load the bundle with `NIOSSLCertificate.fromPEMFile` in `postgresConfiguration()` and remove `customContext`, making the tests pass
- [x] 1.3 Add a case in which a valid PEM fixture builds a `require` configuration

## 2. Log redaction tests

- [x] 2.1 Add a `ProblemTests` case in which a Fluent model with the wrong field type fails on a real row, asserting `FluentError.invalidField column=email` is logged and the row value is not
- [x] 2.2 Add a `ProblemTests` case in which `SQLRow.decode` fails on a real row, asserting `PostgresDecodingError column=n` is logged and the row value is not
- [x] 2.3 Temporarily remove each diagnostics branch to confirm its test fails, then restore it

## 3. Simplification

- [x] 3.1 Remove the `Application` parameter from `JWKSRefresher.fetch`, updating `OIDC.swift` and `RuntimeTests`

## 4. Demos

- [x] 4.1 With the release image and a disposable TLS Postgres on a private CA, record that a certificate for another hostname is rejected, and that the matching hostname with `DATABASE_CA_FILE` runs `migrate --yes`
- [x] 4.2 Record that `DATABASE_CA_FILE=/app/certs/rds-global-bundle.pem` passes startup validation, and that the same private-CA server is then rejected at connection
- [x] 4.3 Record that a directory as `DATABASE_CA_FILE` fails startup with `Invalid DATABASE_CA_FILE`

## 5. Verification

- [x] 5.1 Run `swift test` against a disposable Postgres, never the local development database
- [x] 5.2 Confirm `export-openapi` output is unchanged
- [x] 5.3 Run `openspec validate tighten-deployment-fix-followups --strict`
