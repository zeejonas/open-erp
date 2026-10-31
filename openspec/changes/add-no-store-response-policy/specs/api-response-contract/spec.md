## ADDED Requirements

### Requirement: Shared non-cacheable response policy
One shared application rule SHALL replace Cache-Control with no-store on every application response, including public documentation, unknown routes, errors, ordinary writes, token-bearing 200 responses and held 202 invitation responses. It SHALL wrap error handling so generated failures receive the same header. Individual handlers SHALL NOT implement competing cache rules.

#### Scenario: All invitation token paths
- **WHEN** provisioning, reissue, immediate ordinary invitation creation or approval-held invitation creation returns a token
- **THEN** every response carries Cache-Control: no-store through the shared policy

#### Scenario: Success and failure paths
- **WHEN** a metadata route, public docs route, unknown route or failed authentication returns a response
- **THEN** it also carries Cache-Control: no-store without a handler-specific assignment
