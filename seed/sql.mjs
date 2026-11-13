// SQL сіду демо-закладу (картка #21) для однієї бази: tenant, school або timetable.
// Друкує SQL у stdout; виконує його scripts/seed.sh через psql. Ідемпотентно: повторний запуск
// повертає дані закладу до стану з seed/demo-school.json.
//
// Ролі. school і timetable — робочі ролі <svc>_app із set_config('app.school_id', …): таблиці
// мають FORCE ROW LEVEL SECURITY і політики лише для app, тож власник без політики не побачив би
// рядків. Так сід проходить ті самі перевірки RLS, що й сервіс. tenant — tenant_owner: реєстр
// закладів без RLS (задокументований виняток), а tenant_app не має UPDATE, потрібного для повтору.
//
// Використання (змінні середовища):
//   node seed/sql.mjs tenant     DEMO_SCHOOL_ID, DEMO_USER_ID (id користувача demo у Keycloak)
//   node seed/sql.mjs school     DEMO_SCHOOL_ID — останній рядок виводу psql: новий snapshot_version
//   node seed/sql.mjs timetable  DEMO_SCHOOL_ID, SNAPSHOT_VERSION (з кроку school); бере й
//                                розклад solver: seed/timetable-main.json, seed/timetable-alert.json
//   node seed/sql.mjs counts     очікувані кількості рядків для перевірки після сіду
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { SEED_PATH, uuid5 } from './build.mjs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const DEMO_LOGIN = 'demo';

/** Рядковий літерал SQL: апостроф подвоюється («Здоров''я»). */
export const lit = (v) => (v === null || v === undefined ? 'null' : `'${String(v).replaceAll("'", "''")}'`);
const uuid = (v, what) => {
  if (!UUID.test(v ?? '')) throw new Error(`${what}: потрібен UUID, отримано «${v ?? ''}»`);
  return `'${v}'::uuid`;
};
const values = (rows) => rows.map((r) => `  (${r.join(', ')})`).join(',\n');
const ids = (list, key) => list.map((x) => `'${x[key]}'::uuid`).join(', ');
const withSchool = (schoolId, body) =>
  `begin;\ndo $$ begin perform set_config('app.school_id', '${schoolId}', true); end $$;\n${body}\ncommit;\n`;

export function tenantSql(seed, schoolId, userId) {
  uuid(schoolId, 'DEMO_SCHOOL_ID');
  return `insert into schools (school_id, name, scheduler_login, scheduler_user_id)
values (${uuid(schoolId, 'DEMO_SCHOOL_ID')}, ${lit(seed.profile.name)}, ${lit(DEMO_LOGIN)}, ${uuid(userId, 'DEMO_USER_ID')})
on conflict (school_id) do update set
  name = excluded.name, scheduler_login = excluded.scheduler_login, scheduler_user_id = excluded.scheduler_user_id;
`;
}

