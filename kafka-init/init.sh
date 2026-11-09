#!/usr/bin/env bash
# Створює топіки Kafka за маніфестом contracts/topics.v1.json (contracts v0.2.0) і завершується.
# Запускається контейнером kafka-init при кожному make up, тому ідемпотентний:
# наявний топік не перестворюється, лише синхронізується строк зберігання.
#
# Змінили маніфест у contracts — оновіть список нижче в тій самій гілці, що й тег contracts.
set -euo pipefail

bootstrap="${KAFKA_BOOTSTRAP:-kafka:9092}"
partitions="${KAFKA_TOPIC_PARTITIONS:-3}"
retention_ms=604800000      # 7 днів (маніфест: defaults.retention_ms)
dlq_retention_ms=1209600000 # 14 днів (маніфест: defaults.dlq_retention_ms)

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
    --config "retention.ms=$retention" >/dev/null
  # Для вже наявного топіка --create нічого не змінює: строк зберігання синхронізуємо окремо.
  "$bin/kafka-configs.sh" --bootstrap-server "$bootstrap" --alter \
    --entity-type topics --entity-name "$name" --add-config "retention.ms=$retention" >/dev/null
  echo "kafka-init: $name (retention.ms=$retention)"
}

for topic in "${topics[@]}"; do
  ensure_topic "$topic" "$retention_ms"
  ensure_topic "$topic.dlq" "$dlq_retention_ms"
done

echo "kafka-init: OK"
