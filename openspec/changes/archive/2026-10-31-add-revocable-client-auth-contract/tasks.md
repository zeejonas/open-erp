## 1. Revocation persistence

- [x] 1.1 Add the Fluent revocation model and single create migration with fingerprint primary key, required verified issuer/subject, expiration and revocation time; test fresh migrate/revert and duplicate-record preservation.
- [x] 1.2 Add a small fingerprint/record lookup-and-insert implementation using existing Swift Crypto/Postgres facilities; test distinct tokens, unbound subjects, persistence across application instances/restarts and concurrent duplicate inserts without swallowing other database errors.

## 2. Problem codes

- [x] 2.1 Add access_token_revoked and authentication_unavailable to the explicit code catalog; test both shapes and the Bearer challenge on access_token_revoked.

## 3. Verification and logout

- [x] 3.1 Separate cryptographic/claim validation from the default revocation-aware verifier, with the revocation-skipping helper named explicitly and called only by logout. Test invalid signature/issuer/audience/expiry, valid tokens, revoked tokens and fail-closed 503 storage failures.
- [x] 3.2 Implement POST /auth/logout with no body/query/tenant selector and committed revocation before 204; test unbound/removed users, invalid inputs, repeated and concurrent logout, original timestamp preservation and persistence failures.
- [x] 3.3 Verify revoked-token replay fails on /me, a platform route, tenant routes across organizations and invitation acceptance, using separate application instances sharing Postgres; verify another token for the same subject remains valid under ordinary authorization.
- [x] 3.4 Fingerprint the signed header and payload; test that re-encoded signatures (trailing base64url bits, ECDSA high-S) of a revoked token are rejected and share its record. The admission boundary is a documented non-guarantee, not a tested behavior.

## 4. Lifecycle and client contract

- [x] 4.1 Add the native prune-revoked-tokens command and credential-safe first-revocation audit events; test expired-only cleanup, unexpired enforcement, actor/time evidence and absence of tokens/fingerprints in logs and error details.
- [x] 4.2 Publish provider-neutral client authentication/logout documentation covering route classes, issuer/audience, access versus ID tokens, expiry, invitation scopes/email, refresh-stop ordering, failed logout, provider cleanup and per-token ERP scope; cross-check examples against the implemented routes.
- [x] 4.3 Annotate logout with the shared problem helper; assert bearer-only, no tenant header, 204 and 400/401/503 problem responses, and synthetic examples.

## 5. Verification and rollout

- [x] 5.1 Run authentication, tenant/RBAC, invitation/onboarding, approval, schema and documentation regressions; run strict OpenSpec validation and confirm no alternate token-verification path skips revocation.
- [x] 5.2 Record deployment/rollback instructions; confirm the revocation table is ready before an all-instance cutover and that rollback cannot route requests to a revocation-unaware build.
