## Why

Any member holding a write permission can act alone, including granting themselves more access through `role:update`, `group_member:create`, or `group_role:create`. Earlier changes accepted that self-escalation risk and deferred approvals. SOX change management and segregation of duties need a second person, or a chain of people, to approve sensitive changes before they take effect. Each tenant has to decide which changes need that.

## What Changes

- Add tenant-defined **approval policies**. A policy targets one write permission (for example `company:update`). It can narrow to specific fields and to one company, and it defines one or more sequential **stages**. Each stage has one or more parallel **slots**, and each slot needs a set number of approvals from one group.
- A write that matches no policy applies immediately, as it does today. A write that matches one or more policies is held as an **approval request**, and the endpoint responds `202 Accepted`. Every matching policy becomes its own track, and the change applies only when every track is approved.
- The requester can never approve their own request. One person fills at most one slot per track but may count in several tracks.
- Changes apply when the final approval lands, attributed to the requester. A request fails rather than overwrite if a touched value changed in the meantime, a uniqueness or delete rule no longer holds, or the requester has lost the permission.
- Policies are versioned. Every edit creates an immutable version, and each request track references the version it was submitted under.
- Policies govern themselves. Creating, editing, or deleting a policy can require approval, and always runs under the policies currently in force.
- Add **master override**: a holder of the new `approval_override:create` permission can complete a whole request in one action with a written reason. Add an operator CLI override for organizations where nobody can.
- An invitation that requires approval is created but cannot be accepted until approved, so its one-time token can still be returned to the requester.
- Add a catalog endpoint listing every permission that can require approval and the fields each update exposes. Tenants can choose any field in the catalog.
- New permissions: `approval_policy:create|read|update|delete`, `approval_request:read`, `approval_override:create`.
- **BREAKING**: Every create, update, and delete endpoint can now respond `202 Accepted` with an approval request instead of its usual response.

## Non-goals

- Conditions on values (for example amounts over a threshold). These come with the first object that needs them.
- Time-based escalation, expiry, reminders, and notifications.
- Approvals on global user identity (`PATCH /me`, `auth_subject`, `is_platform_admin`), which belongs to no single organization.
- New business objects. Policies apply only to the current organization-scoped objects.
- Recommended policy templates and an "awaiting my approval" inbox.
- Approver pools made of individual users or roles. Pools are groups only.

## SOX / SOC Impact

- **Segregation of duties**: Tenants can require a different person, or a sequence of people, to approve any write, including grants of access and changes to the approval policies. Requesters can never approve their own changes, and one person cannot fill two slots in the same track.
- **Access control**: Approval authority comes only from membership in a group named by a policy. The platform administrator flag grants nothing. Override authority is an explicit, grantable permission whose grant can itself require approval.
- **Audit trail**: Requests store the proposed change with its before and after values. Decisions are append-only and record who decided, when, why, and which group qualified them. Database triggers reject edits to decisions, policy versions, requests' proposed changes, and the policy version each track was submitted under, from any code or login. Every policy version is kept, so evidence shows exactly which rule governed each change. Overrides are recorded as overrides, never as ordinary approvals.
- **Change management**: Policy edits are versioned and can require approval under the rules they replace, so a control cannot be loosened by the person it constrains.

## Capabilities

### New Capabilities
- `approval-workflows`: Approval policies and versions, the approval catalog, matching writes to policies, approval requests and their lifecycle, approver eligibility, applying approved changes, master and operator override, and held invitations.

### Modified Capabilities
- `organization-rbac`: The permission catalog adds approval permissions, and the route table adds approval routes.
- `list-endpoints`: Adds `GET /approval-policies`, `GET /approval-policies/:id/versions`, and `GET /approval-requests`, with their filters and order.

## Impact

- **Models and migrations**: New `approval_policies`, `approval_policy_slots`, `approval_policy_versions`, `approval_requests`, `approval_request_tracks`, and `approval_decisions` tables. `organization_invitations` gains an optional `approval_request_id`. Row triggers make decisions, policy versions, and requests' proposed changes append-only. Create migrations follow the pre-release policy.
- **Code**: Every create, update, and delete handler builds a proposed change and submits it through one approval service, which applies it immediately or holds it. New `ApprovalPolicyController` and `ApprovalRequestController`, a new `approval-override` CLI command, and permission loading reused for re-checks at apply time.
- **API**: New `/approval-catalog`, `/approval-policies`, and `/approval-requests` routes. All write endpoints may respond `202`.
- **Tests**: Approval flows, override, staleness, isolation, and governing policies. Existing write tests are unchanged because no policy exists by default.
