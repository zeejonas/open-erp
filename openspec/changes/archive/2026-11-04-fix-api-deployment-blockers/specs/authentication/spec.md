## MODIFIED Requirements

### Requirement: Provider-agnostic configuration
The system SHALL read the OIDC issuer, audience, JWKS URL, and userinfo URL from environment variables and SHALL fail to start the HTTP server outside the testing environment if any is missing. Operational commands that do not verify tokens, including `migrate`, `prune-revoked-tokens`, `platform-admin` and `approval-override`, SHALL NOT require these variables or contact the identity provider.

#### Scenario: Missing configuration
- **WHEN** the HTTP server starts in a non-testing environment without `OIDC_ISSUER`
- **THEN** startup fails with an error naming the missing variable

#### Scenario: Operational command without OIDC
- **WHEN** `migrate --yes` runs in a non-testing environment with valid database settings and no OIDC variables
- **THEN** the migration runs without contacting the identity provider

## ADDED Requirements

### Requirement: Signing key lifecycle
When serving, the system SHALL load signing keys from `OIDC_JWKS_URL` without blocking startup, and SHALL refresh them periodically on a bounded schedule. A successful refresh SHALL replace the whole key set, so keys removed from the JWKS stop being trusted. Entries that cannot be used for signature verification SHALL be ignored without affecting the other keys, and the number ignored SHALL be logged. A failed refresh, or a response with no usable keys, SHALL keep the last good key set and log an error stating the reason. The server SHALL NOT exit because the JWKS is unreachable. While no key set has ever loaded, a request presenting a bearer token, including logout, SHALL fail closed with 503 `authentication_unavailable` and SHALL NOT be reported as an invalid credential. Requests without a bearer token SHALL still receive 401.

#### Scenario: Provider unreachable at startup
- **WHEN** the server starts while the JWKS URL is unreachable
- **THEN** the process stays up, retries, and answers a bearer request with 503 `authentication_unavailable` until keys load

#### Scenario: Provider outage after keys loaded
- **WHEN** a refresh fails after keys have loaded
- **THEN** tokens signed by the retained keys continue to verify and the failure is logged

#### Scenario: New key published
- **WHEN** the provider adds a signing key to its JWKS
- **THEN** tokens signed by that key verify after the next successful refresh, with no restart

#### Scenario: Key removed
- **WHEN** the provider removes a signing key from its JWKS
- **THEN** after the next successful refresh, tokens signed by that key receive 401 `invalid_access_token`

#### Scenario: Empty key set
- **WHEN** a refresh returns a JWKS with no usable keys
- **THEN** the last good key set stays in place, so an empty response cannot lock out every user

#### Scenario: Unusable entry alongside signing keys
- **WHEN** a JWKS contains a usable signing key and an entry the system cannot use, such as an unsupported algorithm, curve or key type, or a key without a `kid`
- **THEN** the usable key loads, keys absent from that JWKS stop being trusted, and the ignored count is logged

#### Scenario: Authorization remains enforced
- **WHEN** keys become available after an outage
- **THEN** each request is still subject to revocation, identity binding, organization membership and permission checks
