## Why

Clients currently receive Vapor's default `{error, reason}` body and must branch on human-readable text or bare status codes. Any UI built on this backend needs a stable, machine-readable error contract.

## What Changes

- **BREAKING**: Replace Vapor's default error bodies with RFC 9457 problem details (`application/problem+json`) carrying a stable `code`, preserving statuses, authorization boundaries and applicable headers.
- Define a small status-derived code catalog plus `invalid_access_token` for failed bearer verification; every 401 carries an RFC 6750 Bearer `WWW-Authenticate` challenge (`error="invalid_token"` for rejected tokens).
- Document the problem schema and standard failure statuses in the generated OpenAPI document.

## Capabilities

### New Capabilities

- `api-response-contract`: Stable problem details and error code catalog.

### Modified Capabilities

None. Existing statuses and authorization semantics are unchanged; only the error body format changes.

## Impact

One error middleware replacing Vapor's default, a problem DTO/code enum, a typed `AbortError` for explicit codes, OpenAPI response annotations, and updates to tests asserting the old body. No migration or new package. SOX/SOC: credential-safe and tenant-safe error disclosure; one log per failure.

## Non-goals

Token revocation, cache headers, domain-specific codes without a documented recovery action, rewriting existing handlers into typed errors, and API versioning tooling.
