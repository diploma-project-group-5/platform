#!/usr/bin/env bash
# Перевірки db-init (картка #18). Викликається з make test на стенді lad-test.
# Аргумент — команда docker compose стенду, наприклад:
#   tests/db-init.sh "docker compose -p lad-test -f docker-compose.yml -f docker-compose.test.yml"
set -euo pipefail
dc="$1"
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

sql "DROP ROLE IF EXISTS lad_probe; CREATE ROLE lad_probe LOGIN PASSWORD 'probe-pass-123'" >/dev/null
if $dc exec -T -e PGPASSWORD=probe-pass-123 postgres psql -h 127.0.0.1 -U lad_probe -d keycloak -c "SELECT 1" >/dev/null 2>&1; then
  bad "стороння роль під'єднується до бази keycloak"
else
  ok "стороння роль не під'єднується до бази keycloak"
fi
sql "DROP ROLE lad_probe" >/dev/null

echo "ℹ db-init: пройдено $pass, не пройдено $fail"
[ "$fail" -eq 0 ]
