#!/usr/bin/env bash
# Перевірки kafka-init (картка #20). Викликається з make test на стенді lad-test.
# Аргумент — команда docker compose стенду, як у tests/db-init.sh.
set -euo pipefail
dc="$1"
pass=0; fail=0
ok()  { echo "  ✔ $1"; pass=$((pass + 1)); }
bad() { echo "  ✖ $1"; fail=$((fail + 1)); }
kt()  { $dc exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 "$@"; }
retention() {
  $dc exec -T kafka /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
    --describe --entity-type topics --entity-name "$1" | tr ' ,' '\n\n' | sed -n 's/^retention\.ms=//p' | head -1
}

echo "▶ kafka-init"

if $dc run --rm -T kafka-init >/dev/null 2>&1; then ok "повторний запуск kafka-init проходить (ідемпотентний)"; else bad "повторний запуск kafka-init впав"; fi

expected="audit.recorded school.data.changed school.registered solve.build.requested solve.status solve.substitution.requested"
listed="$(kt --list | tr -d '\r' | grep -v '^__' | sort | tr '\n' ' ')"
want=""; for t in $expected; do want="$want$t $t.dlq "; done
want="$(printf '%s\n' $want | sort | tr '\n' ' ')"
[ "$listed" = "$want" ] && ok "рівно 12 топіків: 6 з маніфесту contracts і 6 .dlq, без .retry.*" || bad "топіки не збігаються з маніфестом: $listed"

[ "$(retention solve.status)" = "604800000" ] && ok "solve.status зберігається 7 днів" || bad "retention.ms solve.status: $(retention solve.status)"
[ "$(retention solve.build.requested.dlq)" = "1209600000" ] && ok "solve.build.requested.dlq зберігається 14 днів" || bad "retention.ms DLQ: $(retention solve.build.requested.dlq)"

parts="$(kt --describe --topic solve.status | grep -c 'Partition: ' || true)"
[ "$parts" = "3" ] && ok "solve.status має 3 партиції (ключ school_id)" || bad "партицій solve.status: $parts"

# Строк зберігання, змінений вручну, kafka-init повертає до значення з маніфесту.
$dc exec -T kafka /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 --alter \
  --entity-type topics --entity-name solve.status --add-config retention.ms=1000 >/dev/null
$dc run --rm -T kafka-init >/dev/null 2>&1 || true
[ "$(retention solve.status)" = "604800000" ] && ok "повторний запуск синхронізує строк зберігання" || bad "строк зберігання не синхронізовано: $(retention solve.status)"

echo "ℹ kafka-init: пройдено $pass, не пройдено $fail"
[ "$fail" -eq 0 ]
