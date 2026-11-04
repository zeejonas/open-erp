## Why

An organization can permanently lose its last administrator through ordinary API calls, with no recovery short of editing the database. Approval policies can also be saved that nobody can ever complete. Deleting an organization has no way back. Clients also cannot learn what the caller may do or which permissions exist, so any client building access management must probe with failed requests or copy the catalog.

These were knowingly deferred (`add-user-groups`, `add-oidc-auth-and-org-rbac`). They need to close before self-service administration makes them easy to trigger.

## What Changes

- Refuse any change that would leave an organization without a member holding every organization-level permission, when one exists today.
- Refuse a policy that some possible requester could never get approved, and refuse a member removal that would make an active policy unsatisfiable.
- Add `GET /me/access`, returning the caller's effective permissions in the selected organization.
- Add `GET /permissions`, a paged list of the full permission catalog.
- Add `POST /platform/organizations/:organizationID/restore` and a `deleted` filter on `GET /platform/organizations`, so a platform administrator can find and restore a deleted organization. Each restore records append-only evidence with a required reason.
- **BREAKING**: `DELETE /organization-users/:userID`, `DELETE /groups/:groupID/members/:userID`, `DELETE /groups/:groupID/roles/:roleID`, and `PATCH /roles/:roleID` can now respond `409`, and a held request for one of these can end `failed`. Their contracts already declare `409`.
- **BREAKING**: `POST` and `PATCH /approval-policies` reject some definitions they accept today, so an organization with one member cannot create a policy that person could be required to approve.

## Non-goals

- Invitation email. Invitation tokens remain returned to the caller.
- Splitting administrator duties or a configurable administrator permission set.
- A retention window or permanent purge for deleted organizations.
- Restoring anything other than organizations.
- An API to read restoration evidence, or an organization-wide audit log.
- Privilege-escalation guards.
- Re-checking policies when access is granted. A requester who later gains a gated permission while being the only approver can withdraw, or be resolved by override.
- Any new tenant-facing restore. A deleted organization has no members who can reach it.

## SOX / SOC Impact

- **Access control**: an organization keeps at least one accountable administrator. New read routes expose only the caller's own access and the code-defined catalog.
- **Segregation of duties**: a policy cannot depend on a requester approving their own change. A one-person organization cannot create a policy it would be unable to satisfy, rather than appearing to have a control it cannot run.
- **Audit trail**: restoring clears `deleted_at` and `deleted_by`, so each restore first copies them to an append-only row with the restoring administrator and reason. The restore is also logged.
- **Platform boundary**: restoring grants the platform administrator no tenant access.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `organization-rbac`: administrator continuity, caller access, catalog discovery, and route permissions.
- `approval-workflows`: policy satisfiability.
- `platform-administration`: finding and restoring deleted organizations.
- `list-endpoints`: declares `GET /permissions`.

## Impact

- **Code**: `ProposedChange.check`, `PolicyRules`, `MeController`, `RoleController`, `PlatformController`, `PlatformOrganizationDTO`, `ListQuery`.
- **Schema**: new `organization_restorations` table with an append-only trigger.
- **API**: three new operations, taking the contract from 54 to 57; `deletedAt` and `deletedById` added to platform organization items.
- **Clients**: `open-erp-ui` depends on this change for tenant administration.
