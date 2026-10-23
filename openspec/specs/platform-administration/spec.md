# platform-administration

## Purpose

Platform administrator bootstrap and organization provisioning, without implicit access to any tenant.

## Requirements

### Requirement: Platform administrator flag
The system SHALL store a non-null `is_platform_admin` boolean on users, defaulting to false. No HTTP endpoint SHALL be able to set or clear it.

#### Scenario: Flag not settable via API
- **WHEN** a user calls `PATCH /me` with `isPlatformAdmin: true`
- **THEN** the flag is unchanged

### Requirement: Platform administrator CLI
The system SHALL provide a `platform-admin` CLI command that, given an email, first name, last name, and OIDC subject, creates or updates the user, binds `auth_subject`, and sets `is_platform_admin` to true. With `--revoke`, it SHALL set the flag to false. The command SHALL log each grant and revocation.

#### Scenario: Bootstrap first platform admin
- **WHEN** an operator runs `platform-admin` with an email and subject not yet in the system
- **THEN** a user is created with that email, bound to that subject, and flagged as platform admin

#### Scenario: Revoke
- **WHEN** an operator runs `platform-admin --revoke` for an existing platform admin
- **THEN** the user's flag is set to false and their next provisioning request responds `403 Forbidden`

#### Scenario: Subject conflict
- **WHEN** the email exists bound to a different subject
- **THEN** the command fails without changes

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

### Requirement: No implicit tenant access
The platform administrator flag SHALL NOT grant membership, permissions, or data access in any organization. Organization-scoped routes SHALL treat platform administrators like any other user.

#### Scenario: Platform admin without membership
- **WHEN** a platform admin who is not a member calls `GET /companies` for an organization
- **THEN** the system responds `403 Forbidden`
