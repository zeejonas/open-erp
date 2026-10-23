# approval-workflows

## Purpose

Approval policies and versions, the approval catalog, matching writes to policies, approval requests and their lifecycle, approver eligibility, applying approved changes, master and operator override, and held invitations.

## Requirements

### Requirement: Approval catalog
The system SHALL define in code which permissions can require approval and which fields each exposes. Every `create`, `update`, and `delete` permission in the catalog SHALL be gateable except `approval_override:create`. Each gateable `update` permission SHALL list every field its endpoint can change, by API name:

| Permission | Fields |
|---|---|
| `organization:update` | `code`, `name` |
| `company:update` | `code`, `name` |
| `role:update` | `name`, `permissions` |
| `group:update` | `name` |
| `approval_policy:update` | `name`, `fields`, `companyId`, `stages` |

`GET /approval-catalog` SHALL return every gateable permission, its fields, and whether it supports company scope. Company scope SHALL be supported exactly for `company:update`, `company:delete`, `group:update`, `group:delete`, `group_member:create`, `group_member:delete`, `group_role:create`, `group_role:delete`, `group_company:create`, and `group_company:delete`.

#### Scenario: Read catalog
- **WHEN** a member with `approval_policy:read` calls `GET /approval-catalog`
- **THEN** the response lists `role:update` with fields `name` and `permissions`, and does not list `approval_override:create` or any `:read` permission

#### Scenario: Catalog requires permission
- **WHEN** a member without `approval_policy:read` calls `GET /approval-catalog`
- **THEN** the system responds `403 Forbidden`

### Requirement: Approval policies
Members with approval policy permissions SHALL be able to create, list, view, edit, and delete approval policies in their organization. A policy SHALL have a name unique among the organization's active policies, one gateable permission, an optional list of fields, an optional company, and one or more stages. Each stage SHALL have one or more slots, and each slot SHALL name an active group in the organization and a required approval count of at least 1. A group SHALL appear at most once per stage. The system SHALL respond `400 Bad Request` when the permission is not gateable, when fields are given for a permission that is not an `update`, when a field is not listed in the catalog for that permission, when a company is given for a permission without company scope, when the company is not an active company in the organization, when a group is not an active group in the organization, or when a slot's required count exceeds its group's active members. A policy's permission SHALL NOT change after creation.

#### Scenario: Create multi-stage policy
- **WHEN** a member with `approval_policy:create` creates "Role changes" on `role:update` with fields `permissions`, stage 1 needing 1 from "Security" and 1 from "IT", and stage 2 needing 1 from "CFO Office"
- **THEN** the policy is created as version 1 with `created_by` set

#### Scenario: Unknown field
- **WHEN** a policy on `company:update` lists field `company_code`
- **THEN** the system responds `400` and names the field

#### Scenario: Fields on a non-update permission
- **WHEN** a policy on `company:delete` lists any field
- **THEN** the system responds `400`

#### Scenario: Company on an unscoped permission
- **WHEN** a policy on `role:update` names a company
- **THEN** the system responds `400`

#### Scenario: Group from another organization
- **WHEN** a slot names a group belonging to organization A in a policy created in organization B
- **THEN** the system responds `400` and nothing is created

#### Scenario: Slot larger than its group
- **WHEN** a slot requires 3 approvals from a group with 2 active members
- **THEN** the system responds `400`

#### Scenario: Duplicate name
- **WHEN** a policy is created or renamed to a name used by an active policy in the organization
- **THEN** the system responds `409 Conflict`

#### Scenario: Policy from another organization
- **WHEN** a member of organization B reads, edits, or deletes a policy belonging to organization A by ID
- **THEN** the system responds `404 Not Found` and the policy is unchanged

#### Scenario: Missing permission
- **WHEN** a member without `approval_policy:create` creates a policy
- **THEN** the system responds `403 Forbidden`

### Requirement: Policy versions
Creating a policy SHALL record version 1. Every edit SHALL record the next version, an immutable snapshot of the full definition with `created_by` and `created_at`. Deleting a policy SHALL soft-delete it with `deleted_by` and keep its versions. `GET /approval-policies/:id/versions` SHALL list a policy's versions for members with `approval_policy:read`. No route SHALL change or remove a version.

#### Scenario: Edit records a version
- **WHEN** a member with `approval_policy:update` changes stage 2's group of policy "Role changes"
- **THEN** version 2 holds the new definition and version 1 is unchanged