export function schoolSql(seed, schoolId) {
  uuid(schoolId, 'DEMO_SCHOOL_ID');
  const p = seed.profile;
  const s = `'${schoolId}'::uuid`;
  return withSchool(
    schoolId,
    `insert into school_profile (school_id, name, lessons_per_day, saturday, shelter_capacity, non_teaching_staff, shelter_seats, registered_at)
values (${s}, ${lit(p.name)}, ${p.lessons_per_day}, ${p.saturday}, ${p.shelter_capacity}, ${p.non_teaching_staff}, ${p.shelter_seats}, now())
on conflict (school_id) do update set
  name = excluded.name, lessons_per_day = excluded.lessons_per_day, saturday = excluded.saturday,
  shelter_capacity = excluded.shelter_capacity, non_teaching_staff = excluded.non_teaching_staff,
  shelter_seats = excluded.shelter_seats, registered_at = coalesce(school_profile.registered_at, excluded.registered_at);

-- План і дзвінки — повністю з файлу; класи, предмети й вчителі, яких у файлі немає, прибираємо
-- (план уже порожній, тож зовнішні ключі не заважають), решту оновлюємо на місці.
delete from curriculum;
delete from bells;
delete from classes where class_id not in (${ids(seed.classes, 'class_id')});
delete from subjects where subject_id not in (${ids(seed.subjects, 'subject_id')});
delete from teachers where teacher_id not in (${ids(seed.teachers, 'teacher_id')});

insert into bells (school_id, lesson_no, starts_at, ends_at) values
${values(seed.bells.map((b) => [s, b.lesson_no, lit(b.starts_at), lit(b.ends_at)]))};

insert into classes (school_id, class_id, name, students, in_person_priority) values
${values(seed.classes.map((c) => [s, `'${c.class_id}'`, lit(c.name), c.students, c.in_person_priority]))}
on conflict (school_id, class_id) do update set
  name = excluded.name, students = excluded.students, in_person_priority = excluded.in_person_priority, archived_at = null;

insert into subjects (school_id, subject_id, name, short_name, education_area, not_in_shelter) values
${values(seed.subjects.map((x) => [s, `'${x.subject_id}'`, lit(x.name), lit(x.short_name), lit(x.education_area), x.not_in_shelter]))}
on conflict (school_id, subject_id) do update set
  name = excluded.name, short_name = excluded.short_name, education_area = excluded.education_area,
  not_in_shelter = excluded.not_in_shelter, archived_at = null;

insert into teachers (school_id, teacher_id, teacher_no, label, weekly_hours_limit, unavailable_days) values
${values(seed.teachers.map((t) => [s, `'${t.teacher_id}'`, t.teacher_no, lit(t.label), t.weekly_hours_limit, `'{${t.unavailable_days.join(',')}}'::smallint[]`]))}
on conflict (school_id, teacher_id) do update set
  teacher_no = excluded.teacher_no, label = excluded.label, weekly_hours_limit = excluded.weekly_hours_limit,
  unavailable_days = excluded.unavailable_days, deleted_at = null;

insert into curriculum (school_id, class_id, subject_id, teacher_id, hours_per_week) values
${values(seed.curriculum.map((r) => [s, `'${r.class_id}'`, `'${r.subject_id}'`, `'${r.teacher_id}'`, r.hours_per_week]))};

-- Дані змінились — новий snapshot_version (як у транзакції кожної зміни в school-service).
-- Його ж запише timetable у «Стан закладу»; psql друкує число останнім рядком.
update school_profile set snapshot_version = snapshot_version + 1, updated_at = now();
select snapshot_version from school_profile;`,
  );
}

// Пріоритетні освітні галузі timetable-service (DEFAULT_PRIORITY_AREAS у config.ts).
export const PRIORITY_AREAS = ['math', 'science', 'language_literature', 'civic_history'];
export const MAIN_ID = uuid5('timetable:main');
export const ALERT_ID = uuid5('timetable:alert');

/**
 * Версія розкладу з результату solver (id генератора) у термінах timetable-service: UUID сіду,
 * input — та сама проєкція знімка, що будує projection.ts для solver і validator-lib, names — копія
 * назв і підписів. Невідомий id генератора — помилка: розклад не від цього сід-файлу.
 */
