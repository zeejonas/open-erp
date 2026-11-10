## MODIFIED Requirements

### Requirement: Unsafe serving role rejected
When serving the API or running the continuous webhook delivery worker in the production environment, the system SHALL fail startup if its database session user is a superuser or a member of the role that owns the `audit` schema. In other non-testing environments, it SHALL log a warning. Migration and other operational commands SHALL NOT be subject to this startup check; the continuous webhook delivery worker SHALL be checked because it is an application runtime, not a schema-administration command.

#### Scenario: Production owner connection
- **WHEN** the API starts with `--env production` as the audit schema owner
- **THEN** startup fails without logging credentials

#### Scenario: Production runtime connection
- **WHEN** the API starts with `--env production` as the runtime role
- **THEN** startup continues

#### Scenario: Migration uses owner role
- **WHEN** `migrate` runs as the owner role in production
- **THEN** the startup check does not block it

#### Scenario: Worker owner connection rejected
- **WHEN** webhook-worker starts in production with a superuser or audit-owner-member session
- **THEN** startup fails before any delivery is claimed

#### Scenario: Worker runtime connection accepted
- **WHEN** webhook-worker starts in production as the safe runtime role
- **THEN** the same database role check passes without requiring migration privileges
