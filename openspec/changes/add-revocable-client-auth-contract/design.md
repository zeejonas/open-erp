## Context

`Request.verifiedAccessToken()` validates JWT signature, expiry, issuer and audience and is used by both normal authentication and invitation acceptance. There is no token revocation. `AuthMiddleware` additionally binds the subject to an ERP user. `add-api-problem-details` supplies the problem format and `invalid_access_token`.

## Goals / Non-Goals

**Goals:** A successful logout makes the presented token unusable across ERP instances; all protected paths agree on revocation; clients get an explicit provider-neutral contract.

**Non-Goals:** Identity-provider/session management, revoking all tokens for a person, client implementations, a distributed cache, changing RBAC or onboarding writes, immediate cancellation of previously authorized requests, error formatting, cache policy, directory features or OpenAPI export tooling.

## Decisions

### Shared durable revocation, using existing dependencies

Use a `revoked_access_tokens` Fluent model with the SHA-256 fingerprint of the token's signed `header.payload` as its string primary key, plus `issuer`, `subject`, `expires_at`, and `revoked_at`. All fields are required. The signature is excluded because JWTKit accepts non-canonical trailing base64url bits and ECDSA `(r, n − s)`, so hashing the whole string would let a revoked token be replayed with a re-encoded signature; the signature covers `header.payload` byte for byte, so that portion cannot vary. Standard JWT verification must succeed before any insert; do not require `jti` or another provider-specific claim. Use existing Swift Crypto for hashing and Postgres for shared persistence. This is API security state, with no organization ID or UI session. Attribution uses verified issuer/subject and server time, so unbound identities can log out without creating an ERP user. [Vapor JWT](https://docs.vapor.codes/security/jwt/), [Fluent models](https://docs.vapor.codes/fluent/model/), [Fluent schema](https://docs.vapor.codes/fluent/schema/).

The ordinary verifier checks for a revocation record after cryptographic/claim validation and before resolving users or admitting the request. Read the shared primary database on every check; no local negative cache or replica read is permitted. Keep database errors outside the invalid-JWT catch: store failure returns 503 `authentication_unavailable`, never acceptance or a misleading 401. Preserve existing 401/403 membership distinctions.

### Logout revokes exactly the supplied bearer token

