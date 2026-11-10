# business-events Specification

## Purpose
Define the public catalog of business events, how they are captured atomically with the changes they describe, and how organizations inspect their event history.

## Requirements
### Requirement: Public business event catalog
The system SHALL define a code-owned catalog of public event types at schema version 1. Each entry SHALL declare its resource type, source-read permission, supported company filtering, and summary schema. The initial catalog SHALL be:

| Events | Resource type | Required source read | Summary data |
|---|---|---|---|
| `organization.created`, `organization.updated`, `organization.deleted`, `organization.restored` | `organization` | `organization:read` | `code`, `name`, `deleted` |
| `company.created`, `company.updated`, `company.deleted` | `company` | `company:read` | `code`, `name`, `deleted` |
| `role.created`, `role.updated`, `role.deleted` | `role` | `role:read` | `name`, `level`, `deleted` |
| `group.created`, `group.updated`, `group.deleted` | `group` | `group:read` | `name`, `deleted` |
| `group_member.created`, `group_member.deleted` | `group_member` | `group_member:read` | `groupId`, `userId` |
| `group_role.created`, `group_role.deleted` | `group_role` | `group:read` | `groupId`, `roleId` |
| `group_company.created`, `group_company.deleted` | `group_company` | `group:read` | `groupId`, `companyId` |
| `organization_user.created`, `organization_user.deleted` | `organization_user` | `organization_user:read` | `userId` |
| `organization_invitation.issued`, `organization_invitation.reissued`, `organization_invitation.accepted`, `organization_invitation.revoked` | `organization_invitation` | `organization_invitation:read` | `groupId`, `status`, `expiresAt` |
| `approval_policy.created`, `approval_policy.updated`, `approval_policy.deleted` | `approval_policy` | `approval_policy:read` | `name`, `permission`, `currentVersion`, `deleted` |
| `approval_request.created`, `approval_request.decision_recorded`, `approval_request.applied`, `approval_request.failed`, `approval_request.rejected`, `approval_request.withdrawn`, `approval_request.overridden` | `approval_request` | `approval_request:read` | `permission`, `targetId`, `status`, nullable `decisionId`, nullable `decisionKind` |

Only company events and group-company relationship events SHALL have a non-null envelope `companyId` in version 1; all other events SHALL have null there, including approval events. Relationship resource IDs SHALL identify the relationship row. Restoring an organization SHALL NOT imply restoration of children. No global user, token, raw audit-table, delivery-internal, or new restore/purge events SHALL be published. `GET /webhook-event-types` SHALL require `webhook_event:read`, follow list-endpoints with no filters or sort parameter, and order its static entries by `type` ascending. Full envelope and summary schemas SHALL be published in OpenAPI, and incompatible changes SHALL use a new schema version.

#### Scenario: Discover supported transitions
- **WHEN** an authorized member lists every page of the event catalog
- **THEN** every event above appears once with schema version, summary schema and source permission, and `company.restored` does not appear

#### Scenario: Catalog access denied
- **WHEN** a member without `webhook_event:read` requests the catalog
- **THEN** the system responds `403`

### Requirement: Atomic semantic event capture
Every committed supported business transition SHALL persist its immutable business event and one dispatch record in the same audited database transaction as the transition. The transaction SHALL NOT read subscriptions or create deliveries; fan-out is defined by webhook-delivery. Capture SHALL cover direct API operations, approval application, provisioning, invitation acceptance/reissue, organization restoration and affected CLI operations. The event SHALL be recorded even with no subscribers. A no-op business update or a change solely to attribution/timestamps SHALL NOT emit an updated event. One logical deletion SHALL emit one deleted event even when it performs multiple audited writes. Internal event, dispatch, subscription, delivery and ledger table changes SHALL NOT recursively produce public business events.

#### Scenario: Rollback removes publication work
- **WHEN** a company update, its audit rows and event have been written and the transaction rolls back
- **THEN** the company is unchanged and none of those rows or its dispatch record commits

#### Scenario: Event insert fails
- **WHEN** a supported business operation cannot persist its event or its dispatch record
- **THEN** the entire operation rolls back

#### Scenario: No subscribers
- **WHEN** a company is created with no eligible subscriptions
- **THEN** its event commits and dispatch creates no deliveries

#### Scenario: Soft deletion is one business event
- **WHEN** a company deletion saves attribution and then soft-deletes the row
- **THEN** the audit records both writes and exactly one `company.deleted` business event is persisted

#### Scenario: CLI applies approved change
- **WHEN** an operator override successfully applies a held company update
- **THEN** the company event commits with operator attribution, the requester ID, and the approval request ID

