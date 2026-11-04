## Why

The API image cannot reach an Amazon RDS database today, and several of its runtime defaults are unsafe or unworkable on managed infrastructure. A local demo showed `migrate` failing with `CERTIFICATE_VERIFY_FAILED` against a private-CA Postgres, succeeding silently in plaintext against a non-TLS Postgres, and crashing when JWKS is unreachable. These must be fixed before any AWS deployment work can succeed.

## What Changes

- **BREAKING** Require verified TLS for Postgres by default. A new `DATABASE_TLS_MODE` accepts `require` (default) or `disable`; the testing environment defaults to `disable`. The current `.prefer` behavior is removed.
- Add `DATABASE_CA_FILE` to trust a specific CA bundle, and ship the RDS global bundle in the image for deployments to select.
- **BREAKING** Fail startup when `DATABASE_HOST`, `DATABASE_USERNAME`, `DATABASE_PASSWORD` or `DATABASE_NAME` is missing, or when a numeric database setting is invalid, instead of falling back to `localhost` and default credentials. The testing environment keeps its defaults.
- Add `DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP`, replacing the framework default of one connection per core.
- Require OIDC settings and signing keys only when serving, so `migrate`, `prune-revoked-tokens`, `platform-admin` and `approval-override` run without them.
- Refresh JWKS periodically and keep the last good keys through a provider outage. A server that has never loaded keys stays up and fails closed with 503 instead of crashing at startup.
- Add a public `GET /health` readiness endpoint covering the database and signing keys.
- **BREAKING** Remove the placeholder `GET /` and `GET /hello` routes.
- Stop logging values reported by Postgres, such as unique-key details and row data, in server-error diagnostics.

**Non-goals**

- AWS infrastructure, CI/CD, and the UI image. These are separate changes.
- Rate limiting, which belongs at the load balancer or WAF for now.
- Restricting `/docs` and `/openapi.json`. The API is intended to run on a private network, and any restriction deserves its own decision.
- Structured logs, metrics, and tracing.
- A central audit log, or changing how `approval-override` identifies its operator.
- Schema changes. No migration is added or edited.

**SOX/SOC impact**

- **Access control:** verified database TLS protects credentials and financial data in transit. Removing default credentials prevents a misconfigured service from running against an unintended database. JWKS refresh lets a removed signing key stop being trusted without a restart. Authentication continues to fail closed.
- **Audit trail:** no attribution or evidence behavior changes. Log redaction reduces personal data and token hashes in operational logs while keeping the error class, SQLSTATE and constraint needed for investigation.
- **Segregation of duties:** unaffected. Operational commands need fewer secrets, which supports narrower task permissions.

## Capabilities

### New Capabilities

- `service-runtime`: database connection security, required runtime configuration, connection pool sizing, and the public health endpoint.

### Modified Capabilities

- `authentication`: OIDC settings become required only when serving, and signing keys gain a refresh and fail-closed lifecycle.
- `api-response-contract`: server-error log diagnostics exclude database-reported values, and `authentication_unavailable` also covers signing keys that have not loaded.

## Impact

- **Code:** `configure.swift`, `entrypoint.swift`, `routes.swift`, `Auth/OIDC.swift`, `Auth/Request+Access.swift`, `Middleware/ProblemMiddleware.swift`.
- **Packaging and docs:** `Dockerfile`, `docker-compose.yml`, `.env.example`, `README.md`.
- **Local setup:** an existing `.env` needs `DATABASE_TLS_MODE=disable` to keep using the non-TLS Compose database.
- **open-erp-ui:** its Playwright fixture starts this API against a non-TLS database, so its environment needs `DATABASE_TLS_MODE=disable`. That one-line update belongs in the UI repo. The UI does not call the removed routes.
- **Public API:** `GET /` and `GET /hello` are removed and `GET /health` is added. None of these appear in the OpenAPI document, so the exported contract is unchanged.
