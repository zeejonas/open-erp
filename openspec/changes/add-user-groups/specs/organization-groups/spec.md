## ADDED Requirements

### Requirement: Groups
Members with group permissions SHALL be able to create, list, view, rename, and delete groups in their organization. A group SHALL have a name unique among the organization's active groups. `GET /groups/:groupID` SHALL include the IDs of the group's active roles and eligible companies. A group with active members or pending invitations SHALL NOT be deletable. Deleting a group SHALL soft-delete it with `deleted_by`, after which it grants nothing, and its name SHALL be reusable.

#### Scenario: Create group
- **WHEN** a member with `group:create` creates group "AP Clerks"
- **THEN** the group is created in the caller's organization with `created_by` set

#### Scenario: Duplicate name
- **WHEN** a group is created or renamed to a name already used by an active group in the organization
- **THEN** the system responds `409 Conflict`

#### Scenario: Delete group in use
- **WHEN** a member deletes a group that has active members or a pending invitation
- **THEN** the system responds `409 Conflict`

#### Scenario: Group from another organization
- **WHEN** a member of organization B reads, updates, or deletes a group belonging to organization A by ID
- **THEN** the system responds `404 Not Found` and the group is unchanged

### Requirement: Group membership
Members with `group_member:create` SHALL be able to add an active member of the organization to a group. Members with `group_member:read` SHALL be able to list a group's active members, and members with `group_member:delete` SHALL be able to remove a member from a group by soft delete with `deleted_by`. Re-adding a removed member SHALL create a new group membership rather than restore the removed one. Duplicate active memberships SHALL be rejected.

#### Scenario: Add member
- **WHEN** a member with `group_member:create` adds an active member to "AP Clerks"
- **THEN** the group membership is created with `created_by` set

#### Scenario: Add non-member
- **WHEN** the target user is not an active member of the organization
- **THEN** the system responds `404 Not Found`

#### Scenario: Duplicate membership
- **WHEN** the user is already an active member of the group
- **THEN** the system responds `409 Conflict`

#### Scenario: Remove member from group
- **WHEN** a member with `group_member:delete` removes a user from a group
- **THEN** the group membership is soft-deleted with `deleted_by` set, and the user loses the group's permissions on their next request

### Requirement: Group roles
Members with `group_role:create` SHALL be able to attach a role from their organization to a group, and members with `group_role:delete` SHALL be able to detach it by soft delete with `deleted_by`. A group SHALL be able to hold both organization-level and company-level roles. Attaching a role from another organization SHALL be rejected. Duplicate active attachments SHALL be rejected.

#### Scenario: Attach role
- **WHEN** a member with `group_role:create` attaches "Organization Viewer" to a group
- **THEN** every active member of the group holds the role's permissions on their next request

#### Scenario: Mixed levels
- **WHEN** a group already holds an organization-level role and a company-level role is attached
- **THEN** the attachment is created

#### Scenario: Role from another organization
- **WHEN** the role belongs to another organization
- **THEN** the system responds `400 Bad Request` and nothing is created

#### Scenario: Duplicate role
- **WHEN** the group already holds the role
- **THEN** the system responds `409 Conflict`

#### Scenario: Detach role
- **WHEN** a member with `group_role:delete` detaches a role from a group
- **THEN** the attachment is soft-deleted with `deleted_by` set, and members lose its permissions on their next request

### Requirement: Company eligibility
Members with `group_company:create` SHALL be able to make a group eligible at a company in their organization, and members with `group_company:delete` SHALL be able to remove that eligibility by soft delete with `deleted_by`. Eligibility SHALL be the grant: a group's company-level roles SHALL apply at exactly its eligible companies, with no further assignment. A group's organization-level roles SHALL apply organization-wide regardless of eligibility. No group SHALL be eligible at a company unless eligibility was explicitly created, including at newly created companies. Deleting a company SHALL soft-delete every eligibility at that company with `deleted_by`, in the same transaction as the company. Enforcing company-level permissions is out of scope for this change.

#### Scenario: Add eligibility
- **WHEN** a member with `group_company:create` makes "AP Clerks" eligible at Acme East
- **THEN** the eligibility is created with `created_by` set

#### Scenario: New company
- **WHEN** a company is created
- **THEN** no group is eligible at it

#### Scenario: Company from another organization
- **WHEN** the company belongs to another organization or is deleted
- **THEN** the system responds `400 Bad Request` and nothing is created

#### Scenario: Duplicate eligibility
- **WHEN** the group is already eligible at the company
- **THEN** the system responds `409 Conflict`

#### Scenario: Deleted company
- **WHEN** a member with `company:delete` deletes a company where groups are eligible
- **THEN** each of those eligibilities is soft-deleted with `deleted_by` set, and no group lists the company

#### Scenario: Removing eligibility keeps organization-level access
- **WHEN** a group holding "Organization Viewer" has its only eligible company removed
- **THEN** its members still hold the Organization Viewer permissions

### Requirement: Group templates
The system SHALL define group templates in code, each naming role templates by key. Provisioning an organization SHALL copy every group template into that organization as an ordinary, editable group attached to the copied roles, recording `template_key` for reporting only. Copied groups SHALL have no members and no eligible companies. `template_key` SHALL NOT influence any access decision. This change SHALL ship:

- **Organization Administrators** (`org_admins`): the Organization Administrator role.
- **Organization Viewers** (`org_viewers`): the Organization Viewer role.

#### Scenario: Templates copied at provisioning
- **WHEN** an organization is provisioned
- **THEN** it has an "Organization Administrators" group holding the Organization Administrator role and an "Organization Viewers" group holding the Organization Viewer role

#### Scenario: Copied group is editable
- **WHEN** a member with `group_role:delete` detaches the role from the copied "Organization Viewers"
- **THEN** the change applies to that organization only
