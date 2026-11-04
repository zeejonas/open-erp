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
