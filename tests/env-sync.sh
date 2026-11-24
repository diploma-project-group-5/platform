#!/usr/bin/env bash
# Перевірки scripts/env-sync.sh (make env). Docker не потрібен.
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/scripts/env-sync.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "  ✔ $1"; pass=$((pass + 1)); }
bad() { echo "  ✖ $1"; fail=$((fail + 1)); }

echo "▶ make env (scripts/env-sync.sh)"

printf '# коментар\nA=1\nB=two=parts\n\nC=3\n' > "$tmp/ex"

bash "$script" "$tmp/ex" "$tmp/env" >/dev/null
cmp -s "$tmp/ex" "$tmp/env" && ok "без .env створює його копією прикладу" || bad "новий .env не збігається з прикладом"

printf 'A=мій-пароль\nZ=своя' > "$tmp/env"   # без переносу рядка в кінці
out="$(bash "$script" "$tmp/ex" "$tmp/env")"
[ "$(grep -c '^A=' "$tmp/env")" = "1" ] && grep -qx 'A=мій-пароль' "$tmp/env" && ok "наявне значення не змінює і не дублює" || bad "наявне значення змінено або продубльовано"
grep -qx 'B=two=parts' "$tmp/env" && grep -qx 'C=3' "$tmp/env" && ok "дописує відсутні змінні, значення з '=' цілі" || bad "відсутні змінні не дописано"
grep -qx 'Z=своя' "$tmp/env" && ok "останній рядок без переносу не склеюється з новими" || bad "останній рядок зіпсовано"
grep -qx 'Z=свояB=two=parts' "$tmp/env" && bad "рядки склеїлися" || true
echo "$out" | grep -q 'B C' && ok "повідомляє, що саме дописано" || bad "повідомлення без списку змінних: $out"

before="$(cat "$tmp/env")"
out="$(bash "$script" "$tmp/ex" "$tmp/env")"
[ "$before" = "$(cat "$tmp/env")" ] && echo "$out" | grep -q 'актуальний' && ok "повторний запуск нічого не змінює" || bad "повторний запуск змінив файл"

grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env.example | cut -d= -f1 | sort | uniq -d | grep -q . && bad "у .env.example є дублікати змінних" || ok ".env.example без дублікатів змінних"

echo "  разом: $pass ✔, $fail ✖"
[ "$fail" -eq 0 ]
