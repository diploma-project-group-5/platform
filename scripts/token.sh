#!/usr/bin/env bash
# Отримати справжній access-токен користувача realm lad так само, як його отримує браузер:
# вхід через шлюз, код авторизації з PKCE, клієнт web. Для перевірки своїх API через curl.
#
#   scripts/token.sh <логін> <пароль> [публічна-адреса]
#   make token                       # демо-укладач із .env
#   make token u=sysadmin p=...      # будь-який користувач
#
# Друкує лише токен, тож його зручно підставляти:
#   curl -H "Authorization: Bearer $(make -s token)" http://localhost/api/v1/school/...
set -euo pipefail

user="${1:?логін}"
pass="${2:?пароль}"
base="${3:-${LAD_PUBLIC_URL:-http://localhost}}"
realm="$base/idp/realms/lad/protocol/openid-connect"
redirect="$base/cb"

jar="$(mktemp)"; hdr="$(mktemp)"; body="$(mktemp)"
trap 'rm -f "$jar" "$hdr" "$body"' EXIT

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
verifier="$(openssl rand 32 | b64url)"
challenge="$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | b64url)"

# Значення action з HTML-форми Keycloak (з розкодованим &amp;).
form_action() { sed -n 's/.*<form[^>]*action="\([^"]*\)".*/\1/p' | head -1 | sed 's/&amp;/\&/g'; }
# Значення code з заголовка Location.
location_code() { tr -d '\r' | sed -n 's/^[Ll]ocation: .*[?&]code=\([^&]*\).*/\1/p' | head -1; }

login_page="$(curl -sS -c "$jar" -b "$jar" -G "$realm/auth" \
  --data-urlencode client_id=web --data-urlencode response_type=code --data-urlencode scope=openid \
  --data-urlencode redirect_uri="$redirect" --data-urlencode state=cli \
  --data-urlencode code_challenge="$challenge" --data-urlencode code_challenge_method=S256)"
action="$(printf '%s' "$login_page" | form_action)"
[ -n "$action" ] || { echo "Не знайдено форму входу Keycloak. Чи запущено make up і чи правильна адреса $base?" >&2; exit 1; }

# Один запит з паролем: кожна невдала спроба рахується захистом від підбору.
curl -sS -D "$hdr" -o "$body" -c "$jar" -b "$jar" "$action" \
  --data-urlencode username="$user" --data-urlencode password="$pass" --data-urlencode credentialId=
code="$(location_code < "$hdr")"

if [ -z "$code" ]; then
  # Тимчасовий пароль: Keycloak переадресовує на сторінку обов'язкової зміни пароля.
  if grep -qiE '^location: .*required-action.*UPDATE_PASSWORD' "$hdr"; then
    echo "Користувач має тимчасовий пароль: спершу увійдіть у браузері й змініть його." >&2
  else
    echo "Вхід не вдався: неправильний логін чи пароль або обліковий запис тимчасово заблоковано." >&2
  fi
  exit 1
fi

curl -sS "$realm/token" \
  --data-urlencode grant_type=authorization_code --data-urlencode client_id=web \
  --data-urlencode code="$code" --data-urlencode redirect_uri="$redirect" \
  --data-urlencode code_verifier="$verifier" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
