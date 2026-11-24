#!/usr/bin/env bash
# Перевірки kafka-init (картка #20). Викликається з make test на стенді lad-test.
# Аргумент — команда docker compose стенду, як у tests/db-init.sh.
set -euo pipefail
dc="$1"
pass=0; fail=0
ok()  { echo "  ✔ $1"; pass=$((pass + 1)); }
bad() { echo "  ✖ $1"; fail=$((fail + 1)); }
kt()  { $dc exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 "$@"; }
# Значення параметра топіка з kafka-configs --describe (лише явно задані).
topic_config() {
  $dc exec -T kafka /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
    --describe --entity-type topics --entity-name "$1" | tr ' ,' '\n\n' | sed -n "s/^$2=//p" | head -1
}
retention() { topic_config "$1" retention.ms; }

echo "▶ kafka-init"

if $dc run --rm -T kafka-init >/dev/null 2>&1; then ok "повторний запуск kafka-init проходить (ідемпотентний)"; else bad "повторний запуск kafka-init впав"; fi

expected="audit.recorded school.data.changed school.registered solve.build.requested solve.status solve.substitution.requested"
listed="$(kt --list | tr -d '\r' | grep -v '^__' | sort | tr '\n' ' ')"
want=""; for t in $expected; do want="$want$t $t.dlq "; done
want="$(printf '%s\n' $want | sort | tr '\n' ' ')"
[ "$listed" = "$want" ] && ok "рівно 12 топіків: 6 з маніфесту contracts і 6 .dlq, без .retry.*" || bad "топіки не збігаються з маніфестом: $listed"

[ "$(retention solve.status)" = "604800000" ] && ok "solve.status зберігається 7 днів" || bad "retention.ms solve.status: $(retention solve.status)"
[ "$(retention solve.build.requested.dlq)" = "1209600000" ] && ok "solve.build.requested.dlq зберігається 14 днів" || bad "retention.ms DLQ: $(retention solve.build.requested.dlq)"

# Сегмент на добу: без нього подія жила б до ~2 × retention (Kafka не видаляє активний сегмент).
[ "$(topic_config solve.status segment.ms)" = "86400000" ] && ok "solve.status: сегмент на добу (segment.ms)" || bad "segment.ms solve.status: $(topic_config solve.status segment.ms)"
[ "$(topic_config audit.recorded.dlq segment.ms)" = "86400000" ] && ok "DLQ теж із сегментом на добу" || bad "segment.ms audit.recorded.dlq: $(topic_config audit.recorded.dlq segment.ms)"

parts="$(kt --describe --topic solve.status | grep -c 'Partition: ' || true)"
[ "$parts" = "3" ] && ok "solve.status має 3 партиції (ключ school_id)" || bad "партицій solve.status: $parts"

# Строк зберігання, змінений вручну, kafka-init повертає до значення з маніфесту.
$dc exec -T kafka /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 --alter \
  --entity-type topics --entity-name solve.status --add-config retention.ms=1000,segment.ms=604800000 >/dev/null
$dc run --rm -T kafka-init >/dev/null 2>&1 || true
[ "$(retention solve.status)" = "604800000" ] && ok "повторний запуск синхронізує строк зберігання" || bad "строк зберігання не синхронізовано: $(retention solve.status)"
[ "$(topic_config solve.status segment.ms)" = "86400000" ] && ok "повторний запуск синхронізує сегмент" || bad "segment.ms не синхронізовано: $(topic_config solve.status segment.ms)"

echo "ℹ kafka-init: пройдено $pass, не пройдено $fail"
[ "$fail" -eq 0 ]
