## ADDED Requirements

### Requirement: Members are people
`GET /users`, `GET /users/:userID`, and their totals SHALL include only people. `DELETE /organization-users/:userID` SHALL respond `404 Not Found` for a service account, whose membership ends only by deleting the service account. Group member listings SHALL include service accounts and SHALL state each member's kind, `person` or `service`.

#### Scenario: Member list excludes integrations
- **WHEN** an organization has 3 people and 2 service accounts and a member calls `GET /users`
- **THEN** the response holds the 3 people with `total` 3

#### Scenario: Membership removal refused
- **WHEN** a member calls `DELETE /organization-users/:userID` with a service account's ID
- **THEN** the system responds `404` and the account keeps its membership

#### Scenario: Group members show kind
- **WHEN** a service account belongs to "AP Clerks" and a member calls `GET /groups/:groupID/members`
- **THEN** the account appears with kind `service`
