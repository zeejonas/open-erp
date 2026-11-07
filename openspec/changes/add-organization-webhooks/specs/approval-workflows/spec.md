## MODIFIED Requirements

### Requirement: Approval catalog
The system SHALL define in code which permissions can require approval and which fields each exposes. Every `create`, `update`, and `delete` permission in the catalog SHALL be gateable except `approval_override:create`. `webhook_subscription:disable` SHALL NOT be gateable. Gateability SHALL be selected explicitly by supported mutation operations, not inferred from a permission merely lacking the `:read` suffix. Each gateable `update` permission SHALL list every field its endpoint can change, by API name:

| Permission | Fields |
|---|---|
| `organization:update` | `code`, `name` |
| `company:update` | `code`, `name` |
| `role:update` | `name`, `permissions` |
| `group:update` | `name` |
| `approval_policy:update` | `name`, `fields`, `companyId`, `stages` |
| `webhook_subscription:update` | `name`, `url`, `eventTypes`, `companyIds`, `enabled`, `rotateSecret` |

`GET /approval-catalog` SHALL return every gateable permission, its fields, and whether it supports company scope. Company scope SHALL be supported exactly for `company:update`, `company:delete`, `group:update`, `group:delete`, `group_member:create`, `group_member:delete`, `group_role:create`, `group_role:delete`, `group_company:create`, and `group_company:delete`.

#### Scenario: Read catalog
- **WHEN** a member with `approval_policy:read` calls `GET /approval-catalog`
- **THEN** the response lists `role:update` with fields `name` and `permissions`, and does not list `approval_override:create` or any `:read` permission

#### Scenario: Catalog requires permission
- **WHEN** a member without `approval_policy:read` calls `GET /approval-catalog`
- **THEN** the system responds `403 Forbidden`

#### Scenario: Integration changes are gateable
- **WHEN** an authorized member reads the approval catalog
- **THEN** it includes subscription create/update/delete, lists all subscription update fields, declares no company scope for these permissions, and excludes emergency disable

## ADDED Requirements

### Requirement: Webhook approval operations
Subscription create/update/delete SHALL enter the existing ProposedChange approval workflow, preserve API outcome contracts, and recheck tenant ownership, requester authority, source-read/payload grants where required, revision preconditions and current outbound authority at application. A held operation SHALL not generate secrets, export business data or mutate the active configuration. Existing approver eligibility, requester separation, concurrent final-approval protection and attributed master/operator override rules SHALL apply. Emergency disable, automatic pause and secret disclosure SHALL never create held requests. An override SHALL remain visible as a distinct recorded action and SHALL not bypass destination safety, tenant isolation or revision preconditions.

#### Scenario: Two final approvals
- **WHEN** two approvers concurrently finish a held subscription activation
- **THEN** exactly one configuration revision is applied

#### Scenario: Activation loses authority
- **WHEN** a held enablement loses its requester's payload/source grant before final approval
- **THEN** it ends failed with the decision retained and the subscription remains disabled

#### Scenario: Cross-tenant held reference
- **WHEN** a proposed webhook mutation contains a subscription from another organization
- **THEN** submission is rejected without disclosing its payload and nothing can be applied in that tenant
