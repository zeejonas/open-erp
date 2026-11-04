## ADDED Requirements

### Requirement: Policy satisfiability
Saving a policy SHALL respond `400 Bad Request` naming the stage when active group members cannot complete a stage under the one-slot-per-approver rule, or when they could not complete it without a member who could make the request. A member could make the request when they hold the policy's permission or, for a policy on `group_member:create`, also `organization_invitation:create`. Removing a member or group member SHALL respond `409 Conflict` when it would take an active policy from satisfiable to unsatisfiable. These rules SHALL run when a change is submitted and again when it is applied. They SHALL NOT be re-evaluated when access is granted, and they SHALL NOT apply to tracks already pending under an earlier policy version.

#### Scenario: Sole approver could make the request
- **WHEN** a policy on `company:update` needs 1 approval from a group whose only member holds `company:update`
- **THEN** the system responds `400` and no policy is created

#### Scenario: One-person organization
- **WHEN** the only member of an organization creates a policy with themselves as the approver
- **THEN** the system responds `400`

#### Scenario: Approver cannot make the request
- **WHEN** a policy on `company:update` needs 1 approval from a group whose only member lacks `company:update`
- **THEN** the policy is created

#### Scenario: Two approvers who can both make the request
- **WHEN** a policy needs 1 approval from a group of two members who both hold the permission
- **THEN** the policy is created

#### Scenario: One person cannot fill two slots
- **WHEN** a stage needs 1 from "Security" and 1 from "IT", and one person is the only member of both
- **THEN** the system responds `400` naming the stage

#### Scenario: Removal breaks a policy
- **WHEN** removing a member from a group would leave an active policy's stage unable to complete
- **THEN** the system responds `409` and the member remains

#### Scenario: Removing the member from the organization
- **WHEN** removing a member from the organization would leave an active policy's stage unable to complete
- **THEN** the system responds `409` and the membership remains

#### Scenario: Policy already unsatisfiable
- **WHEN** an active policy is already unsatisfiable and a member is removed
- **THEN** this rule does not refuse the removal

#### Scenario: Group from another organization
- **WHEN** a slot names a group belonging to another organization
- **THEN** the system responds `400` and members of that group are not counted

#### Scenario: Held policy no longer satisfiable
- **WHEN** a held policy is approved after its approvers were removed
- **THEN** the request is `failed` with its reason and no policy is created
