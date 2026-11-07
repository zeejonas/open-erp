"""Run independent API/worker processes against an isolated Docker test network/database.

Prerequisite: docker compose build app
Run from this repository: python3 openspec/changes/add-organization-webhooks/demos/process-demo.py
No production data, credentials or network endpoints are used. Every created container/network is removed.
"""

import base64
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[4]
DEMO = Path(__file__).resolve().parent
FIXTURES = ROOT / 'Tests/open-erpTests/Fixtures/Webhooks'
PREFIX = 'webhook-demo-' + uuid.uuid4().hex[:8]
NETWORK = PREFIX + '-network'
MANAGEMENT = PREFIX + '-control'
CONTAINERS = []
HIDDEN = []

def docker(*arguments, stdin=None):
    result = subprocess.run(['docker', *arguments], input=stdin, text=True, capture_output=True)
    if result.returncode:
        error = result.stderr
        for secret in HIDDEN:
            error = error.replace(secret, '[redacted]')
        raise RuntimeError(error)
    return result.stdout.strip()

def container(name, image, *arguments, extra=(), management=False, internal_ip=None):
    name = PREFIX + '-' + name
    CONTAINERS.append(name)
    docker('run', '--detach', '--name', name, '--network', MANAGEMENT if management else NETWORK, *extra, image, *arguments)
    if management:
        docker('network', 'connect', *(('--ip', internal_ip) if internal_ip else ()), NETWORK, name)
    return name

def env(values):
    return [item for name, value in values.items() for item in ('--env', f'{name}={value}')]

def host_port(name, port):
    if docker('inspect', '--format', '{{.State.Status}}', name) == 'exited':
        raise RuntimeError('Fixture process exited: ' + docker('logs', name))
    return int(docker('port', name, f'{port}/tcp').split(':')[-1])

class FixtureConnection(http.client.HTTPSConnection):
    def connect(self):
        raw = socket.create_connection(('127.0.0.1', self.port), self.timeout)
        self.sock = self._context.wrap_socket(raw, server_hostname='receiver.example')

def request(port, method, path, body=None, token=None, organization=None, tls=False):
    if tls:
        connection = FixtureConnection('receiver.example', port, context=ssl.create_default_context(cafile=str(FIXTURES / 'receiver-cert.pem')), timeout=15)
    else:
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=15)
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if organization:
        headers['X-Organization-ID'] = organization
    connection.request(method, path, json.dumps(body) if body is not None else None, headers)
    response = connection.getresponse()
    data = response.read()
    connection.close()
    if response.status >= 300:
        raise RuntimeError(f'Fixture request {method} {path} returned {response.status}')
    return json.loads(data) if data else None

