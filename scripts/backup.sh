#!/usr/bin/env bash
# make backup: зашифровані копії баз tenant, school, timetable і keycloak (розділ 03, рішення «Резервні копії»).
# Дамп робить роль backup (лише читання, BYPASSRLS) утилітою pg_dump того самого контейнера PostgreSQL,
# одразу шифрує публічним ключем age і кладе в BACKUP_DIR/<час UTC>/<база>.dump.age.
# Розшифрувати можна лише приватним ключем, якого на ВМ немає. Копії старші за
# BACKUP_RETENTION_DAYS днів видаляються. На ВМ запускається щодня з cron (README «Резервні копії»).
#
# Змінні беруться з .env (або з файлу LAD_ENV_FILE): BACKUP_DB_PASSWORD, BACKUP_AGE_RECIPIENT,
# BACKUP_DIR (./backups), BACKUP_RETENTION_DAYS (14), PG_CONTAINER (lad-postgres).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . "${LAD_ENV_FILE:-./.env}"; set +a

container="${PG_CONTAINER:-lad-postgres}"
dir="${BACKUP_DIR:-./backups}"
keep="${BACKUP_RETENTION_DAYS:-14}"
recipient="${BACKUP_AGE_RECIPIENT:-}"
databases=(tenant school timetable keycloak)

command -v age >/dev/null \
  || { echo "✖ немає утиліти age: brew install age (Mac) або sudo apt install age (ВМ)" >&2; exit 1; }
[[ "$recipient" =~ ^age1[0-9a-z]{58}$ ]] \
  || { echo "✖ BACKUP_AGE_RECIPIENT у .env — публічний ключ age (age-keygen -o lad-backup.key, рядок «Public key: age1…»)" >&2; exit 1; }
[ -n "${BACKUP_DB_PASSWORD:-}" ] || { echo "✖ задайте BACKUP_DB_PASSWORD у .env" >&2; exit 1; }
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || { echo "✖ BACKUP_RETENTION_DAYS — ціле число днів (зараз «$keep»)" >&2; exit 1; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="$dir/$stamp"
mkdir -p "$target"
# Збій посередині не лишає напівготової копії: каталог прибирається, а код завершення — не 0.
trap 'rm -rf "$target"' ERR

echo "▶ make backup → $target"
for db in "${databases[@]}"; do
  docker exec -e PGPASSWORD="$BACKUP_DB_PASSWORD" "$container" \
      pg_dump -h 127.0.0.1 -U backup -d "$db" --format=custom \
    | age -r "$recipient" -o "$target/$db.dump.age.tmp"
  mv "$target/$db.dump.age.tmp" "$target/$db.dump.age"
  echo "  ✔ $db: $(wc -c < "$target/$db.dump.age" | tr -d ' ') байт"
done
trap - ERR

# Строк зберігання: каталоги копій (імена — час UTC) старші за keep днів.
removed=0
while IFS= read -r old; do
  rm -rf "$old"; removed=$((removed + 1))
done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z' -mtime +"$keep")
[ "$removed" -eq 0 ] || echo "  ℹ видалено копій старших за $keep днів: $removed"
echo "▶ Готово"