#### Scenario: Deleted policy keeps history
- **WHEN** a policy with 3 versions is deleted
- **THEN** it no longer matches writes and its 3 versions remain readable by ID

### Requirement: Policy references
A group named by any slot of an active policy SHALL NOT be deletable. A company named by an active policy SHALL NOT be deletable.

#### Scenario: Delete approver group
- **WHEN** a member deletes a group that an active policy uses as an approver pool
- **THEN** the system responds `409 Conflict`

#### Scenario: Delete scoped company
- **WHEN** a member deletes a company that an active policy is scoped to
- **THEN** the system responds `409 Conflict`

### Requirement: Matching writes to policies
When a member calls a gateable write and holds its permission, the system SHALL validate the request as it does today and then find every active policy in the organization that matches it. A policy SHALL match when its permission equals the write's permission, when it lists no fields or the write changes at least one listed field to a different value, and when it names no company or the write's company context includes that company. The write's company context SHALL be the company itself for `company:update` and `company:delete`, the linked company for `group_company:*`, the group's active eligible companies for `group:update`, `group:delete`, `group_member:*`, `group_role:*`, and an invitation into a group, and empty otherwise. An invitation into a group SHALL also be matched against `group_member:create` policies, because accepting it adds a group member. When no policy matches, the write SHALL apply immediately with today's response. When one or more policies match, the system SHALL create an approval request with one track per matching policy, referencing that policy's current version, and SHALL respond `202 Accepted` with the request. Matching SHALL use the policies in force at submission, including for writes to approval policies themselves.

#### Scenario: No policies
- **WHEN** an organization has no approval policies and a member with `company:update` renames a company
- **THEN** the company is renamed and the system responds `200 OK`

#### Scenario: Matching write is held
- **WHEN** policy "Role changes" covers `role:update` field `permissions` and a member with `role:update` adds a permission to a role
- **THEN** the system responds `202` with a pending request, and the role's permissions are unchanged

#### Scenario: Unlisted field passes through
- **WHEN** the same member renames the role without changing its permissions
- **THEN** the role is renamed immediately

#### Scenario: Unchanged value does not match
- **WHEN** a `PATCH` sends the role's current permissions unchanged together with a new name
- **THEN** "Role changes" does not match and the rename applies immediately

#### Scenario: Several policies match
- **WHEN** an organization-wide policy and a policy scoped to company A both cover `company:update`, and a member renames company A
- **THEN** the request has two tracks, one per policy

#### Scenario: Company routing
- **WHEN** a policy scoped to company A covers `company:update` and a member renames company B
- **THEN** the rename applies immediately

#### Scenario: Group eligible at several companies
- **WHEN** group G is eligible at companies A and B, policies scoped to A and to B cover `group_member:create`, and a member adds a user to G
- **THEN** the request has a track for each policy

#### Scenario: Invitation into a gated group
- **WHEN** a policy covers `group_member:create` and a member with `organization_invitation:create` invites a user into a group
- **THEN** the system responds `202` with a pending request that has a track for that policy

#### Scenario: Missing permission still forbidden
- **WHEN** a member without `role:update` calls `PATCH /roles/:id`
- **THEN** the system responds `403 Forbidden` and no request is created

#### Scenario: Invalid write rejected before holding
- **WHEN** a held write would fail validation, for example a role permission not in the catalog
- **THEN** the system responds `400` and no request is created

#### Scenario: Loosening a policy
- **WHEN** policy P covers `approval_policy:update` and a member edits P to remove its own stage
- **THEN** the edit is held under P's current version and P is unchanged until approved

### Requirement: Approver eligibility and stages
Within each track, stages SHALL proceed in order, and only the current stage SHALL accept approvals. A member SHALL be eligible in a track when they belong, through an active group membership, to a group named by a slot of the track's current stage, they are not the requester, and they have not already approved in that track. Group membership SHALL be evaluated at decision time. Approving SHALL record one decision in every pending track where the member is eligible, including the groups that qualified them, and SHALL respond `403 Forbidden` when they are eligible in none. A stage SHALL complete when its approvers can be assigned to its slots, one slot per approver, so that every slot reaches its required count. A track SHALL be approved when its last stage completes. The request SHALL apply when every track is approved.

