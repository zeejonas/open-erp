# api-contract-publication

## Purpose

One route-derived OpenAPI document, served over HTTP and exported offline for client generation.

## Requirements

### Requirement: Single route-derived API document
The system SHALL use one document builder and one API-version source for GET /openapi.json and the export command. Registered route annotations and DTO schemas SHALL remain the source of operation contracts. Documentation endpoints SHALL remain excluded from the document.

#### Scenario: HTTP and command agree
- **WHEN** a document is generated over HTTP and by command from the same revision
- **THEN** both contain identical operations, components, security and API-version metadata

#### Scenario: Feature contract is preserved
- **WHEN** an operation declares bearer security, a required tenant header or a no-tenant platform contract
- **THEN** the export preserves those annotations and every local schema reference resolves

### Requirement: Offline native OpenAPI export
The application SHALL provide export-openapi with a required destination path, using the native Vapor command API. It SHALL generate from the real registered routes without a listening server, database, OIDC configuration or reachable external services. It SHALL atomically write deterministic JSON free of timestamps and machine-specific data. Missing arguments, generation failure and write failure SHALL produce an unsuccessful exit status. Tests SHALL NOT create export artifacts as a side effect of an environment variable.

#### Scenario: Export without runtime services
- **WHEN** export-openapi runs with an output path and no OIDC or database configuration
- **THEN** it exits successfully and writes the route-derived document without contacting those services

#### Scenario: Deterministic export
- **WHEN** the same revision exports twice to separate destinations
- **THEN** both files are byte-identical

#### Scenario: Failed destination
- **WHEN** the destination cannot be written or the path argument is absent
- **THEN** the command exits unsuccessfully and leaves no partial file

#### Scenario: Serving checks unchanged
- **WHEN** the server starts outside testing without required OIDC configuration
- **THEN** startup still fails under the existing authentication requirements
