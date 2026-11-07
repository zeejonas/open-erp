These demos use disposable fixtures and do not contact customer endpoints.

`transaction-timestamp-race.py` uses two Postgres connections to show why transaction-start
timestamps cannot establish whether an enablement committed before event capture. Its
output was `timestamp_only_matches=true, revision_visible_when_event_captured=false`.
The dispatcher tests exercise the corrected snapshot rule, same-transaction capture order,
and decreasing configuration timestamps under contention.

`process-demo.py` requires `docker compose build app`. Run it from the repository root:

```sh
python3 openspec/changes/add-organization-webhooks/demos/process-demo.py
```

It creates an internal Docker network with a public-form IPv4 address for the local TLS
receiver so the production destination policy runs unchanged. A separate control network
exposes only loopback ports to the harness. Workers stay on the internal network. The receiver
uses a test CA and an ephemeral OIDC key. The API provisions eight tenants and sixteen
subscriptions through ordinary authenticated routes, retrieves their secrets through the
recorded disclosure endpoint, and creates 256 companies while workers are absent. Each
notification is verified against its subscription's secret using Standard Webhooks HMAC.

The harness confirms API health with workers absent, stops the API, starts independent worker
OS processes without OIDC variables, and waits for 512 acknowledged deliveries. Workers have
the default limits, a one-second receiver delay, and independent connection pools. Migration
and `audit-verify` commands receive neither webhook keys nor OIDC configuration. Every created
container, anonymous volume, and network is removed at the end. The existing Compose app and
database are left running.

Measured on November 7, 2026 with the Swift 6.3 Linux release image:

| Measurement | One process | Two processes |
| --- | ---: | ---: |
| Acknowledged deliveries | 512 | 512 |
| Elapsed seconds, including worker startup/fan-out | 34.87 | 18.28 |
| Deliveries/second | 14.68 | 28.01 |
| Peak receiver in-flight | 16 | 32 |
| Peak in-flight for any subscription | 2 | 4 |
| Tenants reached in first 32 completions | 8 | 8 |
| Median attempt duration, seconds | 1.015 | 1.015 |
| Durable dispatches before starting workers | 344 | 344 |

Throughput increased **1.91×**. [process-results.json](process-results.json) contains the exact
measurements. Both runs completed with the API stopped and zero receiver signature failures.
These are local fixture results, not a production delivery SLO. The workers' sixty-second
summary loop and health median are separately covered by the runtime/history implementation;
short demos finish before the first periodic summary.

Final acceptance checks passed: 151 Swift tests across 12 suites, the Swift 6.3 Linux release
image build, Compose configuration validation, fresh migrations, the required migration-history
grant revocation, `audit-verify`, `git diff --check`, and strict OpenSpec validation. Tests also
execute the summary aggregation/logging path and exercise cancellation while native DNS is
blocked, hostname verification, redirect refusal, secret disclosure failure, approval races,
lease recovery, tenant isolation, queue attention flags, and operator shutdown attribution.
