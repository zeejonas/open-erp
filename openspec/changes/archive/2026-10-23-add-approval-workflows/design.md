## Context

Every create, update, and delete handler checks `req.require(_:)` and then writes directly in the controller. Access comes only through groups, `loadPermissions` in `OrganizationMiddleware` resolves permissions on every request, and every table carries audit attribution and soft deletes. Earlier designs accepted self-escalation through role and group permissions and deferred approvals. Invitations return a one-time token in the create response and store only its hash. The project is pre-release, so create migrations are edited in place.

## Goals / Non-Goals

**Goals:**
- One code path per write, whether it applies immediately or after approval.
- Any number of stages, parallel slots, and matching policies, with no precedence rules.
- Evidence that survives policy edits: the exact policy version, the before and after values, and every decision.
- No behavior change for an organization without policies.

**Non-Goals:**
- Value conditions, time-based escalation, expiry, notifications, approval inboxes, approvals on global user identity, and policy templates.

## Decisions

### 1. Writes become proposed changes, not replayed requests
A `ProposedChange` enum has one case per gateable permission (for example `.companyUpdate(id, before, after)`). Each case provides:
- its permission,
- the fields it changes (only fields whose value differs),
- its company context,
- `check(on:)`, which runs today's reference, uniqueness, and delete-rule checks plus the staleness check, and
- `apply(on:actorID:)`, which performs the write.

