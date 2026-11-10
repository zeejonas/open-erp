## ADDED Requirements

### Requirement: Secure identity provider transport
Outside the testing environment, the HTTP server SHALL fail to start when `OIDC_JWKS_URL` or `OIDC_USERINFO_URL` is not an absolute `https` URL. The error SHALL name the variable. When `OIDC_ALLOW_INSECURE_HTTP=true`, the server SHALL also accept `http` URLs and SHALL log a warning at startup naming the insecure variables. Any value of `OIDC_ALLOW_INSECURE_HTTP` other than `true` or `false` SHALL fail startup. HTTPS requests to the identity provider SHALL verify the certificate chain and hostname. Operational commands that do not verify tokens SHALL NOT read these variables.

#### Scenario: HTTP JWKS refused
- **WHEN** the server starts outside testing with `OIDC_JWKS_URL=http://idp.example.com/jwks`
- **THEN** startup fails with an error naming `OIDC_JWKS_URL`, and no request is made to that URL

#### Scenario: Explicit opt-out
- **WHEN** the same URL is configured with `OIDC_ALLOW_INSECURE_HTTP=true`
- **THEN** the server starts and logs a warning that `OIDC_JWKS_URL` is insecure

#### Scenario: Keys from an unverifiable host
- **WHEN** the JWKS host presents a certificate that doesn't match its hostname
- **THEN** the key refresh fails, no keys from that response are loaded, and tokens signed by keys that are not loaded are rejected with 401
