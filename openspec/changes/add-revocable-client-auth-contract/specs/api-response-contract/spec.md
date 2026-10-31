## ADDED Requirements

### Requirement: Revocation problem codes
The explicit code catalog SHALL add access_token_revoked (401) for a verified token whose fingerprint is revoked and authentication_unavailable (503) when the revocation store cannot be checked or written. Both SHALL use the shared problem format, and access_token_revoked SHALL carry a Bearer WWW-Authenticate challenge.

#### Scenario: Revoked token and store outage
- **WHEN** a valid token is revoked, or revocation storage is unavailable
- **THEN** the response is 401 access_token_revoked or 503 authentication_unavailable respectively, in the shared problem format

### Requirement: Published logout metadata
Route metadata SHALL document POST /auth/logout as bearer-only with no tenant header and no body, its 204 success, and its 400, 401 and 503 problem responses. Examples SHALL use synthetic values.

#### Scenario: Client inspects logout
- **WHEN** a client reads /openapi.json
- **THEN** it can identify logout's bearer-only, no-tenant contract and failure statuses
