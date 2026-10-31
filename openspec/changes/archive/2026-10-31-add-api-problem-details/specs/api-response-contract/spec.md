## ADDED Requirements

### Requirement: Stable problem details for application errors
Application-generated HTTP errors SHALL use application/problem+json with RFC 9457 fields type, title, status, detail and a stable code extension. The body status SHALL equal the HTTP status; type SHALL be the stable urn:open-erp:problem:<code> identifier. Clients SHALL be instructed to branch on code/status rather than human-readable text. A single formatter SHALL preserve applicable error headers and existing authorization/status semantics, log each failure once (server errors with internal diagnostics, client errors with only status and code), and sanitize internal errors in every environment. It SHALL retain parameter names for invalid inputs without echoing submitted credentials or tokens. No response SHALL disclose SQL, stack traces, configuration values or hidden tenant existence.

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

### Requirement: Bounded stable error code catalog
The explicit code invalid_access_token SHALL identify failed bearer verification. Generic status fallbacks SHALL be bad_request for 400, unauthorized for 401, forbidden for 403, not_found for 404, conflict for 409, payload_too_large for 413, unsupported_media_type for 415, too_many_requests for 429, internal_error for 5xx failures and http_error for remaining error statuses. Codes SHALL NOT be derived from reason text or framework debugging identifiers. New explicit codes SHALL be introduced only with documented recovery semantics and tests.

#### Scenario: Human wording changes
- **WHEN** an error's human-readable explanation changes without a semantic change
- **THEN** its code and type remain unchanged

### Requirement: Published problem metadata
Route metadata SHALL document the problem media type/schema and the applicable standard failure statuses using the existing route-derived OpenAPI generator.

#### Scenario: Client inspects the generated contract
- **WHEN** a client reads /openapi.json
- **THEN** it can identify the problem schema and each operation's applicable failure statuses
