## ADDED Requirements

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
