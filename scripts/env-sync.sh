#!/usr/bin/env bash
# Синхронізує .env з .env.example: створює .env, якщо його немає, і дописує змінні,
# яких у .env бракує. Наявні значення не змінює ніколи.
# Використання: scripts/env-sync.sh [приклад] [ціль]   (типово .env.example і .env)
set -euo pipefail
example="${1:-.env.example}"
target="${2:-.env}"

[ -f "$example" ] || { echo "Немає файлу $example" >&2; exit 1; }

if [ ! -f "$target" ]; then
  cp "$example" "$target"
  echo "▶ Створено $target з $example"
  exit 0
fi

# Рядок, а не масив: bash 3.2 на macOS з set -u падає на порожньому масиві.
added=""
while IFS= read -r line || [ -n "$line" ]; do
  [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
  key="${BASH_REMATCH[1]}"
  grep -qE "^${key}=" "$target" && continue
  # Якщо файл не закінчується переносом рядка, новий рядок приклеївся б до останнього.
  if [ -z "$added" ] && [ -s "$target" ] && [ -n "$(tail -c1 "$target")" ]; then echo >> "$target"; fi
  [ -z "$added" ] && echo "# Додано з $example ($(date +%F))" >> "$target"
  printf '%s\n' "$line" >> "$target"
  added="${added:+$added }$key"
done < "$example"

if [ -z "$added" ]; then
  echo "▶ $target актуальний, нових змінних немає"
else
  echo "▶ Дописано в $target: $added"
fi
