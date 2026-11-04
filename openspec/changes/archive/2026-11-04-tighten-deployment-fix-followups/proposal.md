## Why

Review of `fix-api-deployment-blockers` left small gaps. A directory passes as `DATABASE_CA_FILE` even though the spec requires an invalid file to fail startup, and a demo shows this. The CA loading, database log redaction branches and hostname verification also have no recorded proof, so a regression in these security controls would go unnoticed.

This change builds on `fix-api-deployment-blockers`, which must be archived first because it introduces the `service-runtime` spec.

## What Changes

- Reject a directory as `DATABASE_CA_FILE` at startup. Deployments that point this variable at a directory of CA files must point it at one PEM bundle instead. No documented setup does this.
- Add unit tests for `postgresConfiguration()` and each invalid CA path.
- Add tests that real Fluent and SQL decoding failures keep row values out of request logs.
- Demonstrate that a certificate for the wrong hostname is rejected, and that the shipped RDS bundle loads.
- Simplify `DatabaseSettings.postgresConfiguration()` and remove the unused `Application` parameter from `JWKSRefresher.fetch`.

**Non-goals**

- The `DATABASE_TLS_MODE` updates to the `open-erp-ui` Playwright fixture and to local `.env` files. These belong to that repo and to each developer's machine.
- Connecting to a database by IP address under `require`. RDS endpoints are DNS names.
- Other redaction changes. The existing log diagnostics already pass the new tests' scenarios in a demo.
- Schema changes, or changes to the API contract.

**SOX/SOC impact**

- **Access control:** a mistaken CA path now fails at startup rather than at the first connection. Tests and a demo give evidence that database certificates and hostnames are verified. Trust stays limited to the configured bundle.
- **Audit trail:** unaffected. The new tests guard against personal data entering operational logs.
- **Segregation of duties:** unaffected.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `service-runtime`: a directory is an invalid `DATABASE_CA_FILE`, and `require` mode gains an explicit wrong-hostname scenario.

## Impact

- **Code:** `DatabaseSettings.swift`, `Auth/JWKSRefresher.swift`, `Auth/OIDC.swift`.
- **Tests:** `DatabaseSettingsTests.swift`, `ProblemTests.swift`, `RuntimeTests.swift`.
- **Public API:** none. The exported OpenAPI document is unchanged.
