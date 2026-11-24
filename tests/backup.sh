#!/usr/bin/env bash
# Перевірки ролі backup і make backup (scripts/backup.sh) на стенді lad-test.
# Аргумент — команда docker compose стенду, як у tests/db-init.sh. Потрібна утиліта age на хості.
set -euo pipefail
dc="$1"
set -a; . ./.env; set +a
pass=0; fail=0
ok()  { echo "  ✔ $1"; pass=$((pass + 1)); }
bad() { echo "  ✖ $1"; fail=$((fail + 1)); }
sql() { $dc exec -T postgres sh -c "psql -U \"\$POSTGRES_USER\" -v ON_ERROR_STOP=1 -tAq -d $1 -c \"$2\""; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "▶ backup"

# --- Роль backup: лише читання, але бачить усі заклади під FORCE RLS.
attrs="$(sql postgres "SELECT rolsuper::text || rolcreatedb::text || rolcreaterole::text || rolbypassrls::text FROM pg_roles WHERE rolname = 'backup'")"
[ "$attrs" = "falsefalsefalsetrue" ] && ok "роль backup: BYPASSRLS, без SUPERUSER, CREATEDB, CREATEROLE" || bad "атрибути ролі backup: «$attrs»"

# Таблиця з FORCE RLS і рядками двох закладів — як у сервісах.
sql tenant "SET client_min_messages TO warning; DROP TABLE IF EXISTS backup_probe; CREATE TABLE backup_probe (school_id uuid, note text);
  ALTER TABLE backup_probe ENABLE ROW LEVEL SECURITY; ALTER TABLE backup_probe FORCE ROW LEVEL SECURITY;
  CREATE POLICY probe ON backup_probe USING (school_id = NULLIF(current_setting('app.school_id', true), '')::uuid);
  INSERT INTO backup_probe VALUES ('11111111-1111-1111-1111-111111111111', 'probe-a'), ('22222222-2222-2222-2222-222222222222', 'probe-b');
  ALTER TABLE backup_probe OWNER TO tenant_owner;" >/dev/null
as_backup() { $dc exec -T -e PGPASSWORD="$BACKUP_DB_PASSWORD" postgres psql -h 127.0.0.1 -U backup -d tenant -tAq -c "$1" 2>&1; }

seen="$(as_backup "SELECT count(*) FROM backup_probe")"
[ "$seen" = "2" ] && ok "backup бачить рядки обох закладів під FORCE RLS" || bad "backup бачить рядків: «$seen»"
# Вивід спершу в змінну: з pipefail код помилки psql зіпсував би перевірку конвеєром.
denied="$(as_backup "INSERT INTO backup_probe VALUES ('11111111-1111-1111-1111-111111111111', 'x')" || true)"
if echo "$denied" | grep -qi 'permission denied'; then
  ok "backup не може писати"
else
  bad "backup зміг записати рядок"
fi

# --- make backup: ключ age лише для тесту.
if ! command -v age >/dev/null || ! command -v age-keygen >/dev/null; then
  bad "немає age на хості: brew install age (Mac) або sudo apt install age"
  echo "ℹ backup: пройдено $pass, не пройдено $fail"; exit 1
fi
age-keygen -o "$tmp/key.txt" 2>/dev/null
recipient="$(age-keygen -y "$tmp/key.txt")"
cp .env "$tmp/env"
{ echo "BACKUP_AGE_RECIPIENT=$recipient"; echo "BACKUP_DIR=$tmp/backups"; echo "BACKUP_RETENTION_DAYS=14"; } >> "$tmp/env"
container="$($dc ps -q postgres)"
run_backup() { LAD_ENV_FILE="$tmp/env" PG_CONTAINER="$container" bash scripts/backup.sh >"$tmp/out" 2>&1; }

# Стара копія за межами строку зберігання — make backup її прибирає.
mkdir -p "$tmp/backups/20000101T000000Z" && touch -t 200001010000 "$tmp/backups/20000101T000000Z"

if run_backup; then ok "make backup завершився успішно"; else bad "make backup впав: $(cat "$tmp/out")"; fi
latest="$(find "$tmp/backups" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z' ! -name '20000101T000000Z' | head -1)"
count="$(find "${latest:-$tmp/none}" -name '*.dump.age' 2>/dev/null | wc -l | tr -d ' ')"
[ "$count" = "4" ] && ok "4 копії: tenant, school, timetable, keycloak" || bad "файлів копій: $count"
[ ! -d "$tmp/backups/20000101T000000Z" ] && ok "копії старші за 14 днів видалено" || bad "стара копія лишилась"

if [ -n "$latest" ] && ! grep -qa 'probe-a' "$latest/tenant.dump.age"; then
  ok "копія зашифрована: даних закладу у файлі не видно"
else
  bad "у файлі копії видно дані відкритим текстом"
fi
restored="$( { age -d -i "$tmp/key.txt" "$latest/tenant.dump.age" | $dc exec -T postgres pg_restore -f - ; } 2>&1 || true)"
if echo "$restored" | grep -q 'probe-a' && echo "$restored" | grep -q 'probe-b'; then
  ok "приватним ключем копія розшифровується, pg_restore бачить рядки обох закладів"
else
  bad "копію не вдалося відновити"
fi

# Без ключа age копія не робиться.
echo "BACKUP_AGE_RECIPIENT=" >> "$tmp/env"
if run_backup; then bad "make backup без BACKUP_AGE_RECIPIENT пройшов"; else
  grep -q 'BACKUP_AGE_RECIPIENT' "$tmp/out" && ok "без BACKUP_AGE_RECIPIENT — зрозуміла помилка" || bad "помилка без назви змінної: $(cat "$tmp/out")"
fi

sql tenant "SET client_min_messages TO warning; DROP TABLE IF EXISTS backup_probe" >/dev/null
echo "ℹ backup: пройдено $pass, не пройдено $fail"
[ "$fail" -eq 0 ]
