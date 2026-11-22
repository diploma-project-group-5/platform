// Перевірки docker-compose.yml (platform #19) і доповнення для ВМ (platform #18), без запуску стенду.
// Вхід — `docker compose … config --format json` у stdin (так їх запускає make test):
//   node tests/compose-check.mjs        кожен контейнер з лімітом пам'яті й ротацією логів, бюджет пам'яті
//   node tests/compose-check.mjs --vm   те саме + HTTPS на шлюзі для ВМ
import { readFileSync } from 'node:fs';

const vm = process.argv.includes('--vm');
const cfg = JSON.parse(readFileSync(0, 'utf8'));
const services = Object.entries(cfg.services ?? {});
let pass = 0;
let fail = 0;
const check = (ok, text) => {
  console.log(`  ${ok ? '✔' : '✖'} ${text}`);
  ok ? pass++ : fail++;
};

// mem_limit у JSON — байти (число або рядок) або рядок з одиницею, залежно від версії compose.
const bytes = (v) => {
  if (v === undefined || v === null || v === '') return 0;
  const m = /^(\d+(?:\.\d+)?)\s*([kmg]?)b?$/i.exec(String(v).trim());
  if (!m) return NaN;
  return Number(m[1]) * { '': 1, k: 1024, m: 1024 ** 2, g: 1024 ** 3 }[m[2].toLowerCase()];
};
const mib = (n) => `${Math.round(n / 1024 ** 2)} МБ`;

console.log(`▶ docker-compose${vm ? ' + docker-compose.vm.yml' : ''}: ліміти пам'яті й логи`);
check(services.length >= 14, `сервісів у конфігурації: ${services.length} (очікувалось щонайменше 14 з профілями apps і solver)`);

let budget = 0;
for (const [name, s] of services) {
  const limit = bytes(s.mem_limit ?? s.deploy?.resources?.limits?.memory);
  const log = s.logging ?? {};
  const rotated = log.driver === 'json-file' && log.options?.['max-size'] && log.options?.['max-file'];
  check(limit > 0 && rotated, `${name}: mem_limit ${limit > 0 ? mib(limit) : 'НЕМАЄ'}, ротація логів ${rotated ? `${log.options['max-size']} × ${log.options['max-file']}` : 'НЕМАЄ'}`);
  // Бюджет — лише довгоживучі контейнери: одноразові init і migrate завершуються до старту сервісів.
  if (s.restart !== 'no') budget += limit;
}
// Стеля з запасом під ВМ на 6 ГБ: ліміти — межа, а не резерв, тож фактично стенд займає менше.
check(budget <= 5 * 1024 ** 3, `сума лімітів довгоживучих контейнерів ${mib(budget)} ≤ 5120 МБ`);

if (vm) {
  console.log('▶ docker-compose.vm.yml: HTTPS на шлюзі');
  const t = cfg.services.traefik ?? {};
  const cmd = [].concat(t.command ?? []).join(' ');
  check(cmd.includes('--configFile=/etc/traefik/traefik.vm.yml'), 'traefik стартує з traefik.vm.yml (:443, Let\'s Encrypt)');
  check(JSON.stringify(t.healthcheck?.test ?? []).includes('traefik.vm.yml'), 'healthcheck traefik — з тим самим файлом');
  const ports = (t.ports ?? []).map((p) => Number(p.target));
  check(ports.includes(443) && ports.includes(80), `traefik публікує 80 (редірект) і 443: ${ports.join(', ')}`);
  check((t.volumes ?? []).some((v) => v.target === '/acme'), 'сертифікати Let\'s Encrypt — в окремому томі /acme');
  check((t.volumes ?? []).some((v) => v.target === '/logs' && /logs\/traefik$/.test(v.source ?? '')),
    'журнал запитів шлюзу — у logs/traefik на ВМ (для logrotate, 30 днів)');
  const env = t.environment ?? {};
  check(env.WEB_UPSTREAM === 'http://web:8080' && env.TIMETABLE_UPSTREAM === 'http://timetable-service:3003',
    'шлюз веде на контейнери сервісів без APPS_UPSTREAMS у команді');
}

console.log(`ℹ compose: пройдено ${pass}, не пройдено ${fail}`);
process.exit(fail === 0 ? 0 : 1);
