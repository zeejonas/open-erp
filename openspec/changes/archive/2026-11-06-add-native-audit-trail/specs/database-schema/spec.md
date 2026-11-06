## ADDED Requirements

### Requirement: Tenant ownership on every tenant table
Every tenant-owned table SHALL have a required `organization_id` referencing `organizations`. `approval_decisions`, `approval_policy_slots`, `approval_policy_versions`, `approval_request_tracks`, `company_users`, `group_companies`, `group_members`, `group_roles`, and `role_permissions` SHALL gain this column by editing their create migrations. A reference from a tenant-owned table to a tenant-owned parent SHALL be a composite foreign key that includes `organization_id`, including `approval_policies.company_id`, `organization_invitations.group_id`, and `organization_invitations.approval_request_id`. `users`, `organizations`, and `revoked_access_tokens` SHALL remain global.

#### Scenario: Cross-tenant child rejected
- **WHEN** a `group_members` row names a group in one organization and a membership in another
- **THEN** the database rejects the insert

#### Scenario: Mismatched parent rejected
- **WHEN** a `role_permissions` row has an organization that differs from its role's organization
- **THEN** the database rejects the insert

#### Scenario: Existing tenant table cannot cross tenants
- **WHEN** an invitation names a group from another organization
- **THEN** the database rejects the insert

#### Scenario: Optional parent can be empty
- **WHEN** an invitation has no group
- **THEN** the database accepts the insert

#### Scenario: Tenant value required
- **WHEN** a row is inserted into a listed table without `organization_id`
- **THEN** the database rejects the insert

#### Scenario: Application writes tenant
- **WHEN** an API write creates a child row in a listed table
- **THEN** the row stores the same organization as its parent

### Requirement: Create migrations install audit capture
`CreateAuditEvent` SHALL be registered first and SHALL require the `audit` schema created by bootstrap. Each create migration for an application table SHALL install change capture on that table. Reverting all migrations SHALL remove application tables, audit tables, and audit functions. It SHALL keep the `audit` schema so bootstrap grants survive a revert.

#### Scenario: Fresh schema is audited
- **WHEN** all migrations run on an empty bootstrapped database
- **THEN** the audit coverage check reports no problems

#### Scenario: Full revert removes audit objects
- **WHEN** every migration is reverted
- **THEN** no audit table or capture function remains

#### Scenario: Grants survive revert and migrate
- **WHEN** an owner reverts and reruns all migrations after bootstrap
- **THEN** the runtime role can still read `audit.audit_events` and cannot write to it
