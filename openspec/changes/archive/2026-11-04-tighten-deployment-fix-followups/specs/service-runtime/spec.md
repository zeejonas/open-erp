## MODIFIED Requirements

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
