#!/usr/bin/env bash
# Наскрізна перевірка стенду після make up-apps (не входить у make test: CI не має клонів сервісів).
# Шлюз → сервіси в контейнерах → Keycloak → PostgreSQL → Kafka → school-service.
set -euo pipefail
set -a; . ./.env; set +a
base="${LAD_PUBLIC_URL:-http://localhost}"
pass=0; fail=0
ok()  { echo "  ✔ $1"; pass=$((pass + 1)); }
bad() { echo "  ✖ $1"; fail=$((fail + 1)); }
# Жоден запит не висне: якщо шлюз веде в порожнечу, перевірка падає за 20 с, а не стоїть.
curl() { command curl --max-time 20 "$@"; }

# Заклади smoke мають логіни smoke-*. Після перевірки (і при збої) їх прибираємо всюди: користувача
# в Keycloak, рядки в tenant, school і timetable. Інакше кожен запуск лишав би «Smoke …» у реєстрі,
# а на ВМ — просто на демо. Прибирає й залишки попередніх запусків.
psql_su() { docker exec lad-postgres psql -U "${POSTGRES_SUPERUSER:-postgres}" -v ON_ERROR_STOP=1 -tAq -d "$@"; }
kc="http://localhost:${KC_ADMIN_PORT:-8180}/idp"
kc_token() {
  curl -s -d grant_type=client_credentials -d client_id=tenant-service -d "client_secret=$TENANT_CLIENT_SECRET" \
    "$kc/realms/lad/protocol/openid-connect/token" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}
cleanup_smoke() {
  local rows ids users token uid db
  rows="$(psql_su tenant -c "select school_id || ' ' || scheduler_user_id from schools where scheduler_login like 'smoke-%'" 2>/dev/null || true)"
  [ -n "$rows" ] || return 0
  ids="$(printf '%s\n' "$rows" | awk '{print $1}' | paste -sd, -)"
  users="$(printf '%s\n' "$rows" | awk '{print $2}')"
  # Користувачів видаляє сервісний акаунт tenant-service (права manage-users) напряму, повз шлюз.
  token="$(kc_token)"
  for uid in $users; do
    curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $token" "$kc/admin/realms/lad/users/$uid" || true
  done
  # Усі таблиці з school_id у кожній базі; replica вимикає перевірку зовнішніх ключів, тож порядок не важливий.
  for db in tenant school timetable; do
    psql_su "$db" -c "set session_replication_role = replica;
      do \$\$ declare t text; begin
        for t in select c.table_name from information_schema.columns c
                 join information_schema.tables tb on tb.table_schema = c.table_schema and tb.table_name = c.table_name
                 where c.table_schema = 'public' and c.column_name = 'school_id' and tb.table_type = 'BASE TABLE'
        loop execute format('delete from %I where school_id = any(%L::uuid[])', t, '{$ids}'); end loop;
      end \$\$;" >/dev/null || return 1
  done
}
trap cleanup_smoke EXIT

echo "▶ smoke: стенд із сервісами в контейнерах"
cleanup_smoke

# docker inspect для неіснуючого контейнера друкує порожній рядок, тож порожнє значення — «немає».
inspect() { docker inspect -f "$1" "$2" 2>/dev/null | tr -d '\n' || true; }
for c in lad-web lad-tenant-service lad-school-service lad-timetable-service; do
  state="$(inspect '{{.State.Health.Status}}' "$c")"
  [ "$state" = "healthy" ] && ok "$c: healthy" || bad "$c: ${state:-немає контейнера} (make up-apps пройшов?)"
done
for c in lad-tenant-migrate lad-school-migrate lad-timetable-migrate; do
  code="$(inspect '{{.State.ExitCode}}' "$c")"
  [ "$code" = "0" ] && ok "$c: міграції застосовано (exit 0)" || bad "$c: ${code:+exit $code}${code:-немає контейнера}"
done
# Без контейнерів сервісів решта перевірок лише повторить ту саму причину.
if [ "$fail" -gt 0 ]; then echo "ℹ smoke: пройдено $pass, не пройдено $fail — спершу make up-apps"; exit 1; fi

# web: сторінка застосунку через шлюз; шляхи SPA (/c — сторінка за QR) теж віддають index.html.
for path in / /c; do
  page="$(curl -s "$base$path")"
  case "$page" in *'id="root"'*) ok "шлюз → web $path: сторінка застосунку";; *) bad "шлюз → web $path: не index.html";; esac
done

# Без токена кожен сервіс відповідає сам 401. 502 чи 404 означали б, що шлюз до нього не дійшов.
for svc in tenant/schools school/classes timetable/timetables; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$base/api/v1/$svc")"
  [ "$code" = "401" ] && ok "шлюз → $svc: 401 без токена (відповів сервіс)" || bad "шлюз → $svc: $code замість 401"
done

# /internal через шлюз — 404 від Traefik на зібраному стенді, а не index.html від web (platform #17).
for path in /internal/v1/schools/x/snapshot /INTERNAL/v1/x; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$base$path")"
  [ "$code" = "404" ] && ok "шлюз → $path: 404" || bad "шлюз → $path: $code замість 404"
done

