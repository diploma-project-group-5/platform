// Шлюз Traefik (картка #17): маршрути, закрита адмінка Keycloak, ліміт /public, захисні налаштування.
// У стенді lad-test замість сервісів стоять заглушки whoami: вони відповідають своїм іменем
// («Name: tenant») і рядком запиту, який отримали («GET /api/v1/tenant/... HTTP/1.1»).
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { env, rawGet } from './lib.mjs';

describe('маршрути', () => {
  const routes = [
    ['/', 'web'],
    ['/c', 'web'],
    ['/api/v1/tenant/schools', 'tenant'],
    ['/api/v1/school/classes', 'school'],
    ['/api/v1/timetable/jobs/1', 'timetable'],
    ['/api/v1/public/schedule', 'timetable'],
  ];
  for (const [path, service] of routes) {
    test(`${path} → ${service}, префікс не зрізано`, async () => {
      const res = await rawGet(env.gateway, path);
      assert.equal(res.status, 200);
      assert.match(res.body, new RegExp(`^Name: ${service}$`, 'm'));
      assert.match(res.body, new RegExp(`^GET ${path.replaceAll('/', '\\/')} HTTP\\/1\\.1`, 'm'));
    });
  }

  test('/idp/... веде в Keycloak', async () => {
    const res = await fetch(`${env.gateway}/idp/realms/lad/.well-known/openid-configuration`);
    assert.equal(res.status, 200);
    assert.equal((await res.json()).issuer, `${env.publicUrl}/idp/realms/lad`);
  });
});

describe('адмінка Keycloak закрита ззовні', () => {
  // Кожен рядок — спроба обходу, яку колись довелося закривати. Новий обхід — новий рядок.
  const blocked = [
    '/idp/admin/', '/idp/admin', '/idp/admin/master/console/',
    '/idp//admin/', '/idp/./admin/', '/idp/x/../admin/',
    '/idp/%61dmin/', '/idp/ADMIN/', '/idp/Admin/master/console',
    '/idp/admin%2F', '/idp/admin%2fmaster', '/idp/%3Badmin', '/idp/%5cadmin', '/idp\\admin',
    '/idp;/admin/', '/idp/admin;x/',
    '/idp/realms/master/', '/idp/realms/MASTER/', '/idp/realms/%6Daster/x', '/idp/realms//master/x',
    '/idp/realms/master/protocol/openid-connect/token',
    '/idp/realms/lad/account', '/idp/realms/lad/account/applications', '/idp/realms/LAD/ACCOUNT/',
    '/idp/realms/lad/%61ccount', '/idp/realms/lad//account', '/idp/realms/lad%2Faccount',
    '/idp/realms/lad%5Caccount', '/idp/realms/lad;x/account',
  ];
  for (const path of blocked) {
    test(`${path} → не пропускається`, async () => {
      const res = await rawGet(env.gateway, path);
      // 403 — правило idp-blocked; 400 — Traefik відкинув закодований символ ще раніше.
      assert.ok([400, 403].includes(res.status), `HTTP ${res.status}`);
    });
  }

  // Відкриті шляхи й точна відповідь самого Keycloak на них.
  const allowed = [
    ['/idp/realms/lad/.well-known/openid-configuration', 200],
    ['/idp/realms/lad/protocol/openid-connect/certs', 200],
    [`/idp/realms/lad/protocol/openid-connect/auth?client_id=web&response_type=code&scope=openid` +
      `&redirect_uri=${encodeURIComponent(`${env.publicUrl}/cb`)}&code_challenge=${'a'.repeat(43)}&code_challenge_method=S256`, 200],
    ['/idp/realms/lad/protocol/openid-connect/userinfo', 401],
  ];
  for (const [path, status] of allowed) {
    test(`${path.split('?')[0]} → відкрито (${status} від Keycloak)`, async () => {
      const res = await rawGet(env.gateway, path);
      assert.equal(res.status, status);
    });
  }
});

describe('ліміт запитів', () => {
  const burst = (path) => Promise.all(Array.from({ length: 40 }, () => rawGet(env.gateway, path)));

  test('/api/v1/public: після сплеску — 429', async () => {
    const codes = (await burst('/api/v1/public/x')).map((r) => r.status);
    assert.ok(codes.includes(429), 'немає жодного 429');
    assert.ok(codes.filter((c) => c === 200).length >= 20, 'менше 20 успішних — ліміт надто жорсткий');
  });

  test('/api/v1/tenant: ліміту немає', async () => {
    const codes = (await burst('/api/v1/tenant/x')).map((r) => r.status);
    assert.ok(!codes.includes(429));
  });
});

describe('захисні налаштування', () => {
  test('заголовки безпеки на API', async () => {
    const res = await rawGet(env.gateway, '/api/v1/tenant/schools');
    assert.equal(res.headers['x-content-type-options'], 'nosniff');
    assert.equal(res.headers['referrer-policy'], 'no-referrer');
    assert.equal(res.headers['x-frame-options'], 'SAMEORIGIN');
  });

  test('закодований слеш у шляху API → 400', async () => {
    const res = await rawGet(env.gateway, '/api/v1/tenant/a%2Fb');
    assert.equal(res.status, 400);
  });

  test('заголовок X_Forwarded_For не доходить до сервісу', async () => {
    const res = await rawGet(env.gateway, '/api/v1/tenant/x', { 'X_Forwarded_For': '6.6.6.6' });
    assert.equal(res.status, 200);
    assert.doesNotMatch(res.body, /6\.6\.6\.6/);
  });
});
