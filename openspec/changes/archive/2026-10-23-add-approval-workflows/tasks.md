## 1. Schema and models

- [x] 1.1 Add `CreateApprovalPolicy`, `CreateApprovalPolicySlot`, `CreateApprovalPolicyVersion`, `CreateApprovalRequest`, `CreateApprovalRequestTrack`, and `CreateApprovalDecision` migrations, registered after `CreateGroupCompany` and before `CreateOrganizationInvitation`
- [x] 1.2 Add optional `approval_request_id` to `CreateOrganizationInvitation` in place
- [x] 1.3 Add the matching models, with `ApprovalPolicy.query(on:organizationID:)` and `ApprovalRequest.query(on:organizationID:)`
- [x] 1.4 Add a `createAuditTrigger` helper next to `createActiveUniqueIndex`, and use it in the decision, policy version, request, and request track migrations, with `revert` dropping the table and then its function. Use no cascading foreign keys on approval tables
- [x] 1.5 Extend `SchemaTests`: duplicate active policy names, duplicate active slots, and duplicate version numbers are rejected, and the full schema applies and reverts
- [x] 1.6 Test the triggers: updating or deleting a decision or a policy version fails, changing a request's `change` or `requested_by` or deleting a request fails, changing or deleting a track's policy version fails, and a status change that resends unchanged values succeeds

## 2. Permissions and catalog

- [x] 2.1 Add `approval_policy:create|read|update|delete`, `approval_request:read`, and `approval_override:create` to `Permission`
- [x] 2.2 Add the approval catalog in code: gateable permissions, fields per update permission, and company-scope support
- [x] 2.3 Add `GET /approval-catalog` and test its contents and its `403` without `approval_policy:read`
- [x] 2.4 Test that provisioned templates hold the new permissions as specified

## 3. Proposed changes and the immediate path

- [x] 3.1 Add the `ProposedChange` enum with permission, changed fields, company context, `check(on:)`, and `apply(on:actorID:)`, plus `ApprovalOutcome<T>` encoding `.held` as `202`
- [x] 3.2 Add `req.approvals.submit(_:)`, which applies immediately when no policy matches
- [x] 3.3 Move company and organization writes into changes and route their handlers through `submit`, keeping existing tests green
- [x] 3.4 Move role writes into changes, comparing `permissions` as a set, keeping existing tests green
- [x] 3.5 Move group, group member, group role, and group company writes into changes, keeping existing tests green
- [x] 3.6 Move invitation create and revoke, and member removal, into changes, keeping existing tests green

## 4. Approval policies

- [x] 4.1 Add policy DTOs and `ApprovalPolicyController` create, list, show, edit, and delete, with the spec's validation, writing a version on create and edit and replacing slots by soft delete
- [x] 4.2 Route policy create, edit, and delete through `submit` as `approval_policy:*` changes
- [x] 4.3 Add `GET /approval-policies/:id/versions`, plus the list filters and order from the list-endpoints spec
- [x] 4.4 Block deleting a group used by an active policy slot, or a company an active policy is scoped to, with `409`
- [x] 4.5 Test policy validation (unknown field, fields on a non-update, company on an unscoped permission, foreign group, slot larger than its group), duplicate names, versions, isolation, the `groupId` filter, and the delete guards

## 5. Matching and holding

- [x] 5.1 Implement matching on permission, changed fields, and company context, and create the request with one track per policy at its current version
- [x] 5.2 Test pass-through with no policies, a held write, an unlisted field, an unchanged value, several matching policies, company routing, a group eligible at several companies, `403` before matching, and `400` before holding
- [x] 5.3 Test that editing a policy covered by `approval_policy:update` is held under its current version

## 6. Decisions and apply

- [x] 6.1 Add `ApprovalRequestController` list and show, with the requester and current eligible approvers allowed to show without `approval_request:read`
- [x] 6.2 Add approve: lock the request, check eligibility at decision time, record a decision per eligible track, complete stages by slot assignment, and advance tracks
- [x] 6.3 Apply on the last track's approval in the same transaction, attributed to the requester, and record `failed` with a reason in a second transaction when `check` or `apply` aborts
- [x] 6.4 Add reject with a required comment, and withdraw for the requester only, with `409` on closed requests
- [x] 6.5 Test requester exclusion, parallel slots, one person in two slots, best slot assignment, sequential stages, counting in several tracks, a removed approver, and isolation
- [x] 6.6 Test apply attribution, a stale value, a lost permission, uniqueness at apply, and concurrent final approvals applying once
- [x] 6.7 Test reject, reject without a comment, withdraw, withdrawing someone else's request, and deciding a closed request
- [x] 6.8 Test that a request still shows its policy version and decisions after the policy is edited and deleted

## 7. Override

- [x] 7.1 Add `POST /approval-requests/:id/override` with a required reason, blocking self-override
- [x] 7.2 Add the `approval-override` CLI command, recording the operator name and logging the decision
- [x] 7.3 Test override, self-override, override without the permission or a reason, and the CLI on pending and closed requests

## 8. Held invitations

- [x] 8.1 Create held invitations with `approval_request_id` and return the token in the `202` body. Reject acceptance until the request is applied, restart expiry on apply, match invitations into a group against `group_member:create` policies, and revoke on rejection, withdrawal, or failure
- [x] 8.2 Test acceptance before and after approval (including past the original expiry), acceptance after rejection, and an invitation into a gated group being held

## 9. Finish

- [x] 9.1 Add every approval route to the route-permission sweep
- [x] 9.2 Run `swift build` and `swift test`, and confirm `openspec validate add-approval-workflows` passes
