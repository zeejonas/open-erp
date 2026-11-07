// Isolated Docker fixture: ephemeral OIDC key, TLS receiver, and bounded numeric metrics.
import https from 'node:https';
import fs from 'node:fs';
import crypto from 'node:crypto';

const {privateKey, publicKey} = crypto.generateKeyPairSync('ec', {namedCurve: 'prime256v1'});
const jwk = {...publicKey.export({format: 'jwk'}), kid: 'demo', use: 'sig', alg: 'ES256'};
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
const header = encode({alg: 'ES256', typ: 'JWT', kid: 'demo'});
const claims = encode({iss: 'https://receiver.example/', aud: 'webhook-demo', sub: 'webhook-demo-user', exp: Math.floor(Date.now() / 1000) + 3600});
const unsigned = `${header}.${claims}`;
const token = `${unsigned}.${crypto.sign('sha256', Buffer.from(unsigned), {key: privateKey, dsaEncoding: 'ieee-p1363'}).toString('base64url')}`;
const secrets = new Map();
const active = new Map();
let state;
const reset = () => { state = {received: 0, completed: 0, invalid: 0, peakTotal: 0, peakSubscription: 0, organizations: [], durations: []}; };
reset();
const json = (response, value) => { response.writeHead(200, {'Content-Type': 'application/json'}); response.end(JSON.stringify(value)); };

https.createServer({key: fs.readFileSync('/fixture/receiver-key.pem'), cert: fs.readFileSync('/fixture/receiver-cert.pem')}, (request, response) => {
    if (request.method === 'GET' && request.url === '/jwks') return json(response, {keys: [jwk]});
    if (request.method === 'GET' && request.url === '/userinfo') return json(response, {email: 'demo@example.com', email_verified: true});
    if (request.method === 'GET' && request.url === '/token') return json(response, {token});
    if (request.method === 'GET' && request.url === '/stats') return json(response, state);
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
        const body = Buffer.concat(chunks);
        if (request.url === '/configure') {
            const config = JSON.parse(body);
            secrets.set(config.path, Buffer.from(config.secret.slice(6), 'base64'));
            return json(response, {configured: true});
        }
        if (request.url === '/reset') { reset(); return json(response, {reset: true}); }
        const key = secrets.get(request.url);
        const id = request.headers['webhook-id'];
        const timestamp = request.headers['webhook-timestamp'];
        const signature = request.headers['webhook-signature'];
        const input = Buffer.concat([Buffer.from(`${id}.${timestamp}.`), body]);
        const expected = key && `v1,${crypto.createHmac('sha256', key).update(input).digest('base64')}`;
        if (!expected || signature !== expected || Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) {
            state.invalid += 1;
            response.writeHead(400); response.end(); return;
        }
        state.received += 1;
        active.set(request.url, (active.get(request.url) ?? 0) + 1);
        state.peakTotal = Math.max(state.peakTotal, [...active.values()].reduce((a, b) => a + b, 0));
        state.peakSubscription = Math.max(state.peakSubscription, active.get(request.url));
        const start = Date.now();
        setTimeout(() => {
            active.set(request.url, active.get(request.url) - 1);
            state.completed += 1;
            state.organizations.push(request.url.split('/')[2]);
            state.durations.push(Date.now() - start);
            response.writeHead(202); response.end();
        }, 1000);
    });
}).listen(443, '0.0.0.0');