#### Scenario: Requester cannot approve
- **WHEN** the requester belongs to an approver group and approves their own request
- **THEN** the system responds `403 Forbidden` and no decision is recorded

#### Scenario: Parallel slots
- **WHEN** stage 1 needs 1 from "Security" and 1 from "IT", and only a Security member has approved
- **THEN** stage 1 is not complete, and it completes once an IT member approves

#### Scenario: One person cannot fill two slots
- **WHEN** a member of both "Security" and "IT" approves stage 1 and nobody else has
- **THEN** stage 1 is not complete

#### Scenario: Best slot assignment
- **WHEN** stage 1 needs 1 from "Security" and 1 from "IT", member X belongs to both, member Y belongs only to "Security", and X and Y have approved
- **THEN** stage 1 is complete

#### Scenario: Sequential stages
- **WHEN** a member of the stage 2 group approves while stage 1 is incomplete, and is not eligible for stage 1
- **THEN** the system responds `403 Forbidden`

#### Scenario: Count in several tracks
- **WHEN** a member belongs to an approver group in both tracks of a request and approves once
- **THEN** a decision is recorded in each track

#### Scenario: Removed approver
- **WHEN** a member is removed from the approver group after the request was submitted and then approves
- **THEN** the system responds `403 Forbidden`

#### Scenario: Request from another organization
- **WHEN** a member of organization B approves a request belonging to organization A
- **THEN** the system responds `404 Not Found`

### Requirement: Rejection and withdrawal
An eligible approver SHALL be able to reject a pending request with a required comment, which SHALL end the request as `rejected`. The requester SHALL be able to withdraw their own pending request, which SHALL end it as `withdrawn`. Only `pending` requests SHALL accept decisions or withdrawal, and other requests SHALL respond `409 Conflict`.

#### Scenario: Reject
- **WHEN** an eligible approver rejects a pending request with a comment
- **THEN** the request is `rejected` and the change is not applied

#### Scenario: Reject without comment
- **WHEN** an eligible approver rejects without a comment
- **THEN** the system responds `400`

#### Scenario: Withdraw
- **WHEN** the requester withdraws their pending request
- **THEN** the request is `withdrawn`

#### Scenario: Withdraw someone else's request
- **WHEN** a member who is not the requester withdraws a request
- **THEN** the system responds `403 Forbidden`

#### Scenario: Decide a closed request
- **WHEN** an approver approves a request that is already `applied`
- **THEN** the system responds `409 Conflict`

### Requirement: Applying approved changes
When a request's last track is approved, the system SHALL apply the change in the same transaction as the final decision, attribute it to the requester (`created_by`, `updated_by`, or `deleted_by`), and mark the request `applied`. Before applying, the system SHALL re-check that the requester is still an active member holding the permission, that every touched field still has the value recorded at submission, that the target still exists, and that today's uniqueness and delete rules hold. If any check fails, the change SHALL NOT apply, and the decision SHALL be recorded with the request marked `failed` and a reason. Concurrent final decisions SHALL apply a change at most once.

#### Scenario: Apply on final approval
- **WHEN** the last required approval is recorded on a request to rename company A
- **THEN** company A is renamed with `updated_by` set to the requester, and the request is `applied`

#### Scenario: Stale value
- **WHEN** company A was renamed directly after a held rename was submitted, and the held rename is then approved
- **THEN** the request is `failed`, the decision is recorded, and the direct rename stands

#### Scenario: Requester lost the permission
- **WHEN** the requester no longer holds `company:update` when the final approval is recorded
- **THEN** the request is `failed` and the company is unchanged

#### Scenario: Uniqueness at apply
- **WHEN** a held company create is approved after another company took its code
- **THEN** the request is `failed` and no company is created

#### Scenario: Concurrent final approvals
- **WHEN** two eligible approvers submit the final approval at the same time
- **THEN** the change applies once

### Requirement: Master override
A member holding `approval_override:create` SHALL be able to complete a pending request in one action with a required reason, regardless of stages and tracks, except on a request they made. The override SHALL be recorded as a decision of kind `override` and SHALL apply the change under the same checks as a final approval.

#### Scenario: Override
- **WHEN** a member with `approval_override:create` overrides a request whose stage 1 is incomplete, with a reason
- **THEN** the change applies and one `override` decision is recorded

#### Scenario: Override own request
- **WHEN** the requester holds `approval_override:create` and overrides their own request
- **THEN** the system responds `403 Forbidden`

