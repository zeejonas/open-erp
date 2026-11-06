## ADDED Requirements

### Requirement: Separate database roles
Deployments SHALL use an owner role to own the schema and run migrations, and a runtime role to serve the API. The runtime role SHALL NOT be a superuser, bypass row-level security, create databases or roles, own application objects, or be a member of the owner role. The repository SHALL provide idempotent bootstrap SQL for these roles and the `audit` schema, without committed production passwords. Bootstrap SHALL grant the owner `CREATE` on `public` and SHALL revoke `CREATE` on `public` from `PUBLIC`.

#### Scenario: Compose uses separate roles
- **WHEN** Docker Compose starts from an empty volume
- **THEN** `migrate` connects as the owner role and `app` connects as the runtime role

#### Scenario: Bootstrap is repeatable
- **WHEN** the bootstrap SQL runs twice
- **THEN** the second run succeeds and privileges are unchanged

#### Scenario: Owner can migrate after bootstrap
- **WHEN** the owner role runs migrations on a bootstrapped database
- **THEN** migrations succeed without superuser access

### Requirement: Least-privilege runtime access
The runtime role SHALL have `SELECT`, `INSERT`, `UPDATE`, and `DELETE` on application tables in `public`, and only `SELECT` on `audit.audit_events`. It SHALL NOT have `TRUNCATE`, `TRIGGER`, or `REFERENCES` on application or audit tables. It SHALL NOT create objects in `public` or `audit`. Audit event inserts SHALL occur only through the owner-defined trigger function, which SHALL use a fixed `search_path`.

#### Scenario: Direct audit insert rejected
- **WHEN** the runtime role inserts directly into `audit.audit_events`
- **THEN** the database denies permission

#### Scenario: Audited write succeeds
- **WHEN** the runtime role writes a business row with audit context
- **THEN** the row and its audit event commit

#### Scenario: Trigger cannot be disabled
- **WHEN** the runtime role runs `ALTER TABLE companies DISABLE TRIGGER ALL`
- **THEN** the database denies permission

#### Scenario: Truncate denied
- **WHEN** the runtime role truncates `companies`
- **THEN** the database denies permission

#### Scenario: Schema change denied
- **WHEN** the runtime role creates a table
- **THEN** the database denies permission

### Requirement: Unsafe serving role rejected
When serving in the production environment, the system SHALL fail startup if its database session user is a superuser or a member of the role that owns the `audit` schema. In other non-testing environments, it SHALL log a warning. Migration and operational commands SHALL NOT be subject to this startup check.

#### Scenario: Production owner connection
- **WHEN** the API starts with `--env production` as the audit schema owner
- **THEN** startup fails without logging credentials

#### Scenario: Production runtime connection
- **WHEN** the API starts with `--env production` as the runtime role
- **THEN** startup continues

#### Scenario: Migration uses owner role
- **WHEN** `migrate` runs as the owner role in production
- **THEN** the startup check does not block it
