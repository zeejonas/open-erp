## ADDED Requirements

### Requirement: Durable access-token revocation records
The system SHALL define revoked_access_tokens with one create migration and a Fluent model. It SHALL store a unique SHA-256 fingerprint of the token's signed header and payload as its primary key, verified issuer and subject, token expiration and first revocation time. All fields SHALL be non-null. It SHALL NOT store raw access or refresh tokens, require a provider-specific token ID, depend on an ERP user row, or belong to a UI or tenant session. Duplicate/concurrent revocations SHALL preserve the first record. The schema SHALL be usable by every serving instance and survive application restarts. Registration and revert SHALL follow the pre-release single-create-migration policy.

#### Scenario: Fresh schema and revert
- **WHEN** the registered migrations apply to an empty database and are subsequently reverted
- **THEN** the revocation table is created with required fields and uniqueness and reverts cleanly with the complete schema

#### Scenario: Shared durable record
- **WHEN** one instance commits revocation and another instance or a restarted application checks that fingerprint
- **THEN** the same revocation is visible without any in-memory session state

#### Scenario: Unbound identity attribution
- **WHEN** a verified subject without an ERP user logs out
- **THEN** the record attributes revocation to its verified issuer/subject and server time without creating a user or referencing a tenant

### Requirement: Revocation expiry cleanup and credential-safe evidence
The system SHALL retain an enforceable revocation record until at least the token's verified expiration. The native prune-revoked-tokens command SHALL delete only records whose expiration is not in the future and report a count. First successful revocations SHALL produce security audit events attributable to verified issuer/subject and server time. Tokens, token fingerprints, Authorization values and credentials SHALL NOT appear in logs, public error details, or OpenAPI examples. Cleanup SHALL NOT erase deployment-retained audit logs.

#### Scenario: Cleanup boundary
- **WHEN** cleanup runs with expired and unexpired revocation rows
- **THEN** only expired rows are removed and unexpired logged-out tokens stay rejected

#### Scenario: Credential-safe audit
- **WHEN** logout succeeds, fails, or is retried and cleanup later runs
- **THEN** success attribution and cleanup counts are available without raw tokens or fingerprints in logs or response diagnostics
