# service-runtime

## Purpose

Database configuration and readiness requirements for running the API.
## Requirements
### Requirement: Verified database TLS by default
The system SHALL read `DATABASE_TLS_MODE` with the values `require` and `disable`. Outside the testing environment the default SHALL be `require`; in the testing environment the default SHALL be `disable`. In `require` mode the system SHALL refuse a server that does not offer TLS and SHALL verify the server's certificate chain and hostname. It SHALL NOT fall back to plaintext. Any other mode value SHALL fail startup. When `disable` is selected outside the testing environment, the system SHALL log a warning at startup.

#### Scenario: Server without TLS
- **WHEN** the mode is `require` and the database server does not support TLS
- **THEN** the connection fails and no query is sent in plaintext

#### Scenario: Untrusted certificate
- **WHEN** the mode is `require` and the server's certificate does not chain to a trusted CA
- **THEN** the connection fails with a certificate verification error

#### Scenario: Certificate for another hostname
- **WHEN** the mode is `require` and the server's certificate chains to a trusted CA but does not cover `DATABASE_HOST`
- **THEN** the connection fails with a certificate verification error and no query is sent

#### Scenario: Explicit plaintext for local development
- **WHEN** the mode is `disable` in a non-testing environment
- **THEN** the system connects without TLS and logs a warning that database TLS is disabled

#### Scenario: Unknown mode
- **WHEN** `DATABASE_TLS_MODE` has any value other than `require` or `disable`
- **THEN** startup fails with an error naming the variable

### Requirement: Configurable database CA
The system SHALL read an optional `DATABASE_CA_FILE` path. When it is set, the system SHALL verify the database certificate against that PEM bundle instead of the system trust store. A path that is not a readable file containing at least one valid PEM certificate SHALL fail startup in either TLS mode. The API image SHALL include the Amazon RDS global CA bundle at a documented path and SHALL NOT select it by default.

#### Scenario: Private CA supplied
- **WHEN** `DATABASE_CA_FILE` names a bundle containing the CA that signed the server's certificate
- **THEN** the TLS connection succeeds and migrations can run

#### Scenario: Unreadable CA file
- **WHEN** `DATABASE_CA_FILE` names a missing or invalid file
- **THEN** startup fails rather than falling back to the system trust store

#### Scenario: Directory as CA file
- **WHEN** `DATABASE_CA_FILE` names a directory
- **THEN** startup fails with an error naming the variable

### Requirement: Required database configuration
Outside the testing environment, the system SHALL fail startup when `DATABASE_HOST`, `DATABASE_USERNAME`, `DATABASE_PASSWORD` or `DATABASE_NAME` is missing or empty, naming the missing variable without logging any configured value. `DATABASE_PORT` SHALL remain optional and default to the Postgres port. A value for `DATABASE_PORT` or `DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP` that is not a positive integer SHALL fail startup in every environment. The testing environment SHALL keep its local defaults for the required variables.

#### Scenario: Missing database host
- **WHEN** a non-testing process starts without `DATABASE_HOST`
- **THEN** startup fails with an error naming `DATABASE_HOST` and makes no connection attempt to `localhost`

#### Scenario: Invalid port
- **WHEN** `DATABASE_PORT` is not a positive integer
- **THEN** startup fails rather than using the default port

#### Scenario: Secret values stay out of errors
- **WHEN** configuration validation fails
- **THEN** the error names only the variable and does not include any configured password

### Requirement: Configurable connection pool
The system SHALL read an optional `DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP` and SHALL apply a default greater than the framework's single connection per event loop. The README SHALL explain how this setting, the event-loop count and the number of instances combine against the database's connection limit.

#### Scenario: Single-core instance
- **WHEN** the process has one event loop and the setting is unset
- **THEN** the pool can open more than one database connection, so one open transaction does not block every other request on that instance

### Requirement: Health endpoint
The system SHALL expose `GET /health` without authentication or a tenant selector. It SHALL return 200 with a small fixed JSON body only when a database query succeeds and signing keys are loaded. Otherwise it SHALL return 503 in the shared problem format with a generic detail. The response SHALL NOT disclose tenant data, tenant existence, configuration values, version information or which dependency failed. The endpoint SHALL NOT appear in the OpenAPI document.

#### Scenario: Ready
- **WHEN** the database answers and signing keys are loaded
- **THEN** `GET /health` returns 200 with no credentials or organization header required

#### Scenario: Database unavailable
- **WHEN** the database query fails
- **THEN** `GET /health` returns a generic 503 problem

#### Scenario: Signing keys never loaded
- **WHEN** the server is running and has not yet loaded any signing key
- **THEN** `GET /health` returns a generic 503 problem, so a deployment with a bad JWKS URL does not become ready

