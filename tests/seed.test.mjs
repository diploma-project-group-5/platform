// Статичні перевірки сід-файлу демо-закладу (картка #21): ті самі обмеження, що й у таблицях
// school-service, щоб сід не впав на CHECK посеред демо. Стенд для них не потрібен.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PROBLEM_PATH, SEED_PATH, render, uuid5 } from '../seed/build.mjs';
import { counts, schoolSql, tenantSql, timetableSql } from '../seed/sql.mjs';

const text = readFileSync(SEED_PATH, 'utf8');
const seed = JSON.parse(text);
const problem = JSON.parse(readFileSync(PROBLEM_PATH, 'utf8'));
const AREAS = ['math', 'science', 'language_literature', 'civic_history', 'informatics', 'arts', 'technology', 'social_health', 'physical'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

const unique = (list, key) => assert.equal(new Set(list.map(key)).size, list.length, `дублікати: ${key}`);

test('закомічений сід-файл збігається з виходом seed/build.mjs', () => {
  assert.equal(text, render(problem), 'запустіть node seed/build.mjs і закомітьте результат');
});

test('UUIDv5 — стандартний (як uuid.uuid5 у Python, яким користується solver)', () => {
  assert.equal(uuid5('class:c01-a'), '44a0e811-e149-52c2-9456-aee7de4f31ce');
});

test('масштаб демо: 24–30 класів, укриття ≈ 55% від усіх у будівлі', () => {
  assert.ok(seed.classes.length >= 24 && seed.classes.length <= 30);
  const people = seed.classes.reduce((s, c) => s + c.students, 0) + seed.teachers.length + seed.profile.non_teaching_staff;
  const ratio = seed.profile.shelter_capacity / people;
  assert.ok(ratio > 0.5 && ratio < 0.6, `частка ${ratio.toFixed(2)}`);
});

test('профіль і дзвінки в межах CHECK school-service', () => {
  const p = seed.profile;
  assert.ok(p.name.length >= 1 && p.name.length <= 200);
  assert.ok(p.lessons_per_day >= 1 && p.lessons_per_day <= 10);
  assert.ok(p.shelter_seats >= 0 && p.shelter_seats <= p.shelter_capacity);
  assert.equal(seed.bells.length, p.lessons_per_day);
  seed.bells.forEach((b, i) => {
    assert.equal(b.lesson_no, i + 1);
    assert.ok(b.starts_at < b.ends_at);
    if (i > 0) assert.ok(seed.bells[i - 1].ends_at <= b.starts_at, `урок ${i + 1} перетинається з попереднім`);
  });
  assert.ok(seed.holidays.from <= seed.holidays.to);
});

test('класи, предмети, вчителі: id, назви, діапазони', () => {
  for (const [list, id] of [[seed.classes, 'class_id'], [seed.subjects, 'subject_id'], [seed.teachers, 'teacher_id']]) {
    unique(list, (x) => x[id]);
    for (const x of list) assert.match(x[id], UUID);
  }
  unique(seed.classes, (c) => c.name.toLowerCase());
  for (const c of seed.classes) assert.ok(c.name.length <= 50 && c.students >= 0 && c.students <= 60);
  for (const s of seed.subjects) {
    assert.ok(s.name.length <= 100 && s.short_name.length >= 1 && s.short_name.length <= 20, s.name);
    assert.ok(AREAS.includes(s.education_area), s.education_area);
  }
  unique(seed.teachers, (t) => t.label);
  unique(seed.teachers, (t) => t.teacher_no);
  for (const t of seed.teachers) {
    assert.ok(t.label.length >= 1 && t.label.length <= 100);
    assert.ok(t.weekly_hours_limit >= 0 && t.weekly_hours_limit <= 60);
    assert.ok(t.unavailable_days.every((d) => d >= 1 && d <= 6));
  }
});

test('план: посилання цілі, години в межах, навантаження вчителя ≤ ліміту', () => {
  const ids = (list, key) => new Set(list.map((x) => x[key]));
  const classes = ids(seed.classes, 'class_id');
  const subjects = ids(seed.subjects, 'subject_id');
  const teachers = new Map(seed.teachers.map((t) => [t.teacher_id, t]));
  unique(seed.curriculum, (r) => `${r.class_id}/${r.subject_id}`);
  const load = new Map();
  for (const r of seed.curriculum) {
    assert.ok(classes.has(r.class_id) && subjects.has(r.subject_id) && teachers.has(r.teacher_id));
    assert.ok(r.hours_per_week >= 1 && r.hours_per_week <= 60);
    load.set(r.teacher_id, (load.get(r.teacher_id) ?? 0) + r.hours_per_week);
  }
  for (const [id, hours] of load) assert.ok(hours <= teachers.get(id).weekly_hours_limit, teachers.get(id).label);
  const perClass = new Map();
  for (const r of seed.curriculum) perClass.set(r.class_id, (perClass.get(r.class_id) ?? 0) + r.hours_per_week);
  const slots = seed.profile.lessons_per_day * (seed.profile.saturday ? 6 : 5);
  for (const [id, hours] of perClass) assert.ok(hours <= slots, `клас ${id}: ${hours} год > ${slots} слотів`);
});

// SQL сіду (seed/sql.mjs): виконується на стенді через make seed, тут — що генерується правильно.
const SCHOOL = '5d0b6a1e-7c3f-4b2a-9e41-0a1d2c3b4e5f';

test('SQL сіду: заклад лише з set_config у транзакції, інших school_id немає', () => {
  const own = new Set([SCHOOL, ...seed.classes.map((c) => c.class_id), ...seed.subjects.map((x) => x.subject_id), ...seed.teachers.map((t) => t.teacher_id)]);
  for (const sql of [schoolSql(seed, SCHOOL), timetableSql(seed, SCHOOL, 1)]) {
    assert.match(sql, /^begin;\ndo \$\$ begin perform set_config\('app\.school_id', '5d0b6a1e-7c3f-4b2a-9e41-0a1d2c3b4e5f', true\); end \$\$;/);
    assert.match(sql, /\ncommit;\n$/);
    const foreign = [...sql.matchAll(/'([0-9a-f]{8}-[0-9a-f-]{27})'/g)].map((m) => m[1]).filter((x) => !own.has(x));
    assert.deepEqual(foreign, []);
  }
});

test('SQL сіду: апостроф у назві екрановано, рядків стільки, скільки у файлі', () => {
  const sql = schoolSql(seed, SCHOOL);
  assert.ok(sql.includes("'Здоров''я, безпека та добробут'"));
  const block = (table) => sql.split(`insert into ${table} (`)[1].split(/;\n/)[0];
  const tuples = (table) => (block(table).match(/\n {2}\(/g) ?? []).length;
  const [classes, subjects, teachers, rows, bells] = counts(seed);
  assert.deepEqual(
    [tuples('classes'), tuples('subjects'), tuples('teachers'), tuples('curriculum'), tuples('bells')],
    [classes, subjects, teachers, rows, bells],
  );
  assert.match(sql, /update school_profile set snapshot_version = snapshot_version \+ 1/);
});

test('SQL сіду: дзвінки в «Стані закладу» у форматі timetable, QR на кожен клас і вчителя', () => {
  const sql = timetableSql(seed, SCHOOL, 7);
  assert.ok(sql.includes('{"lesson_no":1,"start":"08:30","end":"09:15"}'));
  assert.equal((sql.match(/gen_random_uuid\(\)/g) ?? []).length, counts(seed)[5]);
  assert.match(sql, /values \('5d0b6a1e-[^']+'::uuid, 7,/);
});

test('SQL сіду: неправильні DEMO_SCHOOL_ID, DEMO_USER_ID, SNAPSHOT_VERSION відхиляються', () => {
  assert.throws(() => schoolSql(seed, "x'; drop table classes; --"), /DEMO_SCHOOL_ID/);
  assert.throws(() => tenantSql(seed, SCHOOL, ''), /DEMO_USER_ID/);
  assert.throws(() => timetableSql(seed, SCHOOL, 0), /SNAPSHOT_VERSION/);
  assert.throws(() => timetableSql(seed, SCHOOL, '1; drop'), /SNAPSHOT_VERSION/);
});
