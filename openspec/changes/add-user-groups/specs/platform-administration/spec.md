## MODIFIED Requirements

### Requirement: Organization provisioning
The system SHALL expose `POST /platform/organizations`, available only to authenticated platform administrators, which in one transaction creates the organization, copies all role templates and group templates into it, and creates an invitation for the first administrator into the "Organization Administrators" group. The response SHALL include the organization and the invitation token.

#### Scenario: Provision organization
- **WHEN** a platform admin provisions "Acme LLC" with first admin `cfo@acme.com`
- **THEN** the organization, its template roles and groups, and an invitation for `cfo@acme.com` into the Organization Administrators group exist, and the token is returned

#### Scenario: First administrator holds every organization permission
- **WHEN** `cfo@acme.com` accepts the provisioning invitation
- **THEN** they belong to Organization Administrators and hold every organization-level permission

#### Scenario: Non-admin provisioning
- **WHEN** a user without the flag calls `POST /platform/organizations`
- **THEN** the system responds `403 Forbidden` and nothing is created

#### Scenario: Provisioning failure is atomic
- **WHEN** any step of provisioning fails
- **THEN** no organization, role, group, or invitation is persisted