#### Scenario: No tenant disclosure
- **WHEN** a request to `GET /health` includes an `X-Organization-ID` for any organization, known or unknown
- **THEN** the response is identical to a request without that header

### Requirement: No placeholder public routes
The system SHALL NOT serve the placeholder routes `GET /` and `GET /hello`. Those paths SHALL return the standard 404 problem.

#### Scenario: Removed placeholder
- **WHEN** a client requests `GET /` or `GET /hello`
- **THEN** the response is a 404 `not_found` problem

### Requirement: Trusted client IP resolution
The system SHALL read `TRUSTED_PROXY_COUNT` as a non-negative integer, defaulting to `0`. Any other value SHALL fail startup. With `0`, the client IP SHALL be the socket remote address, ignoring forwarding headers. With N greater than 0, it SHALL be the Nth address from the right across `X-Forwarded-For` values. If that address is missing or invalid, it SHALL fall back to the socket remote address. `Forwarded` SHALL be ignored.

#### Scenario: Direct client spoofs header
- **WHEN** `TRUSTED_PROXY_COUNT` is `0` and a client sends `X-Forwarded-For`
- **THEN** the socket remote address is used

#### Scenario: One trusted proxy
- **WHEN** `TRUSTED_PROXY_COUNT` is `1` and the header is `198.51.100.9, 203.0.113.7`
- **THEN** the client IP is `203.0.113.7`

#### Scenario: Header too short
- **WHEN** `TRUSTED_PROXY_COUNT` is `2` and the header contains one address
- **THEN** the socket remote address is used

#### Scenario: Invalid count
- **WHEN** `TRUSTED_PROXY_COUNT` is `-1` or not an integer
- **THEN** startup fails

### Requirement: HTTP Strict Transport Security
Outside the testing environment, the system SHALL add `Strict-Transport-Security: max-age=<n>` to every response, including problem responses produced for authentication, authorization and tenant-selection failures. `<n>` SHALL come from the optional `HSTS_MAX_AGE_SECONDS`, which defaults to 31536000. A value of `0` SHALL leave the header out. A negative or non-integer value SHALL fail startup, naming the variable. The header SHALL NOT include `includeSubDomains` or `preload`. The testing environment SHALL leave the header out unless the variable is set.

#### Scenario: Default production header
- **WHEN** the API serves any request outside testing with the variable unset
- **THEN** the response carries `Strict-Transport-Security: max-age=31536000`

#### Scenario: Authorization failure
- **WHEN** a request without a token, or with another organization's `X-Organization-ID`, is refused
- **THEN** the problem response still carries the header

#### Scenario: Disabled
- **WHEN** `HSTS_MAX_AGE_SECONDS=0`
- **THEN** no response carries the header

#### Scenario: Invalid value
- **WHEN** `HSTS_MAX_AGE_SECONDS=-1`
- **THEN** startup fails with an error naming `HSTS_MAX_AGE_SECONDS`

### Requirement: Optional in-process HTTPS
The system SHALL read the optional `HTTP_TLS_CERT_FILE` (a PEM certificate chain) and `HTTP_TLS_KEY_FILE` (a PEM private key). When both are set, the HTTP server SHALL serve only TLS on its configured port. When neither is set, the server SHALL serve plain HTTP, as it does today. Setting only one, or a file that can't be read or parsed, SHALL fail startup, naming the variable and never including file contents. Operational commands that do not serve HTTP SHALL NOT read these variables.

#### Scenario: TLS enabled
- **WHEN** both files are valid and the server starts
- **THEN** `GET /health` over HTTPS succeeds and a plain HTTP request on the same port is refused

#### Scenario: Only one file set
- **WHEN** `HTTP_TLS_CERT_FILE` is set and `HTTP_TLS_KEY_FILE` is not
- **THEN** startup fails with an error naming `HTTP_TLS_KEY_FILE`

#### Scenario: Default unchanged
- **WHEN** neither variable is set
- **THEN** the server serves plain HTTP

### Requirement: Documented encryption posture
The README SHALL include an Encryption section that states, for each hop, whether it is encrypted and which setting controls it: client → load balancer, load balancer → API, API and worker → Postgres, API → identity provider, and worker → webhook receivers. For each storage layer it SHALL state what protects it: database storage, snapshots and backups, application-encrypted webhook secrets, and logs. It SHALL require production database storage to be encrypted at rest with a KMS key. It SHALL explain that RDS can't turn on encryption for an existing instance in place, and give the snapshot-copy-and-restore route. It SHALL require the webhook key-encryption key to come from a secret manager. It SHALL state that the local Compose database has neither TLS nor encryption at rest and must not hold real data.

#### Scenario: Operator checks a hop
- **WHEN** an operator reads the Encryption section
- **THEN** each listed hop and storage layer names its protection and the setting or deployment control that provides it

