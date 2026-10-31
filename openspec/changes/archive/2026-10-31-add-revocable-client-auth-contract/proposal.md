## Why

Clients need logout to invalidate the access token at the ERP immediately, rather than merely discarding it locally while it stays valid until expiry. The backend also needs a published, provider-neutral contract so any client architecture can authenticate and log out correctly.

## What Changes

- Add `POST /auth/logout` to durably revoke the presented access token across ERP instances, including tokens whose subject has not yet accepted an invitation.
- Check shared Postgres revocation state in every protected token-verification path, including invitation acceptance, without provider-specific claims or a UI session store.
- Add `access_token_revoked` and `authentication_unavailable` problem codes.
- Document client token acquisition, claims, tenant selection, logout ordering, refresh/identity-provider responsibilities, and the revocation concurrency boundary.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `authentication`: Revocation-aware access verification, idempotent token logout, identity-resolution exception, and client documentation.
- `database-schema`: Durable, indexed, token-fingerprint revocation records with a single create migration.
- `api-response-contract`: Revocation problem codes and logout metadata.

## Dependencies

Lands after `add-api-problem-details`, which defines the problem format and `invalid_access_token`.

## Impact

Shared token verification, a logout route, one revocation model/migration, a prune command, OpenAPI annotations, README client contract, and focused security tests. Reuses Swift Crypto, Fluent, Vapor JWT and Postgres; no Redis or provider SDK. SOX/SOC: durable logout attribution, fail-closed enforcement, unchanged tenant/permission checks, and credential-safe logging.

## Non-goals

Issuing access/refresh tokens, UI sessions, global provider logout, provider-side refresh-token revocation, revoking other access tokens/devices, retroactively canceling admitted requests, error formatting and cache policy. ERP logout revokes this exact token at the ERP; clients must stop refresh activity and use their provider's revocation/logout mechanisms as applicable.
