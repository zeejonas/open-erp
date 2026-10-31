## Why

Teams building their own UI on this backend need the API contract as a file they can generate clients from, without running a database, contacting an identity provider, or extracting output from a test. The existing `/openapi.json` generator can also serve a native Vapor export command.

## What Changes

- Extract the `/openapi.json` document into one shared builder and API-version source.
- Add `export-openapi <path>` using Vapor's command API and that builder.
- Split `configure` into service setup (database, OIDC, migrations, operational commands) and API setup (routes, export command), so export runs without runtime services while serving keeps every configuration check.

## Capabilities

### New Capabilities

- `api-contract-publication`: Shared document generation and offline export.

### Modified Capabilities

None. Runtime authentication and route annotations are unchanged.

## Impact

`APIDocumentation.swift`, `configure.swift`, `entrypoint.swift`, one command, command tests and README export instructions. Reuses VaporToOpenAPI, Vapor AsyncCommand and Foundation. No migration, CI workflow or new package. SOX/SOC: the exported contract contains no credentials or tenant data.

## Non-goals

CI artifact upload, release asset publication, semantic breaking-change gating (for example oasdiff), API versioning policy and generated clients. These are deferred until the first production release, when a released baseline exists to compare against.
