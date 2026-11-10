## Why

The connection to Postgres is TLS-verified and fails closed, and webhook signing secrets are encrypted in the application. Three gaps remain:
- The API serves plain HTTP and sends no HSTS, so a browser client can be downgraded.
- The hop from the load balancer to the app is plaintext unless the deployment adds something.
- The OIDC JWKS and userinfo URLs accept `http`, so a misconfiguration would let a network attacker supply signing keys.

Encryption at rest is entirely a deployment property that nothing documents or requires. SOC 2 CC6.1 and CC6.7 expect each of these to be a stated, evidenced control.

## What Changes

- Send `Strict-Transport-Security` on every response outside the testing environment. The max-age can be configured, and 0 turns it off.
- Optionally serve HTTPS in-process from a configured certificate and key, so the load balancer → app hop can be encrypted. Plain HTTP stays the default.
- Require `https` for `OIDC_JWKS_URL` and `OIDC_USERINFO_URL` outside testing. An explicit opt-out allows `http` and logs a warning, following the same pattern as `DATABASE_TLS_MODE=disable`.
- Add a README "Encryption" section covering each hop and each storage layer. Make storage encryption at rest a deployment requirement: RDS `StorageEncrypted` with a KMS key, snapshots and backups, and how to encrypt an existing unencrypted instance. Say plainly that local Compose is unencrypted and must never hold real data.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `service-runtime`: HSTS header, optional in-process HTTPS, and a documented encryption posture
- `authentication`: HTTPS required for identity provider key and userinfo URLs outside testing

## Impact

- New `HSTSMiddleware` registered next to `NoStoreMiddleware`. TLS server configuration and OIDC URL validation at startup. README.
- New environment variables: `HSTS_MAX_AGE_SECONDS`, `HTTP_TLS_CERT_FILE`, `HTTP_TLS_KEY_FILE`, `OIDC_ALLOW_INSECURE_HTTP`.
- **BREAKING (deployment configuration):** a non-testing deployment whose OIDC URLs use `http` will now fail to start until it switches to `https` or sets the opt-out.
- Dependencies: NIOSSL is already used through the Postgres driver. It may need to be declared directly in `Package.swift`.
- SOX/SOC: strengthens the transmission control (CC6.7) and the integrity of token verification, since keys can no longer be fetched over an unauthenticated channel. Makes encryption at rest an explicit, auditable deployment requirement (CC6.1). No change to access control, audit trail or segregation of duties.

## Non-goals

- Field-level encryption of personal data or business records, and encrypting stored webhook payloads
- Rotating or re-wrapping the webhook key-encryption key
- Postgres TLS in local Compose
- Detecting storage encryption from inside the application. Postgres can't report it.
- mTLS between the load balancer and the app, and certificate rotation without a restart
