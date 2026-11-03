#!/usr/bin/env bash
# Створює ролі й бази на спільному сервері PostgreSQL.
# Запускається контейнером db-init при кожному make up, тому ідемпотентний:
# повторний запуск нічого не ламає й лише синхронізує паролі з .env.
#
# Зараз тут лише база Keycloak (картка #18). Бази й ролі сервісів
# (<svc>_owner, <svc>_app, <svc>_relay, <svc>_maint, backup) додає картка
# «[каркас] Схеми й користувачі БД на кожен сервіс» за тим самим зразком.
set -euo pipefail

: "${KEYCLOAK_DB_PASSWORD:?задайте KEYCLOAK_DB_PASSWORD у .env}"

psql -v ON_ERROR_STOP=1 -q -d postgres -v kc_pass="$KEYCLOAK_DB_PASSWORD" <<'SQL'
-- Keycloak: власна роль і база; інші ролі до неї не під'єднуються.
SELECT format('CREATE ROLE keycloak LOGIN PASSWORD %L', :'kc_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak') \gexec
ALTER ROLE keycloak WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD :'kc_pass';

SELECT 'CREATE DATABASE keycloak OWNER keycloak'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak') \gexec
REVOKE ALL ON DATABASE keycloak FROM PUBLIC;
SQL

echo "db-init: OK"
