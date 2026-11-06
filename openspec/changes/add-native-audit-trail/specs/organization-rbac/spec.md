## MODIFIED Requirements

### Requirement: Permission catalog
The system SHALL define permissions in code as `resource:action`, where action is one of `create`, `read`, `update`, `delete`, and each permission has a level of `organization` or `company`. Every permission in the catalog SHALL be enforced by at least one route. The catalog SHALL contain the following organization-level permissions:

- `organization:read`, `organization:update`, `organization:delete`
- `company:create`, `company:read`, `company:update`, `company:delete`
- `organization_user:read`, `organization_user:delete`
- `organization_invitation:create`, `organization_invitation:read`, `organization_invitation:delete`
- `role:create`, `role:read`, `role:update`, `role:delete`
- `group:create`, `group:read`, `group:update`, `group:delete`
- `group_member:create`, `group_member:read`, `group_member:delete`
- `group_role:create`, `group_role:delete`
- `group_company:create`, `group_company:delete`
- `approval_policy:create`, `approval_policy:read`, `approval_policy:update`, `approval_policy:delete`
- `approval_request:read`
- `approval_override:create`
- `audit_event:read`

#### Scenario: Unknown permission rejected
- **WHEN** a client creates or updates a role with a permission string not in the catalog
- **THEN** the system responds `400 Bad Request`

#### Scenario: Removed assignment permission rejected
- **WHEN** a client creates a role with `organization_role_assignment:create`
- **THEN** the system responds `400 Bad Request`

#### Scenario: Templates include approval permissions
- **WHEN** an organization is provisioned
- **THEN** "Organization Administrator" holds every approval permission including `approval_override:create`, and "Organization Viewer" holds `approval_policy:read` and `approval_request:read`

#### Scenario: Templates include audit read
- **WHEN** an organization is provisioned
- **THEN** "Organization Administrator" and "Organization Viewer" both hold `audit_event:read`

## ADDED Requirements

### Requirement: Audit route permission
`GET /audit-events` SHALL require `audit_event:read`.

#### Scenario: Permission grants access
- **WHEN** a member whose role holds `audit_event:read` calls `GET /audit-events`
- **THEN** the system responds `200`

#### Scenario: Other organization's permission does not apply
- **WHEN** a user holds `audit_event:read` in one organization and supplies another organization where they hold no such permission
- **THEN** the system responds `403`