def wait_until(predicate, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate(): return
        except (OSError, RuntimeError, http.client.HTTPException):
            pass
        time.sleep(0.1)
    raise RuntimeError('Demo readiness/progress deadline exceeded')

def sql(database, statement):
    return docker('exec', '-i', '--env', 'PGPASSWORD=open_erp_owner_local', database,
        'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'open_erp_owner', '-d', 'vapor_database', stdin=statement)

TRUST = 'cp /fixture/receiver-cert.pem /usr/local/share/ca-certificates/webhook-demo.crt && update-ca-certificates >/dev/null 2>&1 && exec /app/open-erp '

def sample(replicas):
    label = f'r{replicas}'
    key = base64.b64encode(os.urandom(32)).decode()
    HIDDEN.append(key)
    database = container(label + '-db', 'postgres:18-alpine', extra=(
        *env({'POSTGRES_USER': 'vapor_username', 'POSTGRES_PASSWORD': 'vapor_password', 'POSTGRES_DB': 'vapor_database'}),
        '--volume', f'{ROOT / "Database/bootstrap.sql"}:/docker-entrypoint-initdb.d/00-bootstrap.sql:ro',
        '--volume', f'{ROOT / "Database/compose-passwords.sql"}:/docker-entrypoint-initdb.d/01-passwords.sql:ro'))
    wait_until(lambda: docker('exec', database, 'pg_isready', '-h', '127.0.0.1', '-U', 'vapor_username', '-d', 'vapor_database').startswith('127.0.0.1:5432 - accepting'))
    base = {'DATABASE_HOST': database, 'DATABASE_NAME': 'vapor_database', 'DATABASE_TLS_MODE': 'disable', 'LOG_LEVEL': 'warning'}
    owner = {**base, 'DATABASE_USERNAME': 'open_erp_owner', 'DATABASE_PASSWORD': 'open_erp_owner_local'}
    # Migrations and audit verification deliberately receive neither OIDC nor webhook keys.
    docker('run', '--rm', '--network', NETWORK, *env(owner), 'open-erp:latest', 'migrate', '--yes')
    sql(database, 'REVOKE ALL ON public._fluent_migrations FROM open_erp_runtime;')
    docker('run', '--rm', '--network', NETWORK, *env(owner), 'open-erp:latest', 'audit-verify')
    sql(database, "BEGIN; SELECT set_config('audit.context', '{\"actor_type\":\"system\",\"actor_name\":\"webhook-process-demo\"}', true); INSERT INTO users (id, first_name, last_name, email, auth_subject, is_platform_admin) VALUES (gen_random_uuid(), 'Demo', 'Operator', 'demo@example.com', 'webhook-demo-user', true); COMMIT;")
    runtime = {**base, 'DATABASE_USERNAME': 'open_erp_runtime', 'DATABASE_PASSWORD': 'open_erp_runtime_local', 'WEBHOOK_KEY_ENCRYPTION_KEY': key}
    api_environment = {**runtime, 'OIDC_ISSUER': 'https://receiver.example/', 'OIDC_AUDIENCE': 'webhook-demo', 'OIDC_JWKS_URL': 'https://receiver.example/jwks', 'OIDC_USERINFO_URL': 'https://receiver.example/userinfo'}
    shared = ('--user', '0', '--add-host', 'receiver.example:93.184.216.10', '--volume', f'{FIXTURES}:/fixture:ro', '--entrypoint', '/bin/sh')
    api = container(label + '-api', 'open-erp:latest', '-c', TRUST + 'serve --env production --hostname 0.0.0.0 --port 8080',
        extra=(*env(api_environment), '--publish', '127.0.0.1::8080', *shared), management=True)
    api_port = host_port(api, 8080)
    wait_until(lambda: request(api_port, 'GET', '/health') == {'status': 'ok'})
    token = request(RECEIVER_PORT, 'GET', '/token', tls=True)['token']
    HIDDEN.append(token)
    organizations = []
    for index in range(8):
        provisioned = request(api_port, 'POST', '/platform/organizations', {
            'code': f'DEMO{index}', 'name': 'Webhook demo', 'adminEmail': 'demo@example.com', 'adminFirstName': 'Demo', 'adminLastName': 'Operator'}, token)
        organization = provisioned['organization']['id']
        invitation = provisioned['invitationToken']
        HIDDEN.append(invitation)
        request(api_port, 'POST', '/invitations/accept', {'token': invitation}, token)
        organizations.append(organization)
        for subscription in range(2):
            path = f'/webhooks/{organization}/{subscription}'
            created = request(api_port, 'POST', '/webhook-subscriptions', {'name': 'Demo receiver', 'url': 'https://receiver.example' + path, 'eventTypes': ['company.created'], 'companyIds': []}, token, organization)
            request(api_port, 'PATCH', '/webhook-subscriptions/' + created['id'], {'expectedRevisionId': created['currentRevisionId'], 'enabled': True}, token, organization)
            secret = request(api_port, 'POST', '/webhook-subscriptions/' + created['id'] + '/secret', token=token, organization=organization)['secret']
            HIDDEN.append(secret)
            request(RECEIVER_PORT, 'POST', '/configure', {'path': path, 'secret': secret}, tls=True)
    request(RECEIVER_PORT, 'POST', '/reset', {}, tls=True)
    for organization in organizations:
        for index in range(32):
            request(api_port, 'POST', '/companies', {'code': f'CO{index}', 'name': 'Backlog fixture'}, token, organization)
    backlog = int(sql(database, 'SELECT count(*) FROM business_event_dispatches;'))
    assert backlog >= 256 and request(RECEIVER_PORT, 'GET', '/stats', tls=True)['received'] == 0
    assert request(api_port, 'GET', '/health') == {'status': 'ok'}
    # Stop the API before starting workers: catch-up is independent of API and OIDC availability.
    docker('stop', '--time', '20', api)
    print(f'{replicas} worker process(es): API stopped with {backlog} durable dispatches', flush=True)
    workers = []
    began = time.monotonic()
    for index in range(replicas):
        workers.append(container(label + f'-worker-{index}', 'open-erp:latest', '-c', TRUST + 'webhook-worker --env production', extra=(*env(runtime), *shared)))
    wait_until(lambda: sql(database, "SELECT count(*) FROM webhook_deliveries WHERE state = 'acknowledged';") == '512', timeout=120)
    elapsed = time.monotonic() - began
    for worker in workers: docker('stop', '--time', '20', worker)
    metrics = request(RECEIVER_PORT, 'GET', '/stats', tls=True)
    assert metrics['invalid'] == 0 and metrics['completed'] == 512
    median = float(sql(database, "SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM finished_at - started_at)) FROM webhook_delivery_entries WHERE kind = 'result';"))
    result = {'replicas': replicas, 'deliveries': 512, 'endpointDelayMilliseconds': 1000, 'elapsedSeconds': elapsed,
        'deliveriesPerSecond': 512 / elapsed, 'peakInFlight': metrics['peakTotal'], 'peakPerSubscription': metrics['peakSubscription'],
        'organizationsInFirst32': len(set(metrics['organizations'][:32])), 'medianAttemptDurationSeconds': median,
        'durableDispatchesBeforeWorkerStart': backlog, 'apiStoppedDuringCatchUp': True, 'workerOIDCVariables': False}
    assert result['peakPerSubscription'] <= 4 and result['organizationsInFirst32'] == 8
    for name in [api, *workers, database]:
        docker('rm', '--force', '--volumes', name)
        CONTAINERS.remove(name)
    return result

try:
    docker('network', 'create', '--internal', '--subnet', '93.184.216.0/24', NETWORK)
    docker('network', 'create', MANAGEMENT)
    receiver = container('receiver', 'node:22-alpine', 'node', '/demo/receiver.mjs', extra=(
        '--publish', '127.0.0.1::443', '--volume', f'{DEMO}:/demo:ro', '--volume', f'{FIXTURES}:/fixture:ro'), management=True, internal_ip='93.184.216.10')
    RECEIVER_PORT = host_port(receiver, 443)
    wait_until(lambda: request(RECEIVER_PORT, 'GET', '/stats', tls=True)['received'] == 0)
    one = sample(1)
    two = sample(2)
    ratio = two['deliveriesPerSecond'] / one['deliveriesPerSecond']
    report = {'one': one, 'two': two, 'throughputRatio': ratio, 'topology': 'independent Linux API and worker OS processes; isolated internal Docker network'}
    (DEMO / 'process-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2), flush=True)
    assert ratio > 1.5 and one['peakInFlight'] <= 16 and 16 < two['peakInFlight'] <= 32
finally:
    for name in CONTAINERS:
        subprocess.run(['docker', 'rm', '--force', '--volumes', name], capture_output=True)
    subprocess.run(['docker', 'network', 'rm', NETWORK], capture_output=True)
    subprocess.run(['docker', 'network', 'rm', MANAGEMENT], capture_output=True)
