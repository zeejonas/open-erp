## ADDED Requirements

### Requirement: Service account attribution
Writes made by an authenticated service account SHALL use actor type `service_account` with the account's ID as actor ID, and `created_by`, `updated_by`, and `deleted_by` SHALL record that ID. Writes applied by a person's approval of a request a service account submitted SHALL be attributed to the approving person and SHALL link the approval request, whose requester is the service account. Changes to a service account's own records SHALL be attributed to the actor who made them.

#### Scenario: Direct write by an integration
- **WHEN** a service account with `company:create` creates a company
- **THEN** the audit event records actor type `service_account` and the account's ID, and the company's `created_by` is the account

#### Scenario: Held write approved by a person
- **WHEN** a service account's company update is held and a person's approval applies it
- **THEN** the company event records the person as actor and links the approval request, whose requester is the service account

#### Scenario: Lifecycle attributed to the administrator
- **WHEN** a person disables a service account
- **THEN** the event records that person as actor with actor type `user`
