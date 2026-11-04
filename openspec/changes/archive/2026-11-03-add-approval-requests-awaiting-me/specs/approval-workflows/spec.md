## ADDED Requirements

### Requirement: Requests awaiting the caller
The system SHALL expose `GET /approval-requests/awaiting-me` to any active member of the organization selected by `X-Organization-ID`, without requiring `approval_request:read`. It SHALL return only pending requests in that organization where the caller is eligible to approve at least one pending track, using the same rule as approving: the caller is not the requester, belongs through an active group membership to a group named by a slot of the track's current stage, and has not already approved in that track. Group membership SHALL be evaluated at request time. It SHALL use the standard paged envelope, accept only `page` and `per`, order by request `updatedAt`, and return the same item shape as `GET /approval-requests`.

#### Scenario: Eligible approver without read permission
- **WHEN** a member without `approval_request:read` belongs to a group named by the current stage of a pending request
- **THEN** the request is listed, and `metadata.total` counts it

#### Scenario: Later stage
- **WHEN** a member belongs only to a group named by stage 2 of a request whose track is at stage 1
- **THEN** the request is not listed until the track reaches stage 2

#### Scenario: Requester excluded
- **WHEN** a member made a request and also belongs to a group named by its current stage
- **THEN** the request is not listed for them

#### Scenario: Already approved
- **WHEN** a member has approved in the only track they are eligible for and the stage is still incomplete
- **THEN** the request is not listed for them

#### Scenario: Eligible in one of several tracks
- **WHEN** a member has approved in one pending track and remains eligible in another pending track of the same request
- **THEN** the request is listed once

#### Scenario: Ended request
- **WHEN** a request is applied, rejected, withdrawn, or failed
- **THEN** it is not listed for any member

#### Scenario: Group membership removed
- **WHEN** a member loses the group membership that made them eligible
- **THEN** their next call does not list the request

#### Scenario: Paging and strict parameters
- **WHEN** a member with 30 awaiting requests calls `GET /approval-requests/awaiting-me?page=2&per=10`
- **THEN** the response holds requests 11 through 20 in list order with `total` 30, and a call with `status=pending` responds `400 Bad Request`

#### Scenario: Another organization
- **WHEN** a member of organizations A and B is eligible only on a request in A and selects B
- **THEN** the request is not listed

#### Scenario: Not a member
- **WHEN** a caller with no active membership in the selected organization calls the route
- **THEN** the system responds `403 Forbidden` without listing any request

#### Scenario: Missing credentials or organization
- **WHEN** a caller supplies no bearer token, or supplies one without `X-Organization-ID`
- **THEN** the system responds as other organization routes do, with `401 Unauthorized` or `400 Bad Request` respectively
