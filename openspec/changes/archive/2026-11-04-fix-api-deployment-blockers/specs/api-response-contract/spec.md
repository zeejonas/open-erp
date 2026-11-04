## MODIFIED Requirements

### Requirement: Stable problem details for application errors
Application-generated HTTP errors SHALL use application/problem+json with RFC 9457 fields type, title, status, detail and a stable code extension. The body status SHALL equal the HTTP status; type SHALL be the stable urn:open-erp:problem:<code> identifier. Clients SHALL be instructed to branch on code/status rather than human-readable text. A single formatter SHALL preserve applicable error headers and existing authorization/status semantics, log each failure once (server errors with internal diagnostics, client errors with only status and code), and sanitize internal errors in every environment. Diagnostics for database errors SHALL be limited to the error class, driver error code, SQLSTATE, table, constraint and column names, and SHALL exclude server messages and details, bound values and row data. It SHALL retain parameter names for invalid inputs without echoing submitted credentials or tokens. No response SHALL disclose SQL, stack traces, configuration values or hidden tenant existence.

#### Scenario: Invalid access token
- **WHEN** a bearer token fails signature, issuer, audience or expiry verification
- **THEN** the response is 401 invalid_access_token with an RFC 6750 `Bearer error="invalid_token"` WWW-Authenticate challenge

#### Scenario: Missing access token
- **WHEN** a protected route receives no bearer token
- **THEN** the response is 401 unauthorized with a `Bearer` WWW-Authenticate challenge and no error code

#### Scenario: Ordinary Vapor errors
- **WHEN** an existing handler throws an ordinary Abort without an explicit code
- **THEN** the formatter preserves its status and safe headers and uses the status fallback code without the handler being rewritten

#### Scenario: Unknown route and validation error
- **WHEN** routing fails or a declared list parameter is invalid
- **THEN** the response is a 404 not_found or 400 bad_request problem respectively, with invalid parameter names in detail

#### Scenario: Hidden tenant existence
- **WHEN** an authenticated user selects an unknown organization or an organization without membership
- **THEN** both return the same generic 403 forbidden problem and neither reveals which condition occurred

#### Scenario: Internal failure
- **WHEN** an internal exception occurs in any environment
- **THEN** the response is 500 internal_error with a generic detail, internal diagnostics stay out of the response, and the failure is logged with its diagnostics

#### Scenario: Database error carrying submitted values
- **WHEN** an unhandled Postgres error reports a submitted value, such as an email in a unique-key detail
- **THEN** the log entry contains the SQLSTATE and constraint name and does not contain that value

### Requirement: Revocation problem codes
The explicit code catalog SHALL add access_token_revoked (401) for a verified token whose fingerprint is revoked and authentication_unavailable (503) when the revocation store cannot be checked or written, or when no signing keys have ever loaded. Both SHALL use the shared problem format, and access_token_revoked SHALL carry a Bearer WWW-Authenticate challenge.

#### Scenario: Revoked token and store outage
- **WHEN** a valid token is revoked, or revocation storage is unavailable
- **THEN** the response is 401 access_token_revoked or 503 authentication_unavailable respectively, in the shared problem format

#### Scenario: Signing keys not loaded
- **WHEN** a request presents a bearer token before any signing key has loaded
- **THEN** the response is 503 authentication_unavailable in the shared problem format, with no WWW-Authenticate challenge
