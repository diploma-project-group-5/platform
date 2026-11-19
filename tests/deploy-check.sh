#!/usr/bin/env bash
# Перевірки scripts/deploy.sh --check (make deploy): .env для ВМ без доменних налаштувань і з
# паролями з прикладу не проходить, правильно заповнений — проходить; шаблон Traefik цілий.
# Docker не потрібен.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "  ✔ $1"; pass=$((pass + 1)); }
bad() { echo "  ✖ $1"; fail=$((fail + 1)); }

echo "▶ make deploy (scripts/deploy.sh --check)"

# .env.example як є: локальні паролі й порожній домен.
out="$(bash scripts/deploy.sh --check .env.example 2>&1)" && bad ".env.example прийнято для ВМ" || ok ".env.example для ВМ не проходить"
for what in LAD_DOMAIN ACME_EMAIL LAD_PUBLIC_URL COMPOSE_FILE COMPOSE_PROFILES QR_HMAC_SECRET POSTGRES_SUPERUSER_PASSWORD SCHOOL_APP_DB_PASSWORD BACKUP_AGE_RECIPIENT; do
  echo "$out" | grep -q "$what" && ok "називає $what" || bad "не назвав $what: $out"
done

# Правильний .env для ВМ: приклад + домен, https, файли compose, профілі й свої паролі.
cp .env.example "$tmp/vm.env"
while IFS='=' read -r key value; do
  [[ "$key" =~ (PASSWORD|SECRET)$ ]] || continue
  sed -i.bak "s|^$key=.*|$key=vm-$(printf '%s' "$key" | tr 'A-Z_' 'a-z-')-0123456789abcdef0123456789|" "$tmp/vm.env"
done < <(grep -E '^[A-Z_][A-Z0-9_]*=' .env.example)
{
  echo "LAD_DOMAIN=lad.example.org"
  echo "ACME_EMAIL=team@example.org"
  echo "LAD_PUBLIC_URL=https://lad.example.org"
  echo "COMPOSE_FILE=docker-compose.yml:docker-compose.vm.yml"
  echo "COMPOSE_PROFILES=apps,solver"
  echo "BACKUP_AGE_RECIPIENT=age1$(printf 'q%.0s' $(seq 58))"
} >> "$tmp/vm.env"
out="$(bash scripts/deploy.sh --check "$tmp/vm.env" 2>&1)" && ok "заповнений .env для ВМ проходить" || bad "заповнений .env відхилено: $out"

sed -i.bak 's|^LAD_PUBLIC_URL=https://lad.example.org$|LAD_PUBLIC_URL=http://lad.example.org|' "$tmp/vm.env"
bash scripts/deploy.sh --check "$tmp/vm.env" >/dev/null 2>&1 && bad "http замість https прийнято" || ok "LAD_PUBLIC_URL на http — не проходить"

# Шаблон Traefik: обидві підстановки є, а вхідна точка web — та сама, на яку посилаються маршрути.
grep -q '__LAD_DOMAIN__' traefik/traefik.vm.yml.tmpl && grep -q '__ACME_EMAIL__' traefik/traefik.vm.yml.tmpl \
  && ok "шаблон traefik.vm.yml.tmpl з __LAD_DOMAIN__ і __ACME_EMAIL__" || bad "у шаблоні немає підстановок"
grep -qE '^  web:$' traefik/traefik.vm.yml.tmpl && grep -q 'address: ":443"' traefik/traefik.vm.yml.tmpl \
  && ok "вхідна точка web на ВМ — :443 (маршрути routes.yml без змін)" || bad "web у шаблоні не на :443"
for opt in 'aliasHeadersStrategy: delete' 'allowEncodedSlash: false' 'allowEncodedSemicolon: false'; do
  grep -q "$opt" traefik/traefik.vm.yml.tmpl && ok "захист як у traefik.yml: $opt" || bad "у шаблоні немає $opt"
done

echo "ℹ deploy-check: пройдено $pass, не пройдено $fail"
[ "$fail" -eq 0 ]
