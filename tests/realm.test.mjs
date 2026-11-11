// Статичні перевірки файлу realm (картка #18): швидко ловлять небезпечну правку ще до запуску Keycloak.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const realm = JSON.parse(readFileSync(new URL('../keycloak/realm/lad-realm.json', import.meta.url), 'utf8'));
const client = (id) => realm.clients.find((c) => c.clientId === id);
const profile = JSON.parse(
  realm.components['org.keycloak.userprofile.UserProfileProvider'][0].config['kc.user.profile.config'][0],
);
const attr = (name) => profile.attributes.find((a) => a.name === name);

test('school_id бачить і змінює лише адмін', () => {
  assert.deepEqual(attr('school_id').permissions, { view: ['admin'], edit: ['admin'] });
});

test('у профілі немає ПІБ і обов\'язкових полів, крім логіна', () => {
  assert.equal(attr('firstName'), undefined);
  assert.equal(attr('lastName'), undefined);
  assert.equal(attr('email').required, undefined);
});

test('клієнт web: публічний, PKCE S256, без входу паролем напряму й implicit', () => {
  const web = client('web');
  assert.equal(web.publicClient, true);
  assert.equal(web.standardFlowEnabled, true);
  assert.equal(web.directAccessGrantsEnabled, false);
  assert.equal(web.implicitFlowEnabled, false);
  assert.equal(web.attributes['pkce.code.challenge.method'], 'S256');
  assert.ok(web.protocolMappers.some((m) => m.config['claim.name'] === 'school_id'));
});

test('клієнт tenant-service: лише сервісний акаунт з правами на користувачів', () => {
  const t = client('tenant-service');
  assert.equal(t.serviceAccountsEnabled, true);
  assert.equal(t.standardFlowEnabled, false);
  assert.equal(t.directAccessGrantsEnabled, false);
  const sa = realm.users.find((u) => u.serviceAccountClientId === 'tenant-service');
  assert.deepEqual([...sa.clientRoles['realm-management']].sort(), ['manage-users', 'query-users', 'view-users']);
});

test('група schedulers дає роль scheduler', () => {
  assert.deepEqual(realm.groups, [{ name: 'schedulers', realmRoles: ['scheduler'] }]);
});

test('паролі, захист від підбору, час життя токенів', () => {
  assert.match(realm.passwordPolicy, /length\(10\)/);
  assert.match(realm.passwordPolicy, /notUsername/);
  assert.equal(realm.bruteForceProtected, true);
  assert.equal(realm.failureFactor, 5);
  assert.equal(realm.accessTokenLifespan, 900);
  assert.equal(realm.ssoSessionMaxLifespan, 28800);
  assert.equal(realm.registrationAllowed, false);
  assert.equal(realm.resetPasswordAllowed, false);
});

test('у файлі немає паролів і секретів — лише змінні з .env', () => {
  const secrets = [
    client('tenant-service').secret,
    ...realm.users.flatMap((u) => (u.credentials ?? []).map((c) => c.value)),
  ];
  for (const s of secrets) assert.match(s, /^\$\{[A-Z_]+\}$/);
});

test('тема входу lad: увімкнена в realm, файли теми на місці, поле «Логін», без пошти', () => {
  assert.equal(realm.loginTheme, 'lad');
  const theme = (f) => new URL(`../keycloak/themes/lad/login/${f}`, import.meta.url);
  for (const f of ['theme.properties', 'template.ftl', 'login.ftl', 'resources/css/lad.css', 'messages/messages_uk.properties']) {
    assert.ok(existsSync(theme(f)), `немає ${f}`);
  }
  const uk = readFileSync(theme('messages/messages_uk.properties'), 'utf8');
  assert.match(uk, /^ladUsername=Логін$/m);
  const login = readFileSync(theme('login.ftl'), 'utf8');
  assert.doesNotMatch(login, /type="email"/);
  // Сторонніх запитів зі сторінки входу немає: шрифт і стилі — лише файли теми.
  const css = readFileSync(theme('resources/css/lad.css'), 'utf8');
  assert.doesNotMatch(css, /https?:\/\//);
  // Keycloak віддає CSS без charset, тож без @charset браузер читає кирилицю в коментарях як Latin-1.
  assert.ok(css.startsWith('@charset "UTF-8";\n'), 'lad.css має починатися з @charset "UTF-8";');
});