export function versionOf(seed, kind, result) {
  const map = (list, key) => new Map(list.map((x) => [x.source_id, x[key]]));
  const cls = map(seed.classes, 'class_id');
  const sub = map(seed.subjects, 'subject_id');
  const tch = map(seed.teachers, 'teacher_id');
  const id = (m, v, what) => {
    const u = m.get(v);
    if (!u) throw new Error(`розклад ${kind}: невідомий ${what} «${v}» — не з seed/solver-problem.json`);
    return u;
  };
  if (!['OPTIMAL', 'FEASIBLE'].includes(result.status)) throw new Error(`розклад ${kind}: status ${result.status}`);
  const p = seed.profile;
  const input = {
    kind,
    school_days: p.saturday ? [1, 2, 3, 4, 5, 6] : [1, 2, 3, 4, 5],
    lessons_per_day: kind === 'alert' ? seed.alert_bells.length : p.lessons_per_day,
    staff: p.non_teaching_staff,
    capacity: kind === 'alert' ? { seats: p.shelter_seats, passport: p.shelter_capacity } : { passport: p.shelter_capacity },
    classes: seed.classes.map((c) => ({ id: c.class_id, students: c.students, priority: c.in_person_priority })),
    subjects: seed.subjects.map((s) => ({ id: s.subject_id, priority_area: PRIORITY_AREAS.includes(s.education_area), no_shelter: s.not_in_shelter })),
    teachers: seed.teachers.map((t) => ({ id: t.teacher_id, weekly_limit: t.weekly_hours_limit, unavailable_days: [...t.unavailable_days].sort((a, b) => a - b) })),
    rows: seed.curriculum.map((r) => ({ class_id: r.class_id, subject_id: r.subject_id, teacher_id: r.teacher_id, hours: r.hours_per_week })),
  };
  const names = {
    classes: seed.classes.map((c) => ({ class_id: c.class_id, name: c.name })),
    teachers: seed.teachers.map((t) => ({ teacher_id: t.teacher_id, label: t.label })),
    subjects: seed.subjects.map((s) => ({ subject_id: s.subject_id, name: s.name, short_name: s.short_name })),
  };
  const lessons = result.lessons.map((l) => ({
    class_id: id(cls, l.class_id, 'клас'),
    day: l.day,
    lesson_no: l.lesson_no,
    subject_id: id(sub, l.subject_id, 'предмет'),
    teacher_id: id(tch, l.teacher_id, 'вчитель'),
  }));
  const day_formats = result.day_formats.map((f) => ({ class_id: id(cls, f.class_id, 'клас'), day: f.day, in_person: f.in_person }));
  const wall = result.stats?.wall_time_s;
  return {
    timetable_id: kind === 'alert' ? ALERT_ID : MAIN_ID,
    kind,
    input,
    names,
    lessons,
    day_formats,
    build_ms: typeof wall === 'number' ? Math.round(wall * 1000) : null,
  };
}

function versionSql(s, v, version, publication) {
  const published = publication
    ? `'published', ${lit(publication.order_no)}, ${lit(publication.order_date)}, ${lit(publication.approved_by)}, ${lit(publication.effective_from)}, ${lit(publication.published_at)}`
    : `'validated', null, null, null, null, null`;
  return `insert into timetables (school_id, timetable_id, kind, state, order_no, order_date, approved_by, effective_from, published_at, snapshot_version, input, names, build_ms) values
  (${s}, '${version.timetable_id}', ${lit(version.kind)}, ${published}, ${v}, ${lit(JSON.stringify(version.input))}::jsonb, ${lit(JSON.stringify(version.names))}::jsonb, ${version.build_ms ?? 'null'});
insert into lessons (school_id, timetable_id, class_id, day, lesson_no, subject_id, teacher_id) values
${values(version.lessons.map((l) => [s, `'${version.timetable_id}'`, `'${l.class_id}'`, l.day, l.lesson_no, `'${l.subject_id}'`, `'${l.teacher_id}'`]))};
insert into day_formats (school_id, timetable_id, class_id, day, in_person) values
${values(version.day_formats.map((f) => [s, `'${version.timetable_id}'`, `'${f.class_id}'`, f.day, f.in_person]))};`;
}

