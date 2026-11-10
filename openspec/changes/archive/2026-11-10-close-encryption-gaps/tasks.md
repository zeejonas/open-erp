## 1. HSTS

- [x] 1.1 Parse `HSTS_MAX_AGE_SECONDS` (non-negative integer, default 31536000 outside testing, header off in testing unless set). Test that the invalid value `-1` fails startup, naming the variable.
- [x] 1.2 Add `HSTSMiddleware` at `.beginning` in `configureAPI`. Test that the header is present on a 200 and on 401 and 404 problem responses, and absent when the value is 0.

## 2. In-process HTTPS

- [x] 2.1 Read `HTTP_TLS_CERT_FILE` and `HTTP_TLS_KEY_FILE` only when serving. Set `tlsConfiguration` when both are present, and declare `NIOSSL` in `Package.swift` if needed.
- [x] 2.2 Test that only one file set, or an unreadable PEM, fails startup naming the variable without file contents
- [x] 2.3 Test with a generated self-signed fixture that `GET /health` succeeds over HTTPS and plain HTTP is refused

## 3. OIDC transport

- [x] 3.1 Validate the `https` scheme for the JWKS and userinfo URLs outside testing. Parse `OIDC_ALLOW_INSECURE_HTTP` strictly and log a warning naming the insecure variables. Test the refused, opt-out and invalid-flag cases.
- [x] 3.2 Test that a JWKS host with a certificate that doesn't match its hostname loads no keys (reuse the local TLS fixture pattern from `WebhookTransportTests`)
- [x] 3.3 Test that `migrate` and `platform-admin` still start without OIDC variables

## 4. Documentation

- [x] 4.1 Add a README "Encryption" section: a hop table, a storage-layer table, the RDS `StorageEncrypted` requirement and AWS check, the snapshot-copy route for existing instances, the KEK in a secret manager, and the local Compose warning
- [x] 4.2 Document the new variables in the README environment table, including the HSTS lowering caveat and certificate rotation by rolling restart
