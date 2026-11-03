// Keycloak і realm lad (картка #18): вхід, вміст токенів, перший вхід, захист school_id,
// блокування підбору, права сервісного акаунта tenant-service.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  env, oidc, login, tenantToken, masterToken, adminApi, createScheduler, userIdFrom, randomSchoolId, sleep,
} from './lib.mjs';

const createdUsers = [];
const uniq = (p) => `${p}-${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;

after(async () => {
  if (!createdUsers.length) return;
  const token = await masterToken();
  for (const id of createdUsers) await adminApi(token, 'DELETE', `/users/${id}`);
});

async function newScheduler(opts = {}) {
  const username = uniq('test');
  const schoolId = randomSchoolId();
  const password = 'Temp-Pass-0123456';
  const res = await createScheduler(await tenantToken(), { username, schoolId, password, ...opts });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  createdUsers.push(userIdFrom(res.location));
  return { username, schoolId, password, id: userIdFrom(res.location) };
}

describe('вхід і токени', () => {
  test('демо-укладач: роль scheduler, school_id, azp web, iss, 15 хв', async () => {
    const r = await login('demo', env.demoPassword);
    assert.equal(r.status, 'ok');
    assert.equal(r.claims.iss, `${env.publicUrl}/idp/realms/lad`);
    assert.equal(r.claims.azp, 'web');
    assert.equal(r.claims.school_id, env.demoSchoolId);
    assert.ok(r.claims.realm_access.roles.includes('scheduler'));
    assert.ok(!r.claims.realm_access.roles.includes('sysadmin'));
    assert.equal(r.claims.exp - r.claims.iat, 900);
  });

  test('sysadmin: роль sysadmin, без school_id', async () => {
    const r = await login('sysadmin', env.sysadminPassword);
    assert.equal(r.status, 'ok');
    assert.ok(r.claims.realm_access.roles.includes('sysadmin'));
    assert.ok(!r.claims.realm_access.roles.includes('scheduler'));
    assert.equal(r.claims.school_id, undefined);
  });

  test('неправильний пароль — вхід не вдається', async () => {
    const { username } = await newScheduler({ temporary: false, password: 'Right-Pass-0123456' });
    const r = await login(username, 'Wrong-Pass-0123456');
    assert.equal(r.status, 'failed');
  });

  test('вхід паролем напряму (без браузера) для web вимкнено', async () => {
    const res = await fetch(`${oidc(`${env.gateway}/idp`)}/token`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'password', client_id: 'web', username: 'demo', password: env.demoPassword }),
    });
    assert.ok([400, 401].includes(res.status));
    assert.equal((await res.json()).access_token, undefined);
  });

  test('сторінка входу українською', async () => {
    const url = `${oidc(`${env.gateway}/idp`)}/auth?client_id=web&response_type=code&scope=openid` +
      `&redirect_uri=${encodeURIComponent(`${env.publicUrl}/cb`)}&code_challenge=${'a'.repeat(43)}&code_challenge_method=S256`;
    const html = await (await fetch(url)).text();
    assert.match(html, /<html[^>]*lang="uk"/);
  });
});

describe('перший вхід з тимчасовим паролем', () => {
  test('вимагає зміни пароля; короткий новий відхиляється; після зміни — токен з school_id', async () => {
    const u = await newScheduler();
    assert.equal((await login(u.username, u.password)).status, 'update_password');
    assert.equal((await login(u.username, u.password, { newPassword: 'short12' })).status, 'password_rejected');
    const r = await login(u.username, u.password, { newPassword: 'New-Pass-987654' });
    assert.equal(r.status, 'ok');
    assert.equal(r.claims.school_id, u.schoolId);
    assert.ok(r.claims.realm_access.roles.includes('scheduler'));
    assert.equal((await login(u.username, 'New-Pass-987654')).status, 'ok');
  });
});

describe('school_id', () => {
  test('користувач не може змінити свій school_id навіть напряму в Keycloak', async () => {
    const u = await newScheduler({ temporary: false, password: 'Right-Pass-0123456' });
    const { token } = await login(u.username, 'Right-Pass-0123456');
    const res = await fetch(`${env.kc}/realms/lad/account/`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ username: u.username, attributes: { school_id: [randomSchoolId()] } }),
    });
    assert.ok(res.status >= 400, `HTTP ${res.status}`);
    const again = await login(u.username, 'Right-Pass-0123456');
    assert.equal(again.claims.school_id, u.schoolId);
  });
});

describe('захист від підбору', () => {
  test('після 5 невдалих спроб не пускає й з правильним паролем', async () => {
    const u = await newScheduler({ temporary: false, password: 'Right-Pass-0123456' });
    for (let i = 0; i < 5; i++) {
      await login(u.username, `Wrong-Pass-${i}0000000`);
      await sleep(1100); // повільніше за quickLoginCheck, щоб перевіряти саме ліміт у 5 спроб
    }
    assert.equal((await login(u.username, 'Right-Pass-0123456')).status, 'failed');
    const state = await adminApi(await masterToken(), 'GET', `/attack-detection/brute-force/users/${u.id}`);
    assert.equal(state.body.disabled, true);
  });
});

describe('сервісний акаунт tenant-service', () => {
  test('створює укладача в групі schedulers з school_id і обов\'язковою зміною пароля', async () => {
    const u = await newScheduler();
    const master = await masterToken();
    const user = (await adminApi(master, 'GET', `/users/${u.id}`)).body;
    assert.deepEqual(user.attributes.school_id, [u.schoolId]);
    assert.deepEqual(user.requiredActions, ['UPDATE_PASSWORD']);
    const groups = (await adminApi(master, 'GET', `/users/${u.id}/groups`)).body.map((g) => g.path);
    assert.deepEqual(groups, ['/schedulers']);
  });

  test('зайнятий логін → 409', async () => {
    const u = await newScheduler();
    const res = await createScheduler(await tenantToken(), { username: u.username, schoolId: randomSchoolId(), password: 'Temp-Pass-0123456' });
    assert.equal(res.status, 409);
  });

  test('school_id не UUID → 400', async () => {
    const res = await createScheduler(await tenantToken(), { username: uniq('bad'), schoolId: 'not-a-uuid', password: 'Temp-Pass-0123456' });
    assert.equal(res.status, 400);
  });

  test('пароль коротший за 10 символів → 400, користувача не створено', async () => {
    const username = uniq('short');
    const token = await tenantToken();
    const res = await createScheduler(token, { username, schoolId: randomSchoolId(), password: 'short' });
    assert.equal(res.status, 400);
    const found = await adminApi(token, 'GET', `/users?username=${username}&exact=true`);
    assert.deepEqual(found.body, []);
  });

  test('видаляє користувача (відкат реєстрації)', async () => {
    const u = await newScheduler();
    const res = await adminApi(await tenantToken(), 'DELETE', `/users/${u.id}`);
    assert.equal(res.status, 204);
    createdUsers.splice(createdUsers.indexOf(u.id), 1);
  });

  test('не може змінювати realm і читати клієнтів', async () => {
    const token = await tenantToken();
    assert.equal((await adminApi(token, 'PUT', '', { enabled: true })).status, 403);
    assert.equal((await adminApi(token, 'GET', '/clients')).status, 403);
  });
});

describe('адмін-консоль', () => {
  test('вхід у консоль іде на пряму адресу (тунель), а не через шлюз', async () => {
    const html = await (await fetch(`${env.kc}/admin/master/console/`)).text();
    assert.match(html, new RegExp(`"authUrl":\\s*"http://localhost:${env.kcAdminPort}/idp"`));
  });
});
