# organization-rbac

## Purpose

Zero-trust organization permissions granted only through groups, and roles copied from templates. Enforcing company-level permissions is out of scope.
## Requirements
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

### Requirement: Zero-trust enforcement
A user SHALL hold an organization-level permission in an organization only if their active membership belongs, through an active group membership, to an active group in that organization that holds an active attachment to an active organization-level role whose permissions include it. Groups SHALL be the only path to a role. No permission SHALL be implied by a missing, null, or default value, by template origin, by company eligibility, or by the platform administrator flag.

#### Scenario: Granted permission
- **WHEN** a member of a group holding a role containing `company:read` calls `GET /companies`
- **THEN** the system responds `200 OK`

#### Scenario: Missing permission
- **WHEN** a member with no group whose roles contain `company:create` calls `POST /companies`
- **THEN** the system responds `403 Forbidden` and nothing is created

#### Scenario: Member with no groups
- **WHEN** a member who belongs to no groups calls any organization-scoped route
- **THEN** the system responds `403 Forbidden`

#### Scenario: Group with no roles
- **WHEN** a member belongs only to groups that hold no roles
- **THEN** organization-scoped routes respond `403 Forbidden`

#### Scenario: Deleted group
- **WHEN** a member's only granting group is soft-deleted
- **THEN** their next request requiring that group's permissions responds `403 Forbidden`

#### Scenario: Group in another organization
- **WHEN** a user belongs to a group in organization A that holds `company:read`, and calls `GET /companies` for organization B where they belong to no group
- **THEN** the system responds `403 Forbidden`

### Requirement: Route permissions
Organization-scoped routes SHALL require these permissions. A gateable write SHALL require its permission before it is matched to approval policies. Approving, rejecting, and withdrawing require no permission and are authorized by approver eligibility and by being the requester, as the approval-workflows capability defines.

| Route | Permission |
|---|---|
| `GET /me/access` | None; active membership |
| `GET /permissions` | `role:read` |
| `GET /organization` | `organization:read` |
| `PATCH /organization` | `organization:update` |
| `DELETE /organization` | `organization:delete` |
| `GET /companies`, `GET /companies/:id` | `company:read` |
| `POST /companies` | `company:create` |
| `PATCH /companies/:id` | `company:update` |
| `DELETE /companies/:id` | `company:delete` |
| `GET /users`, `GET /users/:id` | `organization_user:read` |
| `DELETE /organization-users/:userID` | `organization_user:delete` |
| `POST /organization-invitations` | `organization_invitation:create` |
| `GET /organization-invitations` | `organization_invitation:read` |
| `DELETE /organization-invitations/:id` | `organization_invitation:delete` |
| `POST /roles` | `role:create` |
| `GET /roles`, `GET /roles/:id` | `role:read` |
| `PATCH /roles/:id` | `role:update` |
| `DELETE /roles/:id` | `role:delete` |
| `POST /groups` | `group:create` |
| `GET /groups`, `GET /groups/:groupID` | `group:read` |
| `PATCH /groups/:groupID` | `group:update` |
| `DELETE /groups/:groupID` | `group:delete` |
| `POST /groups/:groupID/members` | `group_member:create` |
| `GET /groups/:groupID/members` | `group_member:read` |
| `DELETE /groups/:groupID/members/:userID` | `group_member:delete` |
| `POST /groups/:groupID/roles` | `group_role:create` |
| `DELETE /groups/:groupID/roles/:roleID` | `group_role:delete` |
| `POST /groups/:groupID/companies` | `group_company:create` |
| `DELETE /groups/:groupID/companies/:companyID` | `group_company:delete` |
| `GET /approval-catalog` | `approval_policy:read` |
| `POST /approval-policies` | `approval_policy:create` |
| `GET /approval-policies`, `GET /approval-policies/:id`, `GET /approval-policies/:id/versions` | `approval_policy:read` |
| `PATCH /approval-policies/:id` | `approval_policy:update` |
| `DELETE /approval-policies/:id` | `approval_policy:delete` |
| `GET /approval-requests` | `approval_request:read` |
| `GET /approval-requests/awaiting-me` | None; active membership, with results limited to requests the caller can approve |
| `GET /approval-requests/:id` | `approval_request:read`, or the requester, or a currently eligible approver |
| `POST /approval-requests/:id/override` | `approval_override:create` |

#### Scenario: Each route enforces its permission
- **WHEN** a member lacking the listed permission calls the route
- **THEN** the system responds `403 Forbidden`

