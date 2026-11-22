#!/usr/bin/env bash
# make deploy: стенд на ВМ (platform #18, #19, #20, #13). Запускається на ВМ у папці platform,
# поруч — клони tenant-service, school-service, timetable-service, frontend і solver.
#
#   scripts/deploy.sh            перевірити .env, оновити клони, solver на SOLVER_REF, зібрати й підняти
#                                стенд з HTTPS, make smoke
#   scripts/deploy.sh --seed     те саме + make seed (демо-заклад з нуля) перед smoke
#   scripts/deploy.sh --check F  лише перевірити файл F як .env для ВМ (так його перевіряють тести)
#
# Сам platform скрипт не оновлює (bash читає скрипт по ходу виконання): спершу git pull, потім make deploy.
set -euo pipefail
cd "$(dirname "$0")/.."

# Перевірка .env для ВМ. Друкує всі проблеми одразу, а не по одній.
check_env() {
  local file="$1" problems=0
  # Читаємо у підоболонці: значення з файлу не змішуються з оточенням скрипта.
  local report
  report="$(
    set -a; . "$file"; set +a
    p() { echo "  ✖ $1"; }
    [[ "${LAD_DOMAIN:-}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
      || p "LAD_DOMAIN — домен ВМ, наприклад lad.duckdns.org або 203-0-113-7.sslip.io (зараз «${LAD_DOMAIN:-}»)"
    [[ "${ACME_EMAIL:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
      || p "ACME_EMAIL — пошта для Let's Encrypt (зараз «${ACME_EMAIL:-}»)"
    [ "${LAD_PUBLIC_URL:-}" = "https://${LAD_DOMAIN:-}" ] \
      || p "LAD_PUBLIC_URL має бути https://${LAD_DOMAIN:-<LAD_DOMAIN>} (зараз «${LAD_PUBLIC_URL:-}»)"
    [ "${COMPOSE_FILE:-}" = "docker-compose.yml:docker-compose.vm.yml" ] \
      || p "COMPOSE_FILE=docker-compose.yml:docker-compose.vm.yml (зараз «${COMPOSE_FILE:-}»)"
    [[ ",${COMPOSE_PROFILES:-}," == *",apps,"* && ",${COMPOSE_PROFILES:-}," == *",solver,"* ]] \
      || p "COMPOSE_PROFILES=apps,solver (зараз «${COMPOSE_PROFILES:-}»)"
    [ -n "${SOLVER_REF:-}" ] || p "SOLVER_REF — тег solver для показу, наприклад v0.4.0"
    [[ "${BACKUP_AGE_RECIPIENT:-}" =~ ^age1[0-9a-z]{58}$ ]] \
      || p "BACKUP_AGE_RECIPIENT — публічний ключ age для копій (age-keygen, рядок «Public key: age1…»)"
    qr="${QR_HMAC_SECRET:-}"
    [ "${#qr}" -ge 32 ] || p "QR_HMAC_SECRET — щонайменше 32 символи: openssl rand -base64 48"
    # Паролі з .env.example відомі всім, хто бачив репозиторій: на ВМ — лише свої.
    while IFS='=' read -r key _; do
      [[ "$key" =~ ^[A-Z_][A-Z0-9_]*(PASSWORD|SECRET)$ ]] || continue
      value="${!key:-}"
      if [ -z "$value" ] || [[ "$value" == local-* || "$value" == *change-me* ]]; then
        p "$key — замініть значення з прикладу на своє: openssl rand -hex 24"
      elif [[ "$key" == *DB_PASSWORD && ! "$value" =~ ^[A-Za-z0-9_-]+$ ]]; then
        p "$key — лише літери, цифри, - і _ (пароль потрапляє в URL підключення)"
      fi
    done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$file")
  )" || true
  if [ -n "$report" ]; then
    echo "✖ $file не готовий для ВМ:"; echo "$report"
    problems=1
  fi
  return "$problems"
}

if [ "${1:-}" = "--check" ]; then
  check_env "${2:?вкажіть файл: --check <файл>}" && echo "✔ ${2} готовий для ВМ"
  exit $?
fi
seed=0; [ "${1:-}" = "--seed" ] && seed=1

echo "▶ make deploy"
check_env .env || { echo "Виправте .env (README, «Розгортання на ВМ») і запустіть make deploy знову."; exit 1; }
set -a; . ./.env; set +a

# 1. Клони сервісів: тег або гілка з *_REF у .env (TENANT_REF=v1.0.0), інакше свіжий стан поточної
#    гілки клону; solver — завжди закріплений тег SOLVER_REF. validator-lib і contracts окремих клонів
#    не мають: їхні версії закріплено в package.json сервісів.
pin() {
  local src="$1" ref="$2"
  if [ -n "$ref" ]; then
    echo "  ⟳ $src → $ref"
    git -C "$src" fetch --tags --quiet
    git -C "$src" -c advice.detachedHead=false checkout --quiet "$ref"
    # Гілка (а не тег) — підтягнути її свіжий стан.
    git -C "$src" symbolic-ref -q HEAD >/dev/null && git -C "$src" pull --ff-only --quiet
  else
    echo "  ⟳ $src ($(git -C "$src" rev-parse --abbrev-ref HEAD))"
    git -C "$src" pull --ff-only --quiet
  fi
  echo "    $(git -C "$src" describe --tags --always)"
}
pin "${TENANT_SRC:-../tenant-service}" "${TENANT_REF:-}"
pin "${SCHOOL_SRC:-../school-service}" "${SCHOOL_REF:-}"
pin "${TIMETABLE_SRC:-../timetable-service}" "${TIMETABLE_REF:-}"
pin "${WEB_SRC:-../frontend}" "${WEB_REF:-}"
echo "  ⟳ ${SOLVER_SRC:-../solver} → $SOLVER_REF"
git -C "${SOLVER_SRC:-../solver}" fetch --tags --quiet
git -C "${SOLVER_SRC:-../solver}" -c advice.detachedHead=false checkout --quiet "$SOLVER_REF"

# 2. Статична конфігурація Traefik з HTTPS для цього домену.
sed -e "s|__LAD_DOMAIN__|$LAD_DOMAIN|g" -e "s|__ACME_EMAIL__|$ACME_EMAIL|g" \
  traefik/traefik.vm.yml.tmpl > traefik/traefik.vm.yml
echo "  ✔ traefik/traefik.vm.yml для $LAD_DOMAIN"
# Журнал шлюзу з IP — лише з правилом logrotate на 30 днів (рішення 05). Ставиться один раз: make logrotate.
bash scripts/logrotate.sh --check || exit 1
mkdir -p logs/traefik

# 3. Збірка й підйом (COMPOSE_FILE і COMPOSE_PROFILES — з .env).
docker compose up -d --wait --build --remove-orphans

# 4. Демо-заклад (лише з --seed: повертає дані закладу до файлу) і наскрізна перевірка.
[ "$seed" = 1 ] && bash scripts/seed.sh
bash tests/smoke.sh

echo "▶ Готово: $LAD_PUBLIC_URL"
