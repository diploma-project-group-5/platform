// Спільні помічники тестів platform. Без залежностей: лише вбудовані модулі Node 24.
import http from 'node:http';
import crypto from 'node:crypto';

export const env = {
  // Шлюз, через який ходить браузер.
  gateway: process.env.GATEWAY_URL ?? 'http://traefik',
  // Публічна адреса: потрапляє в iss і redirect_uri (у стенді lad-test — той самий шлюз).
  publicUrl: process.env.LAD_PUBLIC_URL ?? 'http://traefik',
  // Keycloak напряму, внутрішньою мережею — як його бачать наші сервіси.
  kc: process.env.KC_INTERNAL_URL ?? 'http://keycloak:8080/idp',
  kcAdminPort: process.env.KC_ADMIN_PORT ?? '8180',
  kcAdminPassword: process.env.KC_ADMIN_PASSWORD,
  sysadminPassword: process.env.SYSADMIN_PASSWORD,
  demoPassword: process.env.DEMO_SCHEDULER_PASSWORD,
  demoSchoolId: process.env.DEMO_SCHOOL_ID,
  tenantSecret: process.env.TENANT_CLIENT_SECRET,
};

export const realmUrl = (base) => `${base}/realms/lad`;
export const oidc = (base) => `${realmUrl(base)}/protocol/openid-connect`;

export function decodeJwt(token) {
  return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString());
}

export const randomSchoolId = () => crypto.randomUUID();
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Запит із шляхом «як є»: fetch нормалізує шлях (прибирає ./.., міняє \ на /),
// а для перевірки обходів блокування потрібен саме сирий шлях.
export function rawGet(baseUrl, rawPath, headers = {}) {
  const u = new URL(baseUrl);
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: u.hostname, port: u.port || 80, path: rawPath, method: 'GET', headers },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (body += c));
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
      },
    );
    req.on('error', reject);
    req.end();
  });
}

// --- Вхід через браузерний потік: код авторизації з PKCE, клієнт web ---

class CookieJar {
  #cookies = new Map();
  store(res) {
    for (const c of res.headers.getSetCookie()) {
      const [pair] = c.split(';');
      const i = pair.indexOf('=');
      this.#cookies.set(pair.slice(0, i).trim(), pair.slice(i + 1));
    }
  }
  header() {
    return [...this.#cookies].map(([k, v]) => `${k}=${v}`).join('; ');
  }
}

async function send(jar, url, { method = 'GET', form } = {}) {
  const res = await fetch(url, {
    method,
    redirect: 'manual',
    headers: {
      cookie: jar.header(),
      ...(form ? { 'content-type': 'application/x-www-form-urlencoded' } : {}),
    },
    body: form ? new URLSearchParams(form).toString() : undefined,
  });
  jar.store(res);
  return res;
}

const formAction = (html) => html.match(/<form[^>]*action="([^"]+)"/)?.[1].replaceAll('&amp;', '&');
const codeFrom = (location) => (location ? new URL(location).searchParams.get('code') : null);

/**
 * Вхід користувача. Повертає:
 *   { status: 'ok', token, claims }
 *   { status: 'update_password' }      — тимчасовий пароль, а newPassword не передано
 *   { status: 'password_rejected', html } — новий пароль не пройшов політику
 *   { status: 'failed', html }         — неправильний пароль або блокування
 */
export async function login(username, password, { newPassword } = {}) {
  const jar = new CookieJar();
  const verifier = crypto.randomBytes(32).toString('base64url');
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  const redirectUri = `${env.publicUrl}/cb`;

  const authUrl = new URL(`${oidc(`${env.gateway}/idp`)}/auth`);
  authUrl.search = new URLSearchParams({
    client_id: 'web', response_type: 'code', scope: 'openid', redirect_uri: redirectUri,
    state: 'test', code_challenge: challenge, code_challenge_method: 'S256',
  }).toString();

  const page = await send(jar, authUrl);
  if (page.status !== 200) throw new Error(`сторінка входу: HTTP ${page.status}`);
  const action = formAction(await page.text());
  if (!action) throw new Error('немає форми входу');

  let res = await send(jar, action, { method: 'POST', form: { username, password, credentialId: '' } });
  let location = res.headers.get('location');

  if (location?.includes('required-action') && location.includes('UPDATE_PASSWORD')) {
    if (!newPassword) return { status: 'update_password' };
    const updatePage = await send(jar, location);
    const updateAction = formAction(await updatePage.text());
    res = await send(jar, updateAction, {
      method: 'POST', form: { 'password-new': newPassword, 'password-confirm': newPassword },
    });
    location = res.headers.get('location');
    if (!codeFrom(location)) return { status: 'password_rejected', html: await res.text() };
  }

  const code = codeFrom(location);
  if (!code) return { status: 'failed', html: await res.text() };

  const tokenRes = await fetch(`${oidc(`${env.gateway}/idp`)}/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code', client_id: 'web', code, redirect_uri: redirectUri, code_verifier: verifier,
    }),
  });
  const body = await tokenRes.json();
  if (!body.access_token) throw new Error(`обмін коду на токен: ${JSON.stringify(body)}`);
  return { status: 'ok', token: body.access_token, claims: decodeJwt(body.access_token) };
}

// --- Токени для admin API ---

async function tokenRequest(url, params) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params),
  });
  const body = await res.json();
  if (!body.access_token) throw new Error(`токен: HTTP ${res.status} ${JSON.stringify(body)}`);
  return body.access_token;
}

// Сервісний акаунт tenant-service — рівно ті права, з якими працюватиме сервіс.
export const tenantToken = () =>
  tokenRequest(`${oidc(env.kc)}/token`, {
    grant_type: 'client_credentials', client_id: 'tenant-service', client_secret: env.tenantSecret,
  });

// Адмін realm master — лише для перевірок і прибирання в тестах.
export const masterToken = () =>
  tokenRequest(`${env.kc}/realms/master/protocol/openid-connect/token`, {
    grant_type: 'password', client_id: 'admin-cli', username: 'admin', password: env.kcAdminPassword,
  });

export async function adminApi(token, method, path, body) {
  const res = await fetch(`${env.kc}/admin/realms/lad${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  return { status: res.status, location: res.headers.get('location'), body: text ? safeJson(text) : null };
}

const safeJson = (t) => { try { return JSON.parse(t); } catch { return t; } };

// Створення укладача так, як це робитиме tenant-service: одразу в групі schedulers.
export function createScheduler(token, { username, schoolId, password, temporary = true }) {
  return adminApi(token, 'POST', '/users', {
    username,
    enabled: true,
    groups: ['/schedulers'],
    attributes: { school_id: [schoolId] },
    credentials: [{ type: 'password', value: password, temporary }],
    ...(temporary ? { requiredActions: ['UPDATE_PASSWORD'] } : {}),
  });
}

export const userIdFrom = (location) => location?.split('/').pop();