export function timetableSql(seed, schoolId, snapshotVersion, timetables) {
  uuid(schoolId, 'DEMO_SCHOOL_ID');
  const v = Number(snapshotVersion);
  if (!Number.isInteger(v) || v < 1) throw new Error(`SNAPSHOT_VERSION: потрібне ціле ≥ 1, отримано «${snapshotVersion ?? ''}»`);
  const s = `'${schoolId}'::uuid`;
  const main = versionOf(seed, 'main', timetables.main);
  const alert = versionOf(seed, 'alert', timetables.alert);
  const bells = JSON.stringify(seed.bells.map((b) => ({ lesson_no: b.lesson_no, start: b.starts_at, end: b.ends_at })));
  const targets = [
    ...seed.classes.map((c) => ['class', c.class_id]),
    ...seed.teachers.map((t) => ['teacher', t.teacher_id]),
  ];
  return withSchool(
    schoolId,
    `insert into school_state (school_id, known_snapshot_version, main_bells, saturday, holiday_from, holiday_to)
values (${s}, ${v}, ${lit(bells)}::jsonb, ${seed.profile.saturday}, ${lit(seed.holidays.from)}, ${lit(seed.holidays.to)})
on conflict (school_id) do update set
  known_snapshot_version = excluded.known_snapshot_version, main_bells = excluded.main_bells,
  saturday = excluded.saturday, holiday_from = excluded.holiday_from, holiday_to = excluded.holiday_to,
  updated_at = now();

-- QR: токен на кожен клас і вчителя. Наявний токен лишається (аркуші вже надруковані), лише
-- знімається відкликання; token_id випадковий — відкритий токен відтворюється з секрету QR_HMAC_SECRET.
insert into access_tokens (school_id, token_id, scope, target_id) values
${values(targets.map(([scope, id]) => [s, 'gen_random_uuid()', lit(scope), `'${id}'`]))}
on conflict (school_id, scope, target_id) do update set revoked_at = null;

update access_tokens set revoked_at = now()
where revoked_at is null
  and not ((scope = 'class' and target_id in (${ids(seed.classes, 'class_id')}))
        or (scope = 'teacher' and target_id in (${ids(seed.teachers, 'teacher_id')})));

-- Розклад демо-закладу з нуля: усе, що наробили на попередньому прогоні демо (задачі, версії,
-- публікації, план і активації тривог, облік тривог, відсутності й заміни), прибираємо.
-- Уроки й формати днів видаляються каскадом разом з версіями.
delete from substitutions;
delete from absences;
delete from alert_activations;
delete from alert_hours;
delete from alert_plan;
delete from alert_bells;
delete from timetables;
delete from jobs;

insert into alert_bells (school_id, lesson_no, starts_at, ends_at) values
${values(seed.alert_bells.map((b) => [s, b.lesson_no, lit(b.starts_at), lit(b.ends_at)]))};

-- Чинна основна версія (1.1), опублікована наказом з минулою датою.
${versionSql(s, v, main, seed.publication)}

-- Шаблон розкладу тривог (1.2): validated, план тривог — чернетка, яку на демо погоджують і активують.
${versionSql(s, v, alert, null)}
insert into alert_plan (school_id, timetable_id) values (${s}, '${alert.timetable_id}');`,
  );
}

export const loadSeed = () => JSON.parse(readFileSync(SEED_PATH, 'utf8'));
const readJson = (name) => JSON.parse(readFileSync(new URL(`./${name}`, import.meta.url), 'utf8'));
export const loadTimetables = () => ({ main: readJson('timetable-main.json'), alert: readJson('timetable-alert.json') });

/** Очікувані кількості для перевірки після сіду: класи, предмети, вчителі, рядки плану, дзвінки, QR,
 *  уроки й формати днів основної версії, уроки шаблону тривог, дзвінки тривог. */
export const counts = (seed, timetables = loadTimetables()) => [
  seed.classes.length,
  seed.subjects.length,
  seed.teachers.length,
  seed.curriculum.length,
  seed.bells.length,
  seed.classes.length + seed.teachers.length,
  timetables.main.lessons.length,
  timetables.main.day_formats.length,
  timetables.alert.lessons.length,
  seed.alert_bells.length,
];

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const seed = loadSeed();
  const { DEMO_SCHOOL_ID, DEMO_USER_ID, SNAPSHOT_VERSION } = process.env;
  const target = process.argv[2];
  try {
    if (target === 'tenant') process.stdout.write(tenantSql(seed, DEMO_SCHOOL_ID, DEMO_USER_ID));
    else if (target === 'school') process.stdout.write(schoolSql(seed, DEMO_SCHOOL_ID));
    else if (target === 'timetable') process.stdout.write(timetableSql(seed, DEMO_SCHOOL_ID, SNAPSHOT_VERSION, loadTimetables()));
    else if (target === 'counts') console.log(counts(seed).join(' '));
    else throw new Error('вкажіть базу: tenant, school або timetable (або counts)');
  } catch (e) {
    console.error(`✖ seed/sql.mjs: ${e.message}`);
    process.exit(1);
  }
}
