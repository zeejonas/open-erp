# authentication

## Purpose

Provider-agnostic OIDC access-token verification, identity binding, the current-user profile, and audit attribution.

## Requirements

### Requirement: Access token verification
The system SHALL require a bearer access token on every route except explicitly public routes. The token MUST be a JWT whose signature verifies against a key from the configured OIDC JWKS, whose `iss` equals `OIDC_ISSUER`, whose `aud` includes `OIDC_AUDIENCE`, and whose `exp` is in the future. The system SHALL NOT depend on any provider-specific claim.

#### Scenario: Missing token
- **WHEN** a request to a protected route has no `Authorization` header
- **THEN** the system responds `401 Unauthorized`

#### Scenario: Invalid signature
- **WHEN** the token is signed by a key not in the configured JWKS
- **THEN** the system responds `401 Unauthorized`

#### Scenario: Wrong issuer or audience
- **WHEN** the token's `iss` differs from `OIDC_ISSUER` or its `aud` does not include `OIDC_AUDIENCE`
- **THEN** the system responds `401 Unauthorized`

#### Scenario: Expired token
- **WHEN** the token's `exp` is in the past
- **THEN** the system responds `401 Unauthorized`

### Requirement: Identity resolution
The system SHALL resolve the authenticated user by matching the token's `sub` to `users.auth_subject`. A verified token whose subject is not bound to any user SHALL be rejected on every route except invitation acceptance, because users are created only through invitations.

#### Scenario: Known subject
- **WHEN** a valid token's `sub` matches a user's `auth_subject`
- **THEN** the request proceeds as that user

#### Scenario: Unknown subject
- **WHEN** a valid token's `sub` matches no user and the route is not invitation acceptance
- **THEN** the system responds `403 Forbidden`

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
