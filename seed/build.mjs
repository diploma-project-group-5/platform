// Збирає сід-файл демо-закладу (картка #21) із синтетичної школи генератора solver.
//
// Вхід — seed/solver-problem.json: вивід `lad-solver generate --classes 30 --shelter-ratio 0.55
// --seed 0` (репозиторій solver). Той самий файл бере solver для чинної версії розкладу (#72),
// тож ідентифікатори обох файлів відповідають один одному: UUID тут — це UUIDv5 від id генератора.
//
// Вихід — seed/demo-school.json у термінах наших сервісів: профіль, дзвінки, класи, предмети,
// вчителі й план у тих полях і обмеженнях, що й таблиці school-service. Дані вигадані, ПД немає:
// підпис вчителя — назва предмета з номером («Математика-2»).
//
// Запуск: node seed/build.mjs   (перезаписує seed/demo-school.json; тест seed.test.mjs
// перевіряє, що закомічений файл збігається з виходом цього скрипта).
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// Простір імен UUIDv5 сіду «Лад». Не змінювати: від нього залежать id у БД і в артефакті solver.
export const NAMESPACE = '2f6b1c7e-4d0a-4c55-9a3e-6e1d8b7f0c21';

/** UUIDv5 (RFC 9562) з рядка в просторі імен NAMESPACE. */
export function uuid5(name) {
  const ns = Buffer.from(NAMESPACE.replaceAll('-', ''), 'hex');
  const h = createHash('sha1').update(ns).update(name, 'utf8').digest();
  h[6] = (h[6] & 0x0f) | 0x50;
  h[8] = (h[8] & 0x3f) | 0x80;
  const x = h.subarray(0, 16).toString('hex');
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}

// id генератора → назва, скорочення, освітня галузь (enum school-service).
export const SUBJECTS = {
  ukr_lang: ['Українська мова', 'Укр. мова', 'language_literature'],
  ukr_lit: ['Українська література', 'Укр. літ.', 'language_literature'],
  foreign_lang: ['Англійська мова', 'Англ. мова', 'language_literature'],
  foreign_lit: ['Зарубіжна література', 'Зар. літ.', 'language_literature'],
  math: ['Математика', 'Матем.', 'math'],
  algebra: ['Алгебра', 'Алгебра', 'math'],
  geometry: ['Геометрія', 'Геометр.', 'math'],
  explore_world: ['Я досліджую світ', 'ЯДС', 'science'],
  science: ['Пізнаємо природу', 'Природа', 'science'],
  biology: ['Біологія', 'Біол.', 'science'],
  geography: ['Географія', 'Геогр.', 'science'],
  physics: ['Фізика', 'Фізика', 'science'],
  chemistry: ['Хімія', 'Хімія', 'science'],
  history: ['Історія', 'Історія', 'civic_history'],
  civics: ['Громадянська освіта', 'Гром. осв.', 'civic_history'],
  informatics: ['Інформатика', 'Інформ.', 'informatics'],
  arts: ['Мистецтво', 'Мист.', 'arts'],
  technology: ['Технології', 'Технол.', 'technology'],
  health: ["Здоров'я, безпека та добробут", 'ЗБД', 'social_health'],
  physical_education: ['Фізична культура', 'Фізкульт.', 'physical'],
};

const LETTERS = 'АБВГДЕ';

// Основні дзвінки на 7 уроків (перерви 10 і 20 хв).
export const BELLS = [
  ['08:30', '09:15'],
  ['09:25', '10:10'],
  ['10:30', '11:15'],
  ['11:35', '12:20'],
  ['12:30', '13:15'],
  ['13:25', '14:10'],
  ['14:20', '15:05'],
];

// Облаштовані навчальні місця від паспортної місткості (як SEATS_SHARE у генераторі).
const SEATS_SHARE = 0.9;

/** «c05-b» → «5-Б». */
function className(id) {
  const m = /^c(\d\d)-([a-z])$/.exec(id);
  if (!m) throw new Error(`невідомий id класу ${id}`);
  return `${Number(m[1])}-${LETTERS[m[2].charCodeAt(0) - 97]}`;
}

/** Підпис вчителя за його основним предметом: «Математика-2», «Початкові класи-3». */
function teacherLabels(problem) {
  const rows = problem.rows;
  const counter = {};
  const labels = {};
  for (const t of problem.teachers) {
    const mine = rows.filter((r) => r.teacher_id === t.id);
    const hours = {};
    for (const r of mine) hours[r.subject_id] = (hours[r.subject_id] ?? 0) + r.hours;
    const main = Object.entries(hours).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))[0]?.[0];
    const base = hours.explore_world ? 'Початкові класи' : main ? SUBJECTS[main][0] : 'Вчитель';
    counter[base] = (counter[base] ?? 0) + 1;
    labels[t.id] = `${base}-${counter[base]}`;
  }
  return labels;
}

export function build(problem) {
  if (problem.kind !== 'main') throw new Error('потрібна задача kind=main');
  for (const s of problem.subjects) if (!SUBJECTS[s.id]) throw new Error(`немає назви для предмета ${s.id}`);
  const labels = teacherLabels(problem);
  const passport = problem.capacity.passport;
  return {
    source: {
      generator: 'lad-solver generate --classes 30 --shelter-ratio 0.55 --seed 0',
      problem: 'seed/solver-problem.json',
      uuid_namespace: NAMESPACE,
    },
    profile: {
      name: 'Ліцей № 17',
      lessons_per_day: problem.lessons_per_day,
      saturday: problem.school_days.includes(6),
      shelter_capacity: passport,
      non_teaching_staff: problem.staff,
      shelter_seats: Math.round(SEATS_SHARE * passport),
    },
    bells: BELLS.slice(0, problem.lessons_per_day).map(([starts_at, ends_at], i) => ({
      lesson_no: i + 1,
      starts_at,
      ends_at,
    })),
    holidays: { from: '2026-12-25', to: '2027-01-11' },
    classes: problem.classes.map((c) => ({
      class_id: uuid5(`class:${c.id}`),
      source_id: c.id,
      name: className(c.id),
      students: c.students,
      in_person_priority: c.priority,
    })),
    subjects: problem.subjects.map((s) => ({
      subject_id: uuid5(`subject:${s.id}`),
      source_id: s.id,
      name: SUBJECTS[s.id][0],
      short_name: SUBJECTS[s.id][1],
      education_area: SUBJECTS[s.id][2],
      not_in_shelter: s.no_shelter,
    })),
    teachers: problem.teachers.map((t, i) => ({
      teacher_id: uuid5(`teacher:${t.id}`),
      source_id: t.id,
      teacher_no: i + 1,
      label: labels[t.id],
      weekly_hours_limit: t.weekly_limit,
      unavailable_days: t.unavailable_days,
    })),
    curriculum: problem.rows.map((r) => ({
      class_id: uuid5(`class:${r.class_id}`),
      subject_id: uuid5(`subject:${r.subject_id}`),
      teacher_id: uuid5(`teacher:${r.teacher_id}`),
      hours_per_week: r.hours,
    })),
  };
}

export const PROBLEM_PATH = new URL('./solver-problem.json', import.meta.url);
export const SEED_PATH = new URL('./demo-school.json', import.meta.url);

export function render(problem) {
  return `${JSON.stringify(build(problem), null, 2)}\n`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  writeFileSync(SEED_PATH, render(JSON.parse(readFileSync(PROBLEM_PATH, 'utf8'))));
  console.log(`▶ ${fileURLToPath(SEED_PATH)} оновлено`);
}