#### Scenario: Role assignment routes removed
- **WHEN** a client calls `POST /organization-role-assignments`
- **THEN** the system responds `404 Not Found`

### Requirement: Roles
Members with role permissions SHALL be able to manage roles in their organization. A role SHALL have a name unique within its organization, a required level (`organization` or `company`) with no default, and a set of permissions whose levels all equal the role's level. A role's level SHALL NOT change after creation. A role attached to an active group SHALL NOT be deletable. A deleted role's name SHALL be reusable. Removing a permission from a role SHALL soft-delete the grant with `deleted_by`, so the history of every role's permissions is kept.

#### Scenario: Create organization-level role
- **WHEN** a member with `role:create` creates role "Auditor" with level `organization` and `company:read`
- **THEN** the role is created in the caller's organization

#### Scenario: Level mismatch
- **WHEN** a role with level `company` is given an organization-level permission
- **THEN** the system responds `400 Bad Request`

#### Scenario: Missing level
- **WHEN** a role is created without a level
- **THEN** the system responds `400 Bad Request`

#### Scenario: Duplicate name
- **WHEN** a role is created with a name already used in the organization
- **THEN** the system responds `409 Conflict`

#### Scenario: Delete role in use
- **WHEN** a member deletes a role attached to an active group
- **THEN** the system responds `409 Conflict`

#### Scenario: Delete role held only by a deleted group
- **WHEN** a member deletes a role whose only attachment is to a soft-deleted group
- **THEN** the role is soft-deleted

#### Scenario: Permission change takes effect immediately
- **WHEN** a permission is removed from a role
- **THEN** every member of every group holding that role loses the permission on their next request

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

### Requirement: Administrator continuity
An organization administrator SHALL be an active member holding every organization-level permission in the catalog. The system SHALL refuse, with `409 Conflict` and a `detail` stating why, any member removal, group member removal, group role removal, or role permission removal that would take the organization's number of administrators from one or more to zero. It SHALL evaluate this when a change is submitted and again when it is applied, and a held change that would cause this at apply SHALL end `failed`. Concurrent changes SHALL NOT together remove the last administrator. `template_key` SHALL NOT affect this rule.

#### Scenario: Removing the last administrator
- **WHEN** the only administrator removes themselves with `DELETE /organization-users/:userID`
- **THEN** the system responds `409` and the membership remains

#### Scenario: Removing the last group membership
- **WHEN** a member removes the only administrator from the group that grants their permissions
- **THEN** the system responds `409` and the group membership remains

#### Scenario: Removing the role from the group
- **WHEN** a member removes the administrator role from the only group holding it for any member
- **THEN** the system responds `409` and the attachment remains

#### Scenario: Narrowing the role
- **WHEN** a member removes `company:read` from the only role that makes anyone an administrator
- **THEN** the system responds `409` and the role is unchanged

#### Scenario: Another administrator remains
- **WHEN** two members are administrators and one is removed
- **THEN** the removal succeeds

#### Scenario: Administrator through a custom group
- **WHEN** a member holds every permission through a custom group, and the last member of Organization Administrators is removed
- **THEN** the removal succeeds

#### Scenario: Partial permissions
- **WHEN** a member holds every permission except one, and the only full administrator is removed
- **THEN** the system responds `409`

#### Scenario: No administrator today
- **WHEN** no member currently holds every permission and a member is removed
- **THEN** this rule does not refuse the removal

#### Scenario: Held removals applied in turn
- **WHEN** two held requests each remove one of two administrators, and the first is applied
- **THEN** approving the second ends it `failed` with its reason, and one administrator remains

#### Scenario: Concurrent removals
- **WHEN** two requests remove each of two administrators at the same time
- **THEN** one succeeds and the other responds `409`

#### Scenario: Unauthorized removal
- **WHEN** a member lacking `organization_user:delete` removes the last administrator
- **THEN** the system responds `403 Forbidden`

### Requirement: Caller access
The system SHALL expose `GET /me/access` to any active member of the organization selected by `X-Organization-ID`, returning that organization's ID and the caller's effective organization-level permissions, sorted. The result SHALL be computed by the same rule that enforces permissions. It SHALL be a complete single resource and SHALL NOT be paged. It SHALL be advisory for clients and SHALL grant nothing.

#### Scenario: Administrator
- **WHEN** an administrator calls `GET /me/access`
- **THEN** the response lists every organization-level permission

