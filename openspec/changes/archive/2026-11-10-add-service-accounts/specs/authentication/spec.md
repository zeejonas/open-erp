## ADDED Requirements

### Requirement: Service account authentication
A verified, unrevoked token whose `sub` is bound to a service account SHALL proceed as that service account only when the account and its organization membership are not deleted and the account is not disabled; otherwise the system SHALL respond `403 Forbidden`. This check SHALL read the shared primary database on every request, so disable and delete take effect before the token expires. Token verification SHALL be the same as for people and SHALL NOT depend on any provider-specific claim. The userinfo endpoint SHALL NOT be called for a service account.

#### Scenario: Client-credentials token
- **WHEN** a valid token whose `sub` is bound to an enabled service account calls a protected route
- **THEN** the request proceeds as that service account

#### Scenario: Disabled account with a live token
- **WHEN** an account is disabled and its unexpired token calls a protected route
- **THEN** the system responds `403 Forbidden`

#### Scenario: Revoked service account token
- **WHEN** a service account's token has been logged out and is reused
- **THEN** the system responds `401` with code `access_token_revoked`

### Requirement: Person-only identity routes
`GET /me`, `PATCH /me`, and invitation acceptance SHALL respond `403 Forbidden` to a service account. `GET /me/organizations`, `GET /me/access`, and access-token logout SHALL remain available to service accounts.

#### Scenario: Profile refused
- **WHEN** a service account calls `PATCH /me`
- **THEN** the system responds `403` and no user changes

#### Scenario: Invitation refused
- **WHEN** a service account's token accepts an invitation
- **THEN** the system responds `403` and no membership is created

#### Scenario: Discover own access
- **WHEN** a service account calls `GET /me/access` with its organization header
- **THEN** the response lists the permissions its groups grant
