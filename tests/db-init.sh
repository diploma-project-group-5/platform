#!/usr/bin/env bash
# Перевірки db-init (картка #18). Викликається з make test на стенді lad-test.
# Аргумент — команда docker compose стенду, наприклад:
#   tests/db-init.sh "docker compose -p lad-test -f docker-compose.yml -f docker-compose.test.yml"
set -euo pipefail
dc="$1"
# Ті самі паролі, що бачить compose.
set -a; . ./.env; set +a
pass=0; fail=0
ok()  { echo "  ✔ $1"; pass=$((pass + 1)); }
bad() { echo "  ✖ $1"; fail=$((fail + 1)); }
sql() { $dc exec -T postgres sh -c "psql -U \"\$POSTGRES_USER\" -d postgres -tAc \"$1\""; }

echo "▶ db-init"

if $dc run --rm -T db-init >/dev/null 2>&1; then ok "повторний запуск db-init проходить (ідемпотентний)"; else bad "повторний запуск db-init впав"; fi

attrs="$(sql "SELECT rolsuper::text || rolbypassrls::text || rolcreatedb::text FROM pg_roles WHERE rolname = 'keycloak'")"
[ "$attrs" = "falsefalsefalse" ] && ok "роль keycloak без SUPERUSER, BYPASSRLS, CREATEDB" || bad "роль keycloak має зайві права: $attrs"

owner="$(sql "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'keycloak'")"
[ "$owner" = "keycloak" ] && ok "база keycloak належить ролі keycloak" || bad "власник бази keycloak: $owner"

# Сервіси з базами (розділ 03): ролі без зайвих прав, власник бази, вхід робочої ролі з паролем з .env.
services="tenant school timetable"
for svc in $services; do
  roles="$(sql "SELECT count(*) FROM pg_roles WHERE rolname IN ('${svc}_owner','${svc}_app','${svc}_relay','${svc}_maint') AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreatedb AND NOT rolcreaterole")"
  [ "$roles" = "4" ] && ok "ролі ${svc}_owner, _app, _relay, _maint без зайвих прав" || bad "ролей $svc без зайвих прав: $roles із 4"

  owner="$(sql "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$svc'")"
  [ "$owner" = "${svc}_owner" ] && ok "база $svc належить ролі ${svc}_owner" || bad "власник бази $svc: $owner"

  var="$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')_APP_DB_PASSWORD"
  if $dc exec -T -e PGPASSWORD="${!var}" postgres psql -h 127.0.0.1 -U "${svc}_app" -d "$svc" -c "SELECT 1" >/dev/null 2>&1; then
    ok "${svc}_app під'єднується до бази $svc з паролем з .env"
  else
    bad "${svc}_app не під'єднується до бази $svc"
  fi
done

# Межу між сервісами тримає СУБД: робоча роль одного сервісу не під'єднується до бази іншого.
if $dc exec -T -e PGPASSWORD="$SCHOOL_APP_DB_PASSWORD" postgres psql -h 127.0.0.1 -U school_app -d timetable -c "SELECT 1" >/dev/null 2>&1; then
  bad "school_app під'єднується до бази timetable"
else
  ok "school_app не під'єднується до бази timetable"
fi
if $dc exec -T -e PGPASSWORD="$TIMETABLE_APP_DB_PASSWORD" postgres psql -h 127.0.0.1 -U timetable_app -d tenant -c "SELECT 1" >/dev/null 2>&1; then
  bad "timetable_app під'єднується до бази tenant"
else
  ok "timetable_app не під'єднується до бази tenant"
fi

# Міграції timetable створюють btree_gist (EXCLUDE для активацій). Це довірене розширення:
# власник бази створює його без суперкористувача.
if $dc exec -T -e PGPASSWORD="$TIMETABLE_OWNER_DB_PASSWORD" postgres psql -h 127.0.0.1 -U timetable_owner -d timetable -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS btree_gist" >/dev/null 2>&1; then
  ok "timetable_owner створює розширення btree_gist у своїй базі"
else
  bad "timetable_owner не може створити btree_gist"
fi

sql "SET client_min_messages = warning; DROP ROLE IF EXISTS lad_probe; CREATE ROLE lad_probe LOGIN PASSWORD 'probe-pass-123'" >/dev/null
for db in keycloak $services; do
  if $dc exec -T -e PGPASSWORD=probe-pass-123 postgres psql -h 127.0.0.1 -U lad_probe -d "$db" -c "SELECT 1" >/dev/null 2>&1; then
    bad "стороння роль під'єднується до бази $db"
  else
    ok "стороння роль не під'єднується до бази $db"
  fi
done
sql "DROP ROLE lad_probe" >/dev/null

echo "ℹ db-init: пройдено $pass, не пройдено $fail"
[ "$fail" -eq 0 ]
