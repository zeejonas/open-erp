"""Reproduce timestamp-only retrospective matching on the disposable Compose database.

Run: python3 openspec/changes/add-organization-webhooks/demos/transaction-timestamp-race.py
Uses two connections and a preparation barrier, without timing sleeps.
Postgres: https://www.postgresql.org/docs/current/functions-info.html#FUNCTIONS-PG-SNAPSHOT
"""

import subprocess
import uuid

command = ['docker', 'exec', '-i', 'open-erp-db-1', 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'vapor_username', '-d', 'vapor_database']
schema = 'webhook_timing_demo_' + uuid.uuid4().hex

def sql(statement):
    return subprocess.run(command, input=statement.replace('webhook_timing_demo', schema), text=True, capture_output=True, check=True, timeout=15).stdout.strip()

print(sql('SELECT version();'))
sql('CREATE SCHEMA webhook_timing_demo; CREATE TABLE webhook_timing_demo.revisions (created_at timestamptz DEFAULT transaction_timestamp(), xid xid8 DEFAULT pg_current_xact_id()); CREATE TABLE webhook_timing_demo.events (occurred_at timestamptz DEFAULT transaction_timestamp(), snapshot pg_snapshot DEFAULT pg_current_snapshot());')
revision = None
try:
    revision = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    revision.stdin.write(f'BEGIN; INSERT INTO {schema}.revisions DEFAULT VALUES;\n\\echo REVISION_PREPARED\n')
    revision.stdin.flush()
    assert revision.stdout.readline().strip() == 'REVISION_PREPARED'
    sql('INSERT INTO webhook_timing_demo.events DEFAULT VALUES;')
    revision.stdin.write('COMMIT;\n\\q\n')
    revision.stdin.flush()
    revision.stdin.close()
    assert revision.wait(timeout=10) == 0, revision.stderr.read()
    print(sql("SELECT 'timestamp_only_matches=' || (r.created_at <= e.occurred_at)::text || ', revision_visible_when_event_captured=' || pg_visible_in_snapshot(r.xid, e.snapshot)::text FROM webhook_timing_demo.revisions r CROSS JOIN webhook_timing_demo.events e;"))
finally:
    if revision is not None and revision.poll() is None:
        revision.kill()
        revision.wait(timeout=10)
    sql('DROP SCHEMA IF EXISTS webhook_timing_demo CASCADE;')
