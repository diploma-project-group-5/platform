#!/usr/bin/env bash
# make demo: локальний стенд для показу однією командою (platform #20).
# Звільняє порти стенду від чужих контейнерів, повністю перезапускає стенд (дані в томах лишаються,
# мережа створюється заново), піднімає сервіси й solver, завантажує демо-заклад (make seed).
# Кожен крок — відповідь на збій, який уже траплявся перед показом: зайнятий порт 5432 робочим
# PostgreSQL, «застаріла» мережа після простою (db-init не знаходить postgres), solver, якого
# make up-apps не піднімає.
# Адреси сервісів для шлюзу (WEB_UPSTREAM тощо) задаються нижче, після .env.
set -euo pipefail
set -a; . ./.env; set +a
# .env задає адреси для режиму розробки (host.docker.internal:5173 тощо), а показ іде на контейнерах.
# Тому після .env — ті самі адреси, що в make up-apps; інакше шлюз веде web і API на хост, де нічого немає.
export WEB_UPSTREAM=http://web:8080 TENANT_UPSTREAM=http://tenant-service:3001 \
  SCHOOL_UPSTREAM=http://school-service:3002 TIMETABLE_UPSTREAM=http://timetable-service:3003
compose=(docker compose --profile apps --profile solver)

echo "▶ make demo: порти, стенд з нуля, solver, сід"

# 1. Порти стенду. Зупиняємо лише чужі контейнери: їхні дані не зникають, підніміть їх потім як звичайно.
for port in "${HTTP_PORT:-80}" "${PG_PORT:-5432}" "${KAFKA_EXTERNAL_PORT:-29092}" "${KC_ADMIN_PORT:-8180}"; do
  for id in $(docker ps -q --filter "publish=$port"); do
    name="$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')"
    case "$name" in
      lad-*) ;;
      *) echo "  ⏹ зупиняю $name — тримає порт $port"; docker stop "$id" >/dev/null ;;
    esac
  done
done

# 2. Версія solver (platform #13): локальний клон не перемикаємо — лише попереджаємо.
if [ -n "${SOLVER_REF:-}" ] && [ -d "${SOLVER_SRC:-../solver}/.git" ]; then
  have="$(git -C "${SOLVER_SRC:-../solver}" describe --tags --exact-match 2>/dev/null || git -C "${SOLVER_SRC:-../solver}" rev-parse --short HEAD)"
  [ "$have" = "$SOLVER_REF" ] \
    || echo "  ⚠ solver у ${SOLVER_SRC:-../solver} — $have, а для показу закріплено $SOLVER_REF: git -C ${SOLVER_SRC:-../solver} checkout $SOLVER_REF"
fi

# 3. Стенд з нуля (томи лишаються) і 4. підйом разом із solver.
"${compose[@]}" down --remove-orphans
"${compose[@]}" up -d --wait --build

# 5. Демо-заклад у чистому стані.
bash scripts/seed.sh

echo "▶ Готово: ${LAD_PUBLIC_URL:-http://localhost}, вхід demo / пароль DEMO_SCHEDULER_PASSWORD з .env"
