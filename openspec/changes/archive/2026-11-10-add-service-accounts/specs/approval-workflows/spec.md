## ADDED Requirements

### Requirement: Service account approval gating
`service_account:create`, `service_account:update`, and `service_account:delete` SHALL be gateable, and the catalog SHALL list `service_account:update` with fields `name`, `description`, `ownerId`, `subject`, and `enabled`. None SHALL support company scope. `service_account:disable` SHALL NOT be gateable. A held registration SHALL re-check subject uniqueness and owner eligibility when applied, and SHALL end `failed` if either no longer holds. Service accounts SHALL be able to submit and withdraw requests and, through group membership, approve them under the same eligibility rules as people.

#### Scenario: Held registration
- **WHEN** a policy covers `service_account:create` and a member registers a service account
- **THEN** the system responds `202` with a pending request and no account exists until it is approved

#### Scenario: Re-enable held
- **WHEN** a policy covers `service_account:update` field `enabled` and a member re-enables a disabled account
- **THEN** the system responds `202` and the account stays disabled until approved

#### Scenario: Subject taken before apply
- **WHEN** a held registration for subject `abc@clients` is approved after another account bound `abc@clients`
- **THEN** the request ends `failed` and no account is created

#### Scenario: Service account write held
- **WHEN** a policy covers `company:update` and a service account renames a company
- **THEN** the system responds `202` with a request whose requester is the service account, and the service account cannot approve it
