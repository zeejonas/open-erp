#!/usr/bin/env bash
# Runs the load-test harness end to end: build, start an isolated stack, seed through the
# API, measure, report, tear down. Requires only Docker.
#
#   LoadTests/run.sh [--keep] [--config path/to/config.json]
#
# --keep leaves the stack and its database running for inspection; remove it later with
#   docker compose -f LoadTests/compose.yml --profile tools down -v
set -euo pipefail

keep=0
config="$(cd "$(dirname "$0")" && pwd)/config.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep=1 ;;
    # Resolve against the caller's directory, before changing into LoadTests/.
    --config) config="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift ;;
    *) echo "usage: $0 [--keep] [--config file]" >&2; exit 2 ;;
  esac
  shift
done
[ -f "$config" ] || { echo "Config file not found: $config" >&2; exit 2; }
cd "$(dirname "$0")"

# The harness only ever writes to its own database.
export DATABASE_NAME="${DATABASE_NAME:-open_erp_loadtest}"
if [ "$DATABASE_NAME" != "open_erp_loadtest" ]; then
  echo "Refusing to run: DATABASE_NAME is '$DATABASE_NAME', but the harness only uses open_erp_loadtest." >&2
  exit 1
fi

export APP_CPUS="${APP_CPUS:-2}" APP_MEMORY="${APP_MEMORY:-1g}" DB_CPUS="${DB_CPUS:-2}" K6_CPUS="${K6_CPUS:-2}"
export DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP="${DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP:-4}"
export LOADTEST_CONFIG="$config"
export HOST_UID HOST_GID
HOST_UID="$(id -u)" HOST_GID="$(id -g)"
# A throwaway key for this run's disposable database.
WEBHOOK_KEY_ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"
export WEBHOOK_KEY_ENCRYPTION_KEY
export REPORT_DIR="$PWD/reports/$(date -u +%Y%m%dT%H%M%SZ)"
export PLATFORM_SUBJECT=loadtest-platform-admin PLATFORM_EMAIL=loadtest-platform-admin@loadtest.example.com
mkdir -p "$REPORT_DIR"

compose() { docker compose -f compose.yml --profile tools "$@"; }
sql() { compose exec -T db psql -U loadtest_admin -d "$DATABASE_NAME" -Atc "$1"; }

sampler=""
cleanup() {
  [ -n "$sampler" ] && kill "$sampler" 2>/dev/null || true
  if [ "$keep" = 1 ]; then
    echo "Stack kept. Remove it with: docker compose -f LoadTests/compose.yml --profile tools down -v"
  else
    compose down -v --remove-orphans >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> Building"
compose down -v --remove-orphans >/dev/null 2>&1 || true
compose build

echo "==> Starting database, identity stub and migrations"
compose up -d --wait db
compose up -d oidc-stub
compose run --rm migrate
compose up -d app worker
compose run --rm cli platform-admin "$PLATFORM_EMAIL" Load Admin "$PLATFORM_SUBJECT" --operator loadtest-harness --env production

echo "==> Seeding"
compose run --rm -e PLATFORM_SUBJECT -e PLATFORM_EMAIL k6 run --quiet /scripts/seed.js

echo "==> Draining the webhook worker"
for _ in $(seq 1 300); do
  backlog="$(sql "SELECT (SELECT count(*) FROM business_event_dispatches) + (SELECT count(*) FROM webhook_deliveries WHERE attempt_count = 0)")"
  [ "$backlog" = 0 ] && break
  sleep 1
done
compose stop worker
[ "$backlog" = 0 ] || { echo "Worker did not drain the backlog ($backlog left)" >&2; exit 1; }

deliveries="$(sql "SELECT count(*) FROM webhook_deliveries")"
failed="$(sql "SELECT count(*) FROM webhook_delivery_entries WHERE kind = 'result' AND outcome <> 'acknowledged'")"
unaudited="$(sql "
  SELECT count(*) FROM (
    SELECT 'companies' AS t, id, created_by FROM companies
    UNION ALL SELECT 'webhook_subscriptions', id, created_by FROM webhook_subscriptions
  ) seeded
  WHERE seeded.created_by IS NULL OR NOT EXISTS (
    SELECT 1 FROM audit.audit_events a
    WHERE a.table_name = seeded.t AND a.record_id = seeded.id AND a.operation = 'create'
      AND a.actor_type = 'user' AND a.actor_id = seeded.created_by)")"
echo "Seeded $deliveries deliveries with $failed failed attempts; $unaudited seeded rows without an attributed audit event"
if [ "$deliveries" = 0 ] || [ "$failed" = 0 ] || [ "$unaudited" != 0 ]; then
  echo "Seed verification failed" >&2
  exit 1
fi

echo "==> Measuring (pg sampler on)"
( while true; do
    sql "SELECT extract(epoch FROM now())::bigint || ',' || count(*) FROM pg_stat_activity WHERE usename = 'open_erp_runtime'" \
      >> "$REPORT_DIR/pg-samples.csv" 2>/dev/null || true
    sleep 1
  done ) &
sampler=$!
status=0
compose run --rm k6 run --quiet /scripts/scenarios.js || status=$?
kill "$sampler" 2>/dev/null || true
sampler=""
# 99 means some step crossed a threshold, which is how saturation is found. Anything else is a failure.
if [ "$status" != 0 ] && [ "$status" != 99 ]; then
  echo "Scenario run failed (k6 exit $status)" >&2
  exit "$status"
fi

reveals="$(sql "
  SELECT count(*) FROM webhook_secret_reveals r
  WHERE NOT EXISTS (
    SELECT 1 FROM organization_users ou
    JOIN group_members gm ON gm.organization_user_id = ou.id AND gm.deleted_at IS NULL
    JOIN groups g ON g.id = gm.group_id AND g.template_key = 'org_admins'
    WHERE ou.user_id = r.actor_id AND ou.organization_id = r.organization_id)")"

echo "==> Writing report"
compose run --rm \
  -e GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet HEAD -- .. 2>/dev/null || echo '-dirty')" \
  -e HOST_CPUS="$(getconf _NPROCESSORS_ONLN)" \
  -e APP_CPUS -e APP_MEMORY -e DB_CPUS -e K6_CPUS -e DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP \
  -e UNAUTHORIZED_REVEALS="$reveals" \
  k6 run --quiet /scripts/report.js
rm -f "$REPORT_DIR/seed.json" "$REPORT_DIR/results.json" "$REPORT_DIR/pg-samples.csv"
echo "Report: $REPORT_DIR/report.md"