token="$(bash scripts/token.sh sysadmin "$SYSADMIN_PASSWORD" "$base")"
login="smoke-$(date +%s)"
resp="$(curl -s -X POST "$base/api/v1/tenant/schools" -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' -d "{\"name\":\"Smoke $login\",\"login\":\"$login\"}")"
school_id="$(printf '%s' "$resp" | sed -n 's/.*"school_id":"\([0-9a-f-]*\)".*/\1/p')"
if [ -n "$school_id" ]; then ok "реєстрація закладу через шлюз: school_id $school_id"; else bad "реєстрація не вдалася: $resp"; fi

if [ -n "$school_id" ]; then
  found=""
  for _ in $(seq 1 30); do
    found="$(docker exec lad-postgres psql -U "${POSTGRES_SUPERUSER:-postgres}" -d school -tAc \
      "select name from school_profile where school_id = '$school_id'")"
    [ -n "$found" ] && break
    sleep 0.5
  done
  [ "$found" = "Smoke $login" ] && ok "school-service отримав school.registered і створив профіль" \
    || bad "профілю $school_id у school немає за 15 с (relay tenant → Kafka → school?)"
fi

# Заміна (platform #13): відсутність вчителя демо-закладу → задача заміни доходить до кінцевого стану
# раніше за queue_deadline_at, а не висить у черзі до сторожа. solver ≥ 0.4.0 її рахує (done),
# 0.3.0 одразу відмовляє (failed / unsupported_job_type) — обидва варіанти означають, що solver
# отримав задачу. Жорсткої межі в секундах немає: якщо solver саме рахує побудову, заміна чекає її.
# Потрібні solver і сід (make seed); без них перевірка пропускається з поясненням.
# Відсутність і її задачі після перевірки видаляються, демо-дані лишаються як були.
subst_check() {
  local date dow teacher demo resp absence job state=queued error="" i
  if [ "$(inspect '{{.State.Running}}' lad-solver)" != "true" ]; then
    echo "  ⊘ заміна: пропущено — solver не запущено (make demo або профіль solver)"; return
  fi
  # Найближчий навчальний день, починаючи із завтра (GNU date на ВМ, BSD date на macOS).
  for i in 1 2 3 4 5 6 7; do
    date="$(date -u -d "+$i day" +%F 2>/dev/null || date -u -v+"$i"d +%F)"
    dow="$(date -u -d "$date" +%u 2>/dev/null || date -u -j -f %F "$date" +%u)"
    [ "$dow" -le 5 ] && break
  done
  teacher="$(psql_su timetable -c "select l.teacher_id from lessons l join timetables t using (school_id, timetable_id)
    where t.school_id = '$DEMO_SCHOOL_ID' and t.kind = 'main' and t.state = 'published' and l.day = $dow limit 1" 2>/dev/null || true)"
  if [ -z "$teacher" ]; then echo "  ⊘ заміна: пропущено — у демо-закладу немає опублікованого розкладу (make seed)"; return; fi
  demo="$(bash scripts/token.sh demo "$DEMO_SCHEDULER_PASSWORD" "$base")"
  resp="$(curl -s -X POST "$base/api/v1/timetable/absences" -H "Authorization: Bearer $demo" -H 'Content-Type: application/json' \
    -d "{\"teacher_id\":\"$teacher\",\"date_from\":\"$date\",\"date_to\":\"$date\"}")"
  absence="$(printf '%s' "$resp" | sed -n 's/.*"absence_id":"\([0-9a-f-]*\)".*/\1/p')"
  job="$(printf '%s' "$resp" | sed -n 's/.*"job_ids":\["\([0-9a-f-]*\)".*/\1/p')"
  if [ -z "$job" ]; then bad "заміна: відсутність не прийнято: $resp"; return; fi
  for i in $(seq 1 300); do
    state="$(psql_su timetable -c "select state from jobs where job_id = '$job'" 2>/dev/null || true)"
    case "$state" in queued|running|'') sleep 1 ;; *) break ;; esac
  done
  error="$(psql_su timetable -c "select coalesce(error, '') from jobs where job_id = '$job'" 2>/dev/null || true)"
  case "$state/$error" in
    done/*) ok "заміна: відсутність → задача заміни done (solver рахує заміни), $date" ;;
    failed/unsupported_job_type) ok "заміна: відсутність → задача заміни одразу failed / unsupported_job_type (solver 0.3.0)" ;;
    *) bad "заміна: задача $job — $state ${error:+($error)}, очікувалось done або failed / unsupported_job_type" ;;
  esac
  psql_su timetable -c "set session_replication_role = replica;
    delete from substitutions where job_id in (select job_id from jobs where absence_id = '$absence');
    delete from jobs where absence_id = '$absence';
    delete from absences where absence_id = '$absence';" >/dev/null 2>&1 || true
}
subst_check

left_db="$(cleanup_smoke && psql_su tenant -c "select count(*) from schools where scheduler_login like 'smoke-%'" || echo '?')"
left_kc="$(curl -s -H "Authorization: Bearer $(kc_token)" "$kc/admin/realms/lad/users?search=smoke-&briefRepresentation=true")"
if [ "$left_db" = "0" ] && [ "$left_kc" = "[]" ]; then
  ok "прибрано за собою: заклад smoke і його укладача видалено з tenant, school, timetable і Keycloak"
else
  bad "не вдалося прибрати заклад smoke"
fi
trap - EXIT

echo "ℹ smoke: пройдено $pass, не пройдено $fail"
[ "$fail" -eq 0 ]
