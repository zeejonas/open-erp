## Context

`registerAPIDocumentation` builds the document inside the `/openapi.json` handler with version 0.1.0. Route annotations and DTOs are the contract source. `configure` sets up Postgres, registers migrations and commands, then `configureAuthentication` requires OIDC variables and fetches JWKS outside testing. Fluent connects lazily, so OIDC setup is the only step that needs configuration and network access. `Application.execute()` boots the app before running any command, so a lifecycle hook cannot defer that work for one command.

## Goals / Non-Goals

**Goals:** One document builder for HTTP and command output; deterministic offline export; no weakening of serving startup checks.

**Non-Goals:** CI/release publication, compatibility gating, versioning policy, generated clients, duplicate route annotations, a second executable or library target.

## Decisions

1. **One builder and version source.** Extract the current `app.routes.openAPI(info:)` call into `apiDocument(_ app:)`, used by `/openapi.json` and the command. Keep the API version in one declaration. [VaporToOpenAPI](https://github.com/dankinsoid/VaporToOpenAPI).
2. **Split configure by dependency.** `configureAPI(app)` registers routes and the export command; it touches no database, environment secrets or network. `configureServices(app)` holds the database, migrations, authentication and operational commands. `configure(app)` calls both, so tests and serving are unchanged.
3. **Entrypoint selects the export path explicitly.** After `Environment.detect` and `LoggingSystem.bootstrap(from:)` consume `--env`/`--log`, the entrypoint calls only `configureAPI` when `env.commandInput.arguments.first == "export-openapi"`, and `configure` otherwise. This is one named comparison, not a general bypass; every other command, including `serve`, still fails without OIDC configuration. [Vapor environment](https://docs.vapor.codes/basics/environment/), [Vapor commands](https://docs.vapor.codes/advanced/commands/).
4. **AsyncCommand with deterministic output.** `export-openapi <path>` encodes with `JSONEncoder` using sorted keys and pretty printing, and writes with `Data.WritingOptions.atomic`. No timestamps, absolute paths or commit data enter the document. Missing path, generation or write failure exits nonzero.

Rejected alternatives:
- `OPENAPI_EXPORT_PATH` in a test: artifact creation should be an explicit build operation.
- Download from a running backend: needs live services and deployment configuration.
- Run export under `--env testing`: changes command semantics and hides missing production configuration.
- A separate library/executable target: structural work for one command.
- Building CI release publication and oasdiff gating now: no released baseline exists yet; deferred.

## Risks / Trade-offs

- [The API path grows dependencies] → `configureAPI` must stay free of services; a test runs the export with no OIDC/database variables.
- [Generator output changes after dependency upgrades] → Package.resolved pins versions; deterministic export makes diffs reviewable.

## Migration Plan

No schema change. Extract the builder without changing the HTTP document, then add the split and command. Rollback removes the command and restores a single `configure`.

## Change Ownership

Owns the document builder, version source, configure split and export command. Feature changes own their route annotations; export includes whatever routes the checked-out revision registers.
