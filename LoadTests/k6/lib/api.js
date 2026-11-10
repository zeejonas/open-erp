// HTTP helpers shared by seeding and scenarios. Every request carries a `name` tag set to
// its route template, so per-ID URLs don't explode metric cardinality.
import { sleep } from 'k6';
import http from 'k6/http';

export const BASE = __ENV.BASE_URL;
const OIDC = __ENV.OIDC_URL;

export function mint(sub, email, extra = {}) {
  const res = http.post(`${OIDC}/token`, JSON.stringify({ sub, email, ...extra }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'oidc-token' },
  });
  if (res.status !== 200) throw new Error(`token mint failed: ${res.status}`);
  return res.json('access_token');
}

/** Builds a request for `http.request` or `http.batch`. */
export function req(method, path, { token, org, body, name, tags = {} } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (org) headers['X-Organization-ID'] = org;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return {
    method,
    url: `${BASE}${path}`,
    body: body === undefined ? null : JSON.stringify(body),
    params: { headers, tags: { name: name || path, ...tags } },
  };
}

export function send(method, path, options) {
  const r = req(method, path, options);
  return http.request(r.method, r.url, r.body, r.params);
}

/** Sends a request that must succeed; seeding and setup stop on the first failure. */
export function must(status, method, path, options) {
  const res = send(method, path, options);
  if (res.status !== status) {
    throw new Error(`${method} ${options && options.name || path} returned ${res.status}, expected ${status}`);
  }
  return res;
}

/** Sends requests in parallel batches and requires every response to have `status`. */
export function mustBatch(status, requests, size = 20) {
  const results = [];
  for (let i = 0; i < requests.length; i += size) {
    const chunk = requests.slice(i, i + size);
    const responses = http.batch(chunk.map((r) => [r.method, r.url, r.body, r.params]));
    responses.forEach((res, j) => {
      if (res.status !== status) {
        throw new Error(`${chunk[j].method} ${chunk[j].params.tags.name} returned ${res.status}, expected ${status}`);
      }
    });
    results.push(...responses);
  }
  return results;
}

/** The API reports healthy only once it has loaded the stub's signing keys. */
export function waitForHealth() {
  for (let i = 0; i < 90; i++) {
    if (http.get(`${BASE}/health`, { tags: { name: '/health' } }).status === 200) return;
    sleep(1);
  }
  throw new Error('API did not report healthy within 90 s');
}