Add `POST /auth/logout`, bearer-only, no tenant header and no body. It validates signature/issuer/audience/expiry, deliberately does not reject an already revoked token, and records revocation before returning empty 204. It does not use AuthMiddleware because invitation recipients and removed users must also be able to revoke their tokens. Name the claims-only helper `verifiedAccessTokenIgnoringRevocation()` and call it only from logout; the default protected verifier always checks revocation. Do not expose an optional skip-revocation switch to ordinary handlers. [Vapor routing](https://docs.vapor.codes/basics/routing/), [Vapor JWT](https://docs.vapor.codes/security/jwt/).

Concurrent duplicate logouts must converge on one immutable record. Use the database primary-key constraint, treating only a verified duplicate of that fingerprint as success; other persistence failures return 503. Preserve the first revocation time. An already expired or invalid token returns 401 without writes. A nonempty body returns 400. Tokens cannot be supplied by query/body. Logout is an ERP resource-server operation, not an implementation of the authorization-server endpoint in [RFC 7009](https://www.rfc-editor.org/rfc/rfc7009.html).

Implementation uses SQLKit's insert builder with `ignoringConflicts(with: "fingerprint")` and `returning("revoked_at")`, producing Postgres `ON CONFLICT (fingerprint) DO NOTHING RETURNING`. Only the fingerprint primary-key conflict is ignored, and the returned row distinguishes the first insertion for auditing. Cleanup uses SQLKit's delete builder with `RETURNING 1`, counting deleted rows without returning fingerprints. Integration tests demonstrate duplicate preservation, storage failure handling, cleanup boundaries, and cross-instance admission behavior. PostgresNIO protocol/error metadata is redacted along with Fluent/PostgresKit bind fields because failed-row diagnostics can contain fingerprints even when normal query binds are hidden. [SQLKit](https://github.com/vapor/sql-kit).

The guarantee begins at the committed revocation: any subsequent protected verification using that token fails, on every instance and for every tenant, including invitation acceptance. A request whose revocation check passed before the commit may finish. Other access tokens, even for the same issuer/subject, remain valid.

### Revocation problem codes

Add `access_token_revoked` (401, with a Bearer challenge) and `authentication_unavailable` (503) as explicit codes in the shared problem catalog from `add-api-problem-details`. Annotate logout's 204/400/401/503 responses with the shared problem helper.

### Client contract and revocation record lifecycle

Document access tokens versus ID tokens; exact issuer/audience; issuer-controlled expiration (recommend 10-minute access tokens, without claiming the ERP enforces maximum lifetime); required scopes for invitation userinfo; tenant-header route classes; binding/membership failures; problem codes; and server-backed/browser/mobile client responsibilities. Clients must stop refresh activity, call ERP logout with the current token, wait for confirmed success before claiming ERP revocation, and clear local credentials. On failure, local clearing alone cannot be described as successful server revocation. Provider refresh revocation and SSO logout are separate client/provider operations; no provider secret is introduced into the ERP. [Auth0 refresh revocation](https://auth0.com/docs/secure/tokens/refresh-tokens/revoke-refresh-tokens).

Retain revocation entries at least through verified token expiry. Add `prune-revoked-tokens` as a native AsyncCommand deleting only entries whose expiry is not in the future. Log a successful first revocation with issuer/subject and time, not token or fingerprint, and log cleanup counts. The database record is the enforcement source; security logs retain attribution under deployment retention controls after expiry cleanup. [Vapor commands](https://docs.vapor.codes/advanced/commands/), [Fluent queries](https://docs.vapor.codes/fluent/query/).

Rejected alternatives:
- Browser logout or short expiration alone: does not revoke a still-valid access token.
- Only call the provider's refresh-revocation endpoint: does not establish immediate rejection by this locally verifying ERP.
- In-memory denylist: loses enforcement on restart and differs across instances.
- `jti` or subject-wide cutoffs: adds a claim assumption or revokes unrelated access tokens.
- Redis/session framework: new infrastructure and session concepts for one indexed lookup.

## Risks / Trade-offs

- [One database lookup per protected request] → Indexed fingerprint primary key, bounded record lifetime, no extra service; fail closed during outages.
- [Successful revocation followed by rollback to old code] → Old code would accept revoked tokens. Roll back only to a revocation-aware build or stop protected traffic until affected tokens expire; retain the security table.
- [In-flight requests] → Define the admission boundary precisely; cancellation/transaction-wide logout locks are out of scope.
- [Refresh mints another token] → Exact-token scope is explicit; clients stop refresh and separately revoke refresh credentials where supported.

## Migration Plan

Add one create migration for the new table and register it before traffic requires revocation. Do not alter released migrations; before release, follow the existing owning-create policy. For development, recreate the schema using existing documented migration practices rather than adding upgrade scripts. Deploy verifier, logout and docs as one change; mixed old/new serving instances cannot provide the revocation guarantee. Apply all-instance cutover before advertising logout. Cleanup never removes an unexpired record.

## Change Ownership

This proposal owns authentication and revocation requirements, revocation persistence, client auth documentation and the two revocation problem codes. It lands after `add-api-problem-details` and does not change the problem format or `add-no-store-response-policy`. It does not modify directory diagnostics or the OpenAPI generator/export/bootstrap split. Other changes add route metadata using these contracts without redefining them. Shared configure/README/test files are edited additively, preserving unrelated registrations.

## Open Questions

None blocking. Revocation scope is the presented access token at this ERP, with a documented client obligation for provider refresh/SSO cleanup.
