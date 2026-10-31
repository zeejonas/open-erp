## 1. Shared document

- [x] 1.1 Extract `apiDocument(_:)` and a single API-version declaration; `/openapi.json` uses it with unchanged output (existing APIDocumentationTests pass).

## 2. Offline export

- [x] 2.1 Split `configure` into `configureAPI` and `configureServices`, with `configure` calling both; existing tests and operational commands are unchanged.
- [x] 2.2 Add the `export-openapi <path>` AsyncCommand with sorted, atomic JSON output; test byte equality across two exports, equality with the HTTP document, and failure on a missing or unwritable path.
- [x] 2.3 Select `configureAPI` alone in the entrypoint for `export-openapi`; demonstrate export with no OIDC/database variables and confirm `serve` still fails without OIDC configuration.

## 3. Documentation

- [x] 3.1 Replace the README note that no generated spec is needed with local export instructions; run strict OpenSpec validation.
