# authentication

## Purpose

Provider-agnostic OIDC access-token verification, identity binding, the current-user profile, and audit attribution.

## Requirements

### Requirement: Access token verification
The system SHALL require a bearer access token on every route except explicitly public routes. The token MUST be a JWT whose signature verifies against a key from the configured OIDC JWKS, whose `iss` equals `OIDC_ISSUER`, whose `aud` includes `OIDC_AUDIENCE`, and whose `exp` is in the future. The system SHALL NOT depend on any provider-specific claim. Before admitting a protected request, the system SHALL reject the token if its SHA-256 fingerprint exists in the shared primary-database revocation store. The fingerprint SHALL cover the signed header and payload, not the signature, so every signature encoding that verifies for the same token is rejected. This check SHALL apply to ordinary user, platform, tenant, and invitation-acceptance routes, with no process-local negative cache. A revocation lookup failure SHALL fail closed with 503 `authentication_unavailable` rather than accept the token or report invalid credentials. The sole exception to rejecting a revoked token SHALL be the idempotent logout operation, which SHALL still validate its signature and standard claims.

#### Scenario: Missing token
- **WHEN** a request to a protected route has no Authorization header
- **THEN** the system responds 401 Unauthorized

#### Scenario: Invalid signature
- **WHEN** the token is signed by a key not in the configured JWKS
- **THEN** the system responds 401 Unauthorized with code invalid_access_token

#### Scenario: Wrong issuer or audience
- **WHEN** the token's iss differs from OIDC_ISSUER or its aud does not include OIDC_AUDIENCE
- **THEN** the system responds 401 Unauthorized with code invalid_access_token

#### Scenario: Expired token
- **WHEN** the token's exp is not in the future
- **THEN** the system responds 401 Unauthorized with code invalid_access_token

#### Scenario: Revoked token on any protected path
- **WHEN** a revocation has committed and a later verification uses that token on a user, platform, tenant, or invitation-acceptance route on any ERP instance
- **THEN** it returns 401 with code access_token_revoked before user resolution or tenant writes, even if the token has not expired

#### Scenario: Re-encoded signature of a revoked token
- **WHEN** a logged-out token is replayed with a different signature encoding that still verifies
- **THEN** the system responds 401 Unauthorized with code access_token_revoked

#### Scenario: Store outage
- **WHEN** a valid token cannot be checked against the shared revocation store
- **THEN** the request returns 503 authentication_unavailable and no protected operation is admitted

### Requirement: Identity resolution
The system SHALL resolve the authenticated user by matching the token's sub to users.auth_subject. A verified token whose subject is not bound to any user SHALL be rejected on every protected route except invitation acceptance and access-token logout, because users are created only through invitations. Neither exception SHALL create a user merely to authenticate or log out.

#### Scenario: Known subject
- **WHEN** a valid unrevoked token's sub matches a user's auth_subject
- **THEN** the request proceeds as that user

#### Scenario: Unknown subject
- **WHEN** a valid unrevoked token's sub matches no user and the route is neither invitation acceptance nor access-token logout
- **THEN** the system responds 403 Forbidden

#### Scenario: Unbound recipient logs out
- **WHEN** a valid token for a subject without an ERP user calls access-token logout
- **THEN** logout can revoke that token without creating a user or requiring tenant membership

### Requirement: Provider-agnostic configuration
The system SHALL read the OIDC issuer, audience, JWKS URL, and userinfo URL from environment variables and SHALL fail to start outside the testing environment if any is missing.

#### Scenario: Missing configuration
- **WHEN** the application starts in a non-testing environment without `OIDC_ISSUER`
- **THEN** startup fails with an error naming the missing variable

### Requirement: Current user profile
The system SHALL expose `GET /me` returning the authenticated user's identity and `PATCH /me` allowing that user to update only their own first and last name. No organization SHALL be able to modify a user's name or email.

#### Scenario: Read own profile
- **WHEN** an authenticated user calls `GET /me`
- **THEN** the system returns that user's id, first name, last name, and email

#### Scenario: Update own name
- **WHEN** an authenticated user calls `PATCH /me` with a new first name
- **THEN** the user's first name is updated and `updated_by` is set to that user

