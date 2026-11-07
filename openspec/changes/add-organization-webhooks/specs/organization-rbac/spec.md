## MODIFIED Requirements

### Requirement: Permission catalog
The system SHALL define permissions in code as `resource:action`, where action is one of `create`, `read`, `update`, `delete`, or the explicitly defined emergency `disable`, and each permission has a level of `organization` or `company`. Every permission in the catalog SHALL be enforced by at least one route. The catalog SHALL contain the following organization-level permissions:

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
- `webhook_subscription:create`, `webhook_subscription:read`, `webhook_subscription:update`, `webhook_subscription:delete`, `webhook_subscription:disable`
- `webhook_event:read`, `webhook_payload:read`, `webhook_delivery:read`, `webhook_secret:read`

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

#### Scenario: Webhook permissions are explicit
- **WHEN** an authorized member reads the permission catalog
- **THEN** every webhook permission is listed at organization level and no permission implies another

### Requirement: Role templates
The system SHALL define role templates in code. Provisioning an organization SHALL copy every template into that organization as ordinary, editable roles, recording `template_key` for reporting only. Later template changes SHALL NOT alter existing organizations' roles, and `template_key` SHALL NOT influence any access decision. This change SHALL ship:

- **Organization Administrator** (`org_admin`, organization level): every organization-level permission.
- **Organization Viewer** (`org_viewer`, organization level): every organization-level `:read` permission except `webhook_payload:read` and `webhook_secret:read`. Payload inspection and secret disclosure SHALL each require an explicit separate grant, even for a copied viewer role.

#### Scenario: Templates copied at provisioning
- **WHEN** an organization is provisioned
- **THEN** it has an "Organization Administrator" role and an "Organization Viewer" role with the template permissions

#### Scenario: Copied role is editable
- **WHEN** a member with `role:update` removes a permission from the copied "Organization Viewer"
- **THEN** the change applies to that organization only

#### Scenario: Viewer has metadata but not payload access
- **WHEN** an organization is provisioned
- **THEN** its viewer role contains webhook subscription/event/delivery read permissions but not payload-read, secret-read, disable or management permissions

#### Scenario: Existing roles are not silently promoted
- **WHEN** the new permission catalog is deployed to a retained pre-release database
- **THEN** copied roles remain unchanged unless an explicit audited bootstrap grants permissions to identified existing full administrators, and partial custom roles are not promoted

## ADDED Requirements

### Requirement: Webhook route authorization
Webhook routes SHALL enforce the permissions defined by business-events, webhook-subscriptions and webhook-delivery, using the same organization membership and effective-permission rules as existing routes. Payload inspection and secret disclosure SHALL each require their explicit additional permission. Neither platform-administrator status nor managing a subscription SHALL implicitly grant tenant payload or secret access. Permission rejection SHALL occur before querying protected payloads or secrets or creating approval/publication work.

#### Scenario: Platform status does not imply tenant access
- **WHEN** a platform administrator without tenant membership requests tenant webhook payloads
- **THEN** access is denied without exposing payloads

#### Scenario: Management is not payload read
- **WHEN** a member has subscription update but lacks payload-read
- **THEN** that permission alone does not authorize a payload-inspection route