### Requirement: Approval outcome semantics
The system SHALL emit `approval_request.created` when a held request is persisted and one `approval_request.decision_recorded` per persisted decision row. It SHALL emit applied/rejected/withdrawn/failed events only for the corresponding committed outcome. A persisted override decision SHALL additionally emit `approval_request.overridden`, independent of whether target application succeeds. Target-resource events SHALL exist only if target changes commit. A held invitation SHALL NOT emit issued until approval makes it usable; withdrawing, rejecting or failing a held invitation SHALL NOT fabricate an issued event.

#### Scenario: Held update
- **WHEN** a company update returns `202` pending approval
- **THEN** the request-created event exists and no company-updated event exists

#### Scenario: Final approval succeeds
- **WHEN** the last required decision and company change commit
- **THEN** decision-recorded, company-updated and request-applied events commit with shared approval linkage

#### Scenario: Application fails after decision
- **WHEN** application rolls back and the existing failure path separately persists the decisions and failed status
- **THEN** only those persisted decisions and failed outcome have events, with no target update or applied event

#### Scenario: Held invitation becomes usable
- **WHEN** an invitation token was prepared in a held request and final approval releases the invitation
- **THEN** issued is emitted at release, not token preparation

### Requirement: Immutable envelope and resource revisions
The version 1 envelope SHALL contain `id`, `type`, `schemaVersion`, server `occurredAt`, `organizationId`, nullable `companyId`, `resource` with `type`, `id` and `revision`, `actor` with `type` and nullable `id`, nullable `requestedById`, `requestId` and `approvalRequestId`, `changedFields`, and the catalog's typed `data`. Optional fields SHALL be present as null when unavailable. Resource revisions SHALL increase transactionally for each emitted event on an organization/resource identity, including multiple events in one transaction, and SHALL NOT restart after soft deletion/restoration. Filtered streams SHALL NOT promise contiguous revisions or global ordering. The system SHALL retain exact serialized payload bytes and a digest, reject event update/delete/truncate, and link internal audit evidence by organization and transaction ID.

Payloads SHALL exclude tokens, identity subjects, IP addresses, database usernames, operator names, approval comments, proposed change bodies, invitation names/email, signing secrets and raw exception text. Summaries SHALL NOT automatically expand when model DTOs gain fields.

#### Scenario: Concurrent revisions
- **WHEN** two operations emit events for the same company concurrently
- **THEN** their committed events have distinct increasing revisions, and rollback does not consume a committed revision

#### Scenario: Restore continues the stream
- **WHEN** an organization is deleted and later restored
- **THEN** the restore revision is greater than its delete revision

#### Scenario: Sensitive data excluded
- **WHEN** an invitation or failed approval event is serialized
- **THEN** the body contains only its declared summary and no token, email, comment, proposed payload or raw failure reason

### Requirement: Tenant event history and payload inspection
`GET /webhook-events` and `GET /webhook-events/:id` SHALL require `webhook_event:read` and expose only the selected organization's metadata. The list SHALL follow list-endpoints, ordered by `createdAt` descending and `id` ascending, with exact filters `type`, `resourceType`, `resourceId`, `companyId`, `approvalRequestId`, `requestId`, and inclusive `from`/`to` on `createdAt`, and no sort parameter. Unknown event types/resource types SHALL be rejected. Metadata SHALL omit payload bytes, `data`, dispatch state, transaction IDs and database context. `GET /webhook-events/:id/payload` SHALL additionally require `webhook_payload:read` and return the stored JSON body. Cross-tenant item IDs SHALL return `404`; a cross-tenant ID filter SHALL match an empty page. All routes SHALL require authentication, an active membership, and `X-Organization-ID`.

#### Scenario: Tenant isolation
- **WHEN** an authorized organization A member filters for an organization B resource
- **THEN** the list is empty, its total is zero, and direct access to B's event returns `404`

#### Scenario: Missing metadata permission
- **WHEN** a member without `webhook_event:read` lists events
- **THEN** the system responds `403`

#### Scenario: Metadata does not grant payload access
- **WHEN** a member with event-read but without payload-read requests an event's payload
- **THEN** the system responds `403` and ordinary metadata still omits `data`

### Requirement: Event production coverage
The system SHALL test each catalog business operation through its supported entry points for event production, and SHALL classify every audited mapped business-table transition as either requiring a catalog event or explicitly non-event-bearing. A test SHALL fail when a mapped business table or catalog entry lacks that classification or an emitting-operation test. New catalog entries SHALL require an emitting-operation test and a payload contract. Reconciliation of committed audit history against events is deferred.

#### Scenario: Missing producer detected in tests
- **WHEN** a catalog entry has no test exercising its emitting operation
- **THEN** the coverage test fails and names the event type

#### Scenario: Non-event classification
- **WHEN** a soft-delete attribution save or held invitation preparation is audited
- **THEN** the classification marks it non-event-bearing without requiring a separate update or issued event

