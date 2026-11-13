#!/usr/bin/env bash
# make seed: завантажує демо-заклад із seed/demo-school.json у бази tenant, school і timetable
# (картка #21): дані закладу, QR і розклад від solver (чинна версія 1.1 та шаблон тривог 1.2).
# Потрібен стенд make up-apps: міграції сервісів мають бути застосовані.
# Ідемпотентно: повторний запуск повертає заклад і розклад до стану з файлів (задачі, публікації,
# активації тривог і заміни попереднього прогону демо прибираються); QR-токени не змінюються.
#
# Заклад — DEMO_SCHOOL_ID з .env; укладач — користувач demo з realm (той самий school_id).
# SQL друкує seed/sql.mjs у контейнері node:24 (Node на машині не потрібен), виконує psql
# у контейнері lad-postgres. Ролі й причини — у шапці seed/sql.mjs.
set -euo pipefail
set -a; . ./.env; set +a
: "${DEMO_SCHOOL_ID:?задайте DEMO_SCHOOL_ID у .env}"

fail() { echo "  ✖ $1" >&2; exit 1; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
# SQL з seed/sql.mjs для бази $1; змінні DEMO_* і SNAPSHOT_VERSION передаються з оточення.
gen() {
  docker run --rm -v "$PWD":/work:ro -w /work -e DEMO_SCHOOL_ID -e DEMO_USER_ID -e SNAPSHOT_VERSION \
    node:24-bookworm-slim node seed/sql.mjs "$1"
}
# psql роллю $2 до бази $3 з паролем $1; SQL — зі stdin.
psql_as() { docker exec -i -e PGPASSWORD="$1" lad-postgres psql -h 127.0.0.1 -U "$2" -d "$3" -v ON_ERROR_STOP=1 -qtA; }
psql_su() { docker exec lad-postgres psql -U "${POSTGRES_SUPERUSER:-postgres}" -v ON_ERROR_STOP=1 -qtA -d "$1" -c "$2"; }

echo "▶ сід демо-закладу (DEMO_SCHOOL_ID=$DEMO_SCHOOL_ID)"
running lad-postgres && running lad-keycloak || fail "немає lad-postgres або lad-keycloak — спершу make up-apps"
for check in "tenant schools" "school curriculum" "timetable school_state"; do
  set -- $check
  [ "$(psql_su "$1" "select to_regclass('public.$2') is not null")" = "t" ] \
    || fail "у базі $1 немає таблиці $2 — міграції не застосовано (make up-apps)"
done

# id користувача demo в Keycloak: реєстр tenant зберігає його як scheduler_user_id.
DEMO_USER_ID="$(docker exec lad-keycloak bash -c '/opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm.config \
  --server http://localhost:8080/idp --realm master --user admin --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null \
  && /opt/keycloak/bin/kcadm.sh get users -r lad --config /tmp/kcadm.config -q username=demo -q exact=true \
       --fields id --format csv --noquotes' | tr -d '\r')"
[[ "$DEMO_USER_ID" =~ ^[0-9a-f-]{36}$ ]] || fail "користувача demo в realm lad не знайдено (make kc-reset?)"
export DEMO_SCHOOL_ID DEMO_USER_ID

gen tenant | psql_as "$TENANT_OWNER_DB_PASSWORD" tenant_owner tenant
SNAPSHOT_VERSION="$(gen school | psql_as "$SCHOOL_APP_DB_PASSWORD" school_app school | tail -n1)"
[[ "$SNAPSHOT_VERSION" =~ ^[0-9]+$ ]] || fail "school не повернула snapshot_version"
export SNAPSHOT_VERSION
gen timetable | psql_as "$TIMETABLE_APP_DB_PASSWORD" timetable_app timetable

# Перевірка: усе з файлу на місці, snapshot_version однаковий у school і timetable.
read -r classes subjects teachers rows bells tokens main_lessons main_formats alert_lessons alert_bells < <(gen counts)
id="'$DEMO_SCHOOL_ID'"
pass=0; bad=0
expect() {
  if [ "$2" = "$3" ]; then echo "  ✔ $1"; pass=$((pass + 1)); else echo "  ✖ $1: очікувалось $3, є $2"; bad=$((bad + 1)); fi
}
expect "tenant: заклад у реєстрі, укладач demo" \
  "$(psql_su tenant "select scheduler_login || ' ' || scheduler_user_id from schools where school_id = $id")" "demo $DEMO_USER_ID"
expect "school: $classes класів, $subjects предметів, $teachers вчителів, $rows рядків плану, $bells дзвінків" \
  "$(psql_su school "select concat_ws(' ',
     (select count(*) from classes where school_id = $id and archived_at is null),
     (select count(*) from subjects where school_id = $id and archived_at is null),
     (select count(*) from teachers where school_id = $id and deleted_at is null),
     (select count(*) from curriculum where school_id = $id),
     (select count(*) from bells where school_id = $id))")" "$classes $subjects $teachers $rows $bells"
expect "timetable: «Стан закладу» з тим самим snapshot_version ($SNAPSHOT_VERSION)" \
  "$(psql_su timetable "select known_snapshot_version from school_state where school_id = $id")" "$SNAPSHOT_VERSION"
expect "timetable: $tokens активних QR (класи й вчителі)" \
  "$(psql_su timetable "select count(*) from access_tokens where school_id = $id and revoked_at is null")" "$tokens"
expect "timetable: чинна версія 1.1 опублікована, $main_lessons уроків, $main_formats форматів днів, той самий snapshot_version" \
  "$(psql_su timetable "select concat_ws(' ', t.state, t.effective_from <= current_date, t.snapshot_version,
     (select count(*) from lessons l where l.timetable_id = t.timetable_id),
     (select count(*) from day_formats f where f.timetable_id = t.timetable_id))
     from timetables t where t.school_id = $id and t.kind = 'main'")" "published t $SNAPSHOT_VERSION $main_lessons $main_formats"
expect "timetable: шаблон тривог 1.2 ($alert_lessons уроків), план — чернетка, $alert_bells дзвінків тривог" \
  "$(psql_su timetable "select concat_ws(' ', p.state,
     (select count(*) from lessons l where l.timetable_id = p.timetable_id),
     (select count(*) from alert_bells b where b.school_id = $id))
     from alert_plan p where p.school_id = $id")" "draft $alert_lessons $alert_bells"
echo "ℹ сід: пройдено $pass, не пройдено $bad"
[ "$bad" -eq 0 ]
