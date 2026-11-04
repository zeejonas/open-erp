## Why

A member eligible to decide an approval request can open it, but has no way to find it. `GET /approval-requests` requires `approval_request:read` and cannot filter by eligibility, while working it out on the client needs group membership data the member may not be able to read. Any API client that presents work to an approver has this problem.

## What Changes

- Add `GET /approval-requests/awaiting-me`, listing the pending requests the caller can approve right now in the selected organization.
- Authorize it by active membership alone. Results are limited to requests the caller may already view as an eligible approver.
- Reuse the eligibility rule that `POST /approval-requests/:id/approve` enforces, so the list and the action cannot disagree.

### Non-goals

- Exposing effective permissions or group memberships on `/me`.
- Resolving user IDs to names in approval responses.
- Notifications or counts outside this list.
- Changing who may approve, reject, withdraw, or view a request.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `approval-workflows`: Members can list the pending requests awaiting their approval.
- `organization-rbac`: The route permissions table lists the new route as requiring active membership and no permission.

## Impact

Approval controller and service, a list test suite, and route-local OpenAPI annotations. No migration or new package.

SOX/SOC: access control is unchanged in substance, since each listed request is already viewable by that member. Segregation of duties holds because requesters and members who have already approved a track are excluded. The route only reads, so it writes no audit records and changes no decision evidence.