#### Scenario: Member with no group
- **WHEN** a member with no group calls `GET /me/access`
- **THEN** the system responds `200` with an empty `permissions` list

#### Scenario: Access differs per organization
- **WHEN** a person is an administrator of organization A and a viewer of organization B, and calls with B selected
- **THEN** only the viewer's permissions are returned

#### Scenario: Not a member
- **WHEN** a person calls with an organization they do not belong to
- **THEN** the system responds `403 Forbidden` and does not reveal whether it exists

#### Scenario: Removed member
- **WHEN** a member is removed and then calls `GET /me/access`
- **THEN** the system responds `403 Forbidden`

#### Scenario: Missing organization
- **WHEN** a person calls without `X-Organization-ID`
- **THEN** the system responds `400 Bad Request`

### Requirement: Permission catalog discovery
The system SHALL expose `GET /permissions` to members holding `role:read`, listing every permission in the catalog with its level, including permissions that cannot require approval. The catalog is defined in code and SHALL be the same for every organization.

#### Scenario: Full catalog
- **WHEN** a member with `role:read` lists every page of `GET /permissions`
- **THEN** every catalog permission appears once, including `company:read` and `approval_override:create`

#### Scenario: Without permission
- **WHEN** a member without `role:read` calls `GET /permissions`
- **THEN** the system responds `403 Forbidden`

#### Scenario: Not a member
- **WHEN** a person calls with an organization they do not belong to
- **THEN** the system responds `403 Forbidden`

### Requirement: Audit route permission
`GET /audit-events` SHALL require `audit_event:read`.

#### Scenario: Permission grants access
- **WHEN** a member whose role holds `audit_event:read` calls `GET /audit-events`
- **THEN** the system responds `200`

#### Scenario: Other organization's permission does not apply
- **WHEN** a user holds `audit_event:read` in one organization and supplies another organization where they hold no such permission
- **THEN** the system responds `403`

### Requirement: Webhook route authorization
Webhook routes SHALL enforce the permissions defined by business-events, webhook-subscriptions and webhook-delivery, using the same organization membership and effective-permission rules as existing routes. Payload inspection and secret disclosure SHALL each require their explicit additional permission. Neither platform-administrator status nor managing a subscription SHALL implicitly grant tenant payload or secret access. Permission rejection SHALL occur before querying protected payloads or secrets or creating approval/publication work.

#### Scenario: Platform status does not imply tenant access
- **WHEN** a platform administrator without tenant membership requests tenant webhook payloads
- **THEN** access is denied without exposing payloads

#### Scenario: Management is not payload read
- **WHEN** a member has subscription update but lacks payload-read
- **THEN** that permission alone does not authorize a payload-inspection route

### Requirement: Service account permissions
The permission catalog SHALL include the organization-level permissions `service_account:create`, `service_account:read`, `service_account:update`, `service_account:delete`, and `service_account:disable`, enforced on these routes:

| Route | Permission |
|---|---|
| `POST /service-accounts` | `service_account:create` |
| `GET /service-accounts`, `GET /service-accounts/:id` | `service_account:read` |
| `PATCH /service-accounts/:id` | `service_account:update` |
| `POST /service-accounts/:id/disable` | `service_account:disable` |
| `DELETE /service-accounts/:id` | `service_account:delete` |

Service accounts SHALL receive permissions only through active group memberships, as people do, and the system SHALL NOT restrict which permissions a service account can be granted.

#### Scenario: Route enforces permission
- **WHEN** a member lacking `service_account:disable` calls `POST /service-accounts/:id/disable`
- **THEN** the system responds `403 Forbidden` and the account stays enabled

#### Scenario: Permissions through groups
- **WHEN** a service account is added to a group whose role grants `company:read`
- **THEN** the account can call `GET /companies`, and cannot call `POST /companies`

#### Scenario: Templates include the permissions
- **WHEN** an organization is provisioned
- **THEN** "Organization Administrator" holds every `service_account` permission and "Organization Viewer" holds `service_account:read`

### Requirement: Service accounts are not administrators
Administrator continuity SHALL count only people. A service account holding every organization-level permission SHALL NOT count as an administrator, so removing the last person administrator SHALL be refused even when such a service account exists.

#### Scenario: Bot cannot replace the last administrator
- **WHEN** a service account holds every organization-level permission and a member removes the only person administrator
- **THEN** the system responds `409 Conflict` and the membership remains

