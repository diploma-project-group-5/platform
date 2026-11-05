#!/usr/bin/env bash
# Створює ролі й бази на спільному сервері PostgreSQL.
# Запускається контейнером db-init при кожному make up, тому ідемпотентний:
# повторний запуск нічого не ламає й лише синхронізує паролі з .env.
set -euo pipefail

psql_admin() { psql -v ON_ERROR_STOP=1 -q -d postgres "$@"; }

# Роль з LOGIN без зайвих прав; пароль завжди синхронізується з .env.
ensure_role() {
  local role="$1" password="$2"
  psql_admin -v role="$role" -v pass="$password" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L', :'role', :'pass') \gexec
SQL
}

# База з власником; під'єднуватися можуть лише перелічені ролі.
ensure_database() {
  local db="$1" owner="$2"; shift 2
  psql_admin -v db="$db" -v owner="$owner" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'owner')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec
SQL
  for role in "$@"; do
    psql_admin -v db="$db" -v role="$role" <<'SQL'
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db', :'role') \gexec
SQL
  done
}

# Сервіс за схемою розділу 03: <svc>_owner (міграції), <svc>_app (DML), <svc>_relay (outbox),
# <svc>_maint (фонові задачі). Паролі — змінні <SVC>_<РОЛЬ>_DB_PASSWORD у .env.
service_database() {
  local svc="$1" upper kind var password
  upper="$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')"
  for kind in owner app relay maint; do
    var="${upper}_$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD"
    password="${!var:-}"
    [ -n "$password" ] || { echo "db-init: задайте $var у .env" >&2; exit 1; }
    ensure_role "${svc}_${kind}" "$password"
  done
  ensure_database "$svc" "${svc}_owner" "${svc}_app" "${svc}_relay" "${svc}_maint"
}

# --- Keycloak: власна роль і база ---
: "${KEYCLOAK_DB_PASSWORD:?задайте KEYCLOAK_DB_PASSWORD у .env}"
ensure_role keycloak "$KEYCLOAK_DB_PASSWORD"
ensure_database keycloak keycloak

# --- Сервіси ---
# school і timetable додаються сюди одним рядком кожен, разом з паролями в .env і docker-compose.yml.
service_database tenant

echo "db-init: OK"