Handlers keep their permission check and DTO validation (https://docs.vapor.codes/basics/validation/), build the change, and call `req.approvals.submit(change)`. The write logic moves out of the controllers into `apply`, so the immediate path and the approved path share one implementation. The enum is `Codable` and is stored on the request as JSON. Fluent stores any `Codable` value in a `@Field` (https://docs.vapor.codes/fluent/model/#field), and an exhaustive switch makes the compiler flag any permission without a case.

*Rejected:* middleware that stores and replays the HTTP request (it can't see which fields change, it runs validation at replay time, and approvers sign off on a raw body instead of a diff); draft rows in each entity table (every model and uniqueness index has to ignore drafts).

### 2. Gated responses are `202` through one outcome type
`submit` returns `ApprovalOutcome<T>`, either `.applied(T)` or `.held(GetApprovalRequestDTO)`. It conforms to `AsyncResponseEncodable` (https://api.vapor.codes/vapor/documentation/vapor/asyncresponseencodable) and encodes `.held` with status `202 Accepted`. Handlers that return `HTTPStatus` today return `ApprovalOutcome<HTTPStatus>`.

*Rejected:* throwing a custom error for the held case (a held change is a success, and the error middleware would own response bodies).

### 3. Schema: normalized current policies, immutable JSON versions
```
approval_policies          organization_id, name, permission, fields text[], company_id?,
                           current_version, created_by, updated_by, deleted_by, timestamps
                           active-unique(organization_id, name)
approval_policy_slots      policy_id, stage, group_id, required, created_by, deleted_by, created_at, deleted_at
                           active-unique(policy_id, stage, group_id)
approval_policy_versions   policy_id, version, definition json, created_by, created_at
                           unique(policy_id, version); no update, no delete
approval_requests          organization_id, permission, target_id?, change json, status,
                           failure_reason?, requested_by, created_at, updated_at
approval_request_tracks    request_id, policy_version_id, current_stage, status, created_at, updated_at
approval_decisions         request_id, track_id?, stage?, kind, decided_by?, operator?,
                           qualifying_group_ids uuid[], comment?, created_at; no update, no delete
organization_invitations   + approval_request_id?
```
Slots are normalized so that `GET /approval-policies?groupId=` and the "group used by a policy" delete guard are plain joins (https://docs.vapor.codes/fluent/query/#join). An edit soft-deletes the old slots with `deleted_by` and inserts new ones in the same transaction (https://docs.vapor.codes/fluent/transaction/). A version's `definition` is the same `Codable` struct the policy endpoints accept. A request track references the version, never the live policy. Arrays use the schema builder's `.array(of:)` (https://docs.vapor.codes/fluent/schema/).

Optional columns are optional only where the value can be absent: an unscoped policy, a create with no target yet, an override with no track, and a CLI decision with no user.

*Rejected:* fully normalized versions (three more tables with no query that needs them); JSON-only policies (group references can't be queried); copying the policy into each request (the same snapshot duplicated for every request).

### 4. Matching is a pure function
`submit` loads the organization's active policies for the change's gating permissions, eager-loading slots (https://docs.vapor.codes/fluent/relations/#eager-loading). A policy matches when its permission is equal, when its fields are empty or overlap the change's changed fields, and when its company is unset or in the change's company context. Set-valued fields such as `permissions` compare as sets. A change's gating permissions are its own permission, plus `group_member:create` for an invitation into a group, because accepting that invitation adds a group member and would otherwise bypass membership policies. No match calls `apply` with the requester as actor. One or more matches create the request and one track per policy at its `current_version`. Both paths run in one transaction. Writes to `approval_policy:*` take the same path, so the policies in force govern their own changes with no special code.

### 5. Stage completion is a slot assignment, not first come
Each approval records the stage and every slot group that qualified the approver. A stage is complete when the approvers who approved it can be assigned to slots, one slot per approver, filling every slot's required count. The check is a small bipartite matching (augmenting paths over at most tens of approvers), recomputed on each approval. A member eligible in several tracks gets one decision row per track from one call. Eligibility reads the caller's active group memberships at decision time, filtering `deleted_at` on every joined table as `loadPermissions` does.

*Rejected:* assigning a slot when the approval arrives (the order of approvals can leave a stage stuck that a better assignment would complete); asking the approver to choose a slot (pushes the same problem onto users).

### 6. One request changes state at a time
Approve, reject, withdraw, and override lock the request row with `SELECT … FOR UPDATE` inside the transaction, using SQLKit's `for(.update)` (`SQLSubqueryClauseBuilder.for(_:)`), because Fluent's query builder has no locking API. A second final approval waits, sees the request is no longer `pending`, and gets `409`.

*Rejected:* an optimistic version column (concurrent approvers see retry errors for a normal action).

### 7. Apply failures are recorded, not lost
The final decision, `check`, `apply`, and the `applied` status commit together. If `check` or `apply` throws an `Abort` (stale value, `409` uniqueness through `conflictOnDuplicate`, `403` lost permission, `404` missing target), that transaction rolls back. A second transaction then re-locks the request, records the same decision, sets `failed` with the abort reason, and revokes a held invitation. Any other error rolls back without a record and surfaces as `500`, so the approver can retry. The permission re-check reuses `loadPermissions`, which becomes internal, along with an active membership check.

*Rejected:* committing approval first and applying in a later step (a crash in between leaves an approved change that was never applied).

### 8. Overrides share the apply path
`POST /approval-requests/:id/override` requires `approval_override:create`, a reason, and a caller who is not the requester. It records one `override` decision with no track and runs the same apply and failure path. Tracks keep their status, and reports read the decision kind. The `approval-override` CLI is an `AsyncCommand` (https://docs.vapor.codes/advanced/commands/) taking `--request`, `--operator`, and `--reason`. It records `decided_by` as null with the operator name and logs it, like `platform-admin`.

### 9. Held invitations are created, then activated
A held invitation is created at submission with `approval_request_id` set, so the token can be returned once in the `202` body alongside the request. Acceptance responds `409` unless that request is `applied`. Applying checks that the invitation is unaccepted and its group is still active, and restarts its expiry, so approval time does not consume the invitee's window. Rejection, withdrawal, and failure soft-delete the invitation with `deleted_by` set to the decider or requester.

*Rejected:* creating the invitation on approval (the token would go to the approver); storing the token encrypted until the requester fetches it (keeps a secret at rest).

### 10. Routes and permissions
`ApprovalPolicyController` registers `/approval-catalog` and `/approval-policies` (with `/:id/versions`). `ApprovalRequestController` registers `/approval-requests` and `/:id/approve`, `/reject`, `/withdraw`, and `/override`, all using route groups behind `AuthMiddleware` and `OrganizationMiddleware` (https://docs.vapor.codes/basics/routing/#route-groups). Lists use `listParameters` and `paginate` like every other list. New permissions join the catalog, so the existing template filters give "Organization Administrator" every approval permission and "Organization Viewer" the two reads.

### 11. Schema changes follow the pre-release migration policy
New create migrations are registered after `CreateGroupCompany` and before `CreateOrganizationInvitation`, which is edited in place to add `approval_request_id`. Migrations are listed in dependency order (https://docs.vapor.codes/fluent/migration/#register).

### 12. The database enforces append-only evidence
A `BEFORE UPDATE OR DELETE` row trigger (https://www.postgresql.org/docs/current/sql-createtrigger.html) with a PL/pgSQL function (https://www.postgresql.org/docs/current/plpgsql-trigger.html) raises an exception on:
- any `UPDATE` or `DELETE` of `approval_decisions` and `approval_policy_versions`, and
- any `DELETE` of `approval_requests`, or any `UPDATE` where `organization_id`, `permission`, `target_id`, `change`, `requested_by`, or `created_at` is distinct from its old value (`IS DISTINCT FROM`). `status`, `failure_reason`, and `updated_at` stay writable.
- any `DELETE` of `approval_request_tracks`, or any `UPDATE` where `request_id`, `policy_version_id`, or `created_at` changes. `current_stage`, `status`, and `updated_at` stay writable.

The trigger compares values, not which columns were sent, so a write that resends unchanged values succeeds. Each table's create migration creates its own function and trigger through SQLKit's `raw` (https://docs.vapor.codes/fluent/advanced/#sql), and its `revert` drops the table and then the function. This keeps one migration per table, and the SQL lives in one `createAuditTrigger` helper next to `createActiveUniqueIndex`. The trigger holds for every deployment, including ones with a single database login. Every write in decisions 5 through 9 inserts decisions or changes request status, so none is blocked. Dropping a table and `TRUNCATE` don't fire row triggers, so `autoRevert` in tests is unaffected.

Approval tables use no `ON DELETE CASCADE`, so deleting a parent row never reaches a protected row. A later migration that must backfill protected rows runs `ALTER TABLE … DISABLE TRIGGER`, backfills, and runs `ENABLE TRIGGER` within the same migration (https://www.postgresql.org/docs/current/sql-altertable.html), so the bypass is visible in review. Purging a tenant's approval history is an operator procedure that follows the same pattern and is logged.

*Rejected:* application-only enforcement (bugs, a compromised app server, and ad hoc SQL can rewrite evidence); separate migration and runtime database roles (adds a second credential for every deployment; it can be layered on later as deployment hardening); hash chains or write-once log export (protects against database superusers, which no requirement asks for yet).

### 13. Tests
Existing write tests stay unchanged, because no policies exist by default. New tests follow the spec scenarios: no-policy pass-through, held writes, field and company matching, parallel and sequential stages, best slot assignment, multiple tracks, requester exclusion, rejection and withdrawal, staleness, lost permission, concurrent final approvals, override and CLI, held invitations, policy versions, self-governance, isolation, the route-permission sweep, and the triggers rejecting edits while allowing request status changes.

## Risks / Trade-offs

- [Every write handler is refactored] → Behavior moves into `apply` unchanged. The existing suite exercises the immediate path for every route.
- [Clients must handle `202`] → Only after a tenant creates a policy. The held body always names the request ID and status.
- [Approver groups shrink after a policy is saved] → The size check runs only at save. Override and the CLI unstick requests, and policies can be queried by group.
- [An override holder can skip every stage] → A reason is required, self-override is blocked, decisions are recorded as overrides, and granting the permission can itself require approval.
- [A future migration that backfills protected rows fails] → The migration step fails and the running app is unaffected, because migrations run as a separate `migrate` command. Backfills follow the disable, backfill, enable pattern in one migration.
- [The table owner or a superuser can disable the triggers] → That takes a schema change, not a stray `UPDATE`. Separate roles and tamper evidence remain later options.
- [Raw SQL in four migrations] → Kept in one helper next to `createActiveUniqueIndex`, because the schema builder has no API for triggers.
- [The stored `change` JSON shape is a contract once released] → Pre-release it can change freely. After release, new shapes need decoding for old pending requests.
- [Held requests never expire] → Requesters withdraw them. Expiry needs a scheduler and is a non-goal.

## Migration Plan

Pre-production; no tenant data to preserve. Reset the local database and run migrations. Organizations start with no policies, so behavior is unchanged until a tenant adds one. Rollback: redeploy the previous build and reset the local database.

## Open Questions

- Should the database also enforce append-only decisions and versions?
Answer: Yes, with row triggers on the approval audit tables (decision 12). Separate database roles are left for deployment hardening.
