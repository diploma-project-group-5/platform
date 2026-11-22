#!/usr/bin/env bash
# make logrotate: правило logrotate для журналу запитів шлюзу на ВМ (IP — не довше 30 днів).
# Ставиться один раз через sudo в /etc/logrotate.d/lad-traefik; системний logrotate запускає його щодня.
#   bash scripts/logrotate.sh          — поставити або оновити правило (питає пароль sudo)
#   bash scripts/logrotate.sh --check  — лише перевірити, що стоїть актуальне правило (make deploy)
# LOGROTATE_FILE змінює шлях правила (для тестів).
set -euo pipefail
cd "$(dirname "$0")/.."
dir="$(pwd)/logs/traefik"
target="${LOGROTATE_FILE:-/etc/logrotate.d/lad-traefik}"
rendered="$(sed "s|__LOG_DIR__|$dir|g" deploy/logrotate-traefik.tmpl)"

if [ "${1:-}" = "--check" ]; then
  if [ -f "$target" ] && [ "$(cat "$target")" = "$rendered" ]; then
    echo "  ✔ logrotate: журнал шлюзу зберігається 30 днів ($target)"
    exit 0
  fi
  echo "  ✖ немає актуального правила logrotate для журналу шлюзу ($target)." >&2
  echo "    IP відвідувачів мають зберігатися не довше 30 днів: один раз запустіть make logrotate (потрібен sudo)." >&2
  exit 1
fi

command -v logrotate >/dev/null || { echo "✖ немає logrotate: sudo apt install logrotate" >&2; exit 1; }
mkdir -p "$dir"
printf '%s\n' "$rendered" | sudo tee "$target" >/dev/null
sudo chmod 644 "$target"
# Сухий прогін: logrotate перевіряє синтаксис правила, нічого не ротуючи.
sudo logrotate -d "$target" >/dev/null 2>&1 || { echo "✖ logrotate не прийняв правило $target" >&2; exit 1; }
echo "✔ logrotate: $target — журнал $dir/access.log, 30 днів"
