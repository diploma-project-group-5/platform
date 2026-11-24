#!/usr/bin/env bash
# Створює топіки Kafka за маніфестом contracts/topics.v1.json (contracts v0.5.0; список топіків той самий, що з v0.4.0) і завершується.
# Запускається контейнером kafka-init при кожному make up, тому ідемпотентний:
# наявний топік не перестворюється, лише синхронізуються строк зберігання й розмір сегмента в часі.
#
# Змінили маніфест у contracts — оновіть список нижче в тій самій гілці, що й тег contracts.
set -euo pipefail

bootstrap="${KAFKA_BOOTSTRAP:-kafka:9092}"
partitions="${KAFKA_TOPIC_PARTITIONS:-3}"
retention_ms=604800000      # 7 днів (маніфест: defaults.retention_ms)
dlq_retention_ms=1209600000 # 14 днів (маніфест: defaults.dlq_retention_ms)
# Kafka видаляє дані цілими сегментами, а активний сегмент — ніколи. Без segment.ms (за замовчуванням
# 7 днів) на малому трафіку подія жила б майже 2 × retention. Сегмент на добу: подія живе не довше
# retention + 1 доба (рішення: топіки 7 днів, DLQ 14 днів — мінімізація ПД).
segment_ms=86400000         # 1 доба

# Топіки з маніфесту. До кожного — <топік>.dlq: у кожного топіка є консюмер (розділ 12).
# Топіків .retry.* немає: 3 спроби в консюмері, далі DLQ.
topics=(
  school.registered
  school.data.changed
  solve.build.requested
  solve.substitution.requested
  solve.status
  audit.recorded
)

bin=/opt/kafka/bin

ensure_topic() {
  local name="$1" retention="$2"
  "$bin/kafka-topics.sh" --bootstrap-server "$bootstrap" --create --if-not-exists \
    --topic "$name" --partitions "$partitions" --replication-factor 1 \
    --config "retention.ms=$retention" --config "segment.ms=$segment_ms" >/dev/null
  # Для вже наявного топіка --create нічого не змінює: строк зберігання й сегмент синхронізуємо окремо.
  "$bin/kafka-configs.sh" --bootstrap-server "$bootstrap" --alter \
    --entity-type topics --entity-name "$name" --add-config "retention.ms=$retention,segment.ms=$segment_ms" >/dev/null
  echo "kafka-init: $name (retention.ms=$retention, segment.ms=$segment_ms)"
}

for topic in "${topics[@]}"; do
  ensure_topic "$topic" "$retention_ms"
  ensure_topic "$topic.dlq" "$dlq_retention_ms"
done

echo "kafka-init: OK"