#### Scenario: Email is not editable
- **WHEN** an authenticated user calls `PATCH /me` with an `email` field
- **THEN** the email is not changed

### Requirement: Audit attribution
The system SHALL set `created_by`, `updated_by`, and `deleted_by` to the authenticated user on every create, update, and soft delete of audited records.

#### Scenario: Create attributes creator
- **WHEN** an authenticated user creates a company
- **THEN** the company's `created_by` equals that user's id

#### Scenario: Delete attributes deleter
- **WHEN** an authenticated user deletes a company
- **THEN** the company's `deleted_by` equals that user's id and `deleted_at` is set

### Requirement: Removed unauthenticated user endpoints
The system SHALL NOT expose `POST /users` or `PATCH /users/:userID`.

#### Scenario: Legacy user creation
- **WHEN** a client calls `POST /users`
- **THEN** the system responds `404 Not Found`

### Requirement: Durable access-token logout
The system SHALL expose POST /auth/logout accepting only the presented Authorization Bearer token, without a body or tenant selector. It SHALL validate signature, issuer, audience and expiration even for repeat logout, durably record the exact token's fingerprint, verified issuer/subject, expiration and server revocation time, and return empty 204 only after revocation is committed. Revoking an already revoked valid token, including concurrent retries, SHALL return 204 without changing its first revocation time. It SHALL NOT revoke another token for the same subject or accept a token supplied through query parameters or body. Persistence failure SHALL return 503 authentication_unavailable without claiming success. Missing/invalid/expired tokens SHALL return 401; nonempty bodies or query parameters SHALL return 400 with no revocation write. This route SHALL be documented as ERP token logout, not as a provider OAuth revocation endpoint.

#### Scenario: Logout prevents replay
- **WHEN** a valid token is used successfully, logout returns 204, and that token is used for a later protected verification
- **THEN** the later request is denied with 401 access_token_revoked

#### Scenario: Concurrent and repeated logout
- **WHEN** two instances receive logout for the same valid token concurrently and it is retried afterward
- **THEN** all successful calls return 204, one revocation record persists, and its first revocation time is unchanged

#### Scenario: Other token and tenant isolation
- **WHEN** one of two distinct valid access tokens for a subject is logged out
- **THEN** that exact token is rejected in every organization and instance while the other token remains subject to normal membership and permission checks

#### Scenario: Invalid logout or persistence failure
- **WHEN** logout receives an invalid or expired token, an unsupported body/query, or cannot persist a valid token's revocation
- **THEN** it returns 401, 400, or 503 respectively, does not report successful revocation, and does not log credentials

#### Scenario: Request already admitted
- **WHEN** a request passed its revocation check before logout committed
- **THEN** it may finish under its existing authorization, while every revocation check started after the commit rejects the logged-out token

### Requirement: Documented client authentication and logout contract
The backend SHALL publish a provider-neutral client contract covering access tokens rather than ID tokens, configured issuer/audience/JWKS, issuer-controlled expiry, invitation userinfo scopes and verified email, Bearer transport, tenant-header requirements, binding and authorization failures, and stable problem codes. It SHALL describe browser, server-backed, and mobile clients without owning their login/session store. Logout instructions SHALL require clients to stop token refresh, submit the current token to ERP logout, distinguish confirmed revocation from a failed request, and clear local credentials. The contract SHALL state that ERP logout revokes only that exact token at this ERP, does not end the provider session or revoke refresh credentials/other issued tokens, and requires appropriate separate client/provider cleanup. Recommended short lifetimes SHALL NOT be represented as a substitute for revocation or a maximum lifetime enforced by this backend.

#### Scenario: Client can choose its own login architecture
- **WHEN** a client developer reads the published contract
- **THEN** it explains how to acquire and present an access token, select a tenant where required, and handle 401/403 without a backend UI session or direct database access

#### Scenario: Logout request fails
- **WHEN** ERP logout fails or its success cannot be confirmed
- **THEN** the contract states that clearing local credentials alone does not prove server-side revocation and describes retry while the token is available

#### Scenario: Provider refresh and SSO
- **WHEN** ERP logout succeeds but the provider session or a refresh credential still exists
- **THEN** the contract identifies separate provider cleanup and makes no claim that another freshly issued token is revoked