#### Scenario: Override without permission
- **WHEN** a member without `approval_override:create` overrides a request
- **THEN** the system responds `403 Forbidden`

#### Scenario: Override without reason
- **WHEN** an override has no reason
- **THEN** the system responds `400`

### Requirement: Operator override
The system SHALL provide an `approval-override` CLI command that, given a request ID, an operator name, and a reason, completes the pending request under the same checks as a final approval. It SHALL record an `override` decision with no deciding user, the operator name, and the reason, and SHALL log it. It SHALL NOT depend on the platform administrator flag.

#### Scenario: Stuck request
- **WHEN** an operator runs `approval-override` for a pending request with an operator name and reason
- **THEN** the change applies and the decision records the operator name and reason

#### Scenario: Closed request
- **WHEN** the request is not `pending`
- **THEN** the command fails without changes

### Requirement: Approval requests
A request SHALL record its organization, permission, target, requester, proposed change with before and after values, status (`pending`, `applied`, `rejected`, `withdrawn`, or `failed`), failure reason, tracks, and decisions. Members with `approval_request:read` SHALL be able to list and view every request in their organization. The requester, and members of a group named by the current stage of a pending track, SHALL be able to view that request without `approval_request:read`. A request outside the caller's organization, or one that does not exist, SHALL respond `404 Not Found`.

#### Scenario: Read requests
- **WHEN** a member with `approval_request:read` calls `GET /approval-requests?status=pending`
- **THEN** only the organization's pending requests are returned

#### Scenario: Requester views own request
- **WHEN** a requester without `approval_request:read` calls `GET /approval-requests/:id` for their request
- **THEN** the system responds `200 OK` with its tracks, decisions, and before and after values

#### Scenario: Unrelated member
- **WHEN** a member who lacks `approval_request:read`, did not make the request, and is not eligible on it views it
- **THEN** the system responds `403 Forbidden`

#### Scenario: Request from another organization
- **WHEN** a member of organization B views a request belonging to organization A
- **THEN** the system responds `404 Not Found`

### Requirement: Append-only decisions
Each decision SHALL record its request, track (none for an override), kind (`approve`, `reject`, or `override`), deciding user or operator name, the groups that qualified the decider, comment or reason, and time. No route SHALL change or remove a decision, a request's proposed change, or its tracks' policy versions. The database SHALL reject every update and delete of a decision or a policy version, every delete of a request or a track, every update that changes a request's organization, permission, target, proposed change, requester, or creation time, and every update that changes a track's request, policy version, or creation time, regardless of which code or login issues it. A request's status and failure reason, and a track's stage and status, SHALL remain writable. No foreign key SHALL cascade deletes into these tables.

#### Scenario: Evidence after a policy edit
- **WHEN** a request is applied and its policy is later edited and deleted
- **THEN** the request still shows the policy version it was approved under and every decision

#### Scenario: Direct edit of a decision
- **WHEN** any database session updates or deletes a row in `approval_decisions` or `approval_policy_versions`
- **THEN** the database raises an error and the row is unchanged

#### Scenario: Direct edit of a proposed change
- **WHEN** any database session changes the `change` or `requested_by` of an approval request, or deletes the request
- **THEN** the database raises an error and the row is unchanged

#### Scenario: Direct edit of a track's policy version
- **WHEN** any database session changes a track's `policy_version_id`, or deletes the track
- **THEN** the database raises an error and the row is unchanged

#### Scenario: Status still changes
- **WHEN** a request moves from `pending` to `applied`, including a write that resends its unchanged proposed change
- **THEN** the update succeeds

### Requirement: Held invitations
An invitation whose creation matches a policy SHALL be created with its token returned to the requester in the `202` response, and SHALL NOT be acceptable until its request is applied. Its expiry SHALL start when the request is applied. If the request is rejected, withdrawn, or failed, the invitation SHALL be revoked.

#### Scenario: Accept before approval
- **WHEN** a user accepts an invitation whose request is pending
- **THEN** the system responds `409 Conflict` and no membership is created

#### Scenario: Accept after approval
- **WHEN** the invitation's request is applied, even after the invitation's original expiry, and the user accepts it
- **THEN** the membership and group membership are created

#### Scenario: Rejected invitation
- **WHEN** the invitation's request is rejected
- **THEN** the invitation is revoked and accepting it responds as a revoked invitation does today
