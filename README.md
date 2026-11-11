# platform

Інфраструктура «Лад» для локальної розробки й демо-сервера: PostgreSQL, Kafka, Keycloak і шлюз Traefik у docker-compose.

## Що потрібно

Docker Desktop (з Docker Compose v2) і `make`.

## Швидкий старт

```bash
make env
make up
```

`make env` створює `.env` з `.env.example`, а якщо `.env` уже є — дописує лише змінні, яких бракує (наприклад, після `git pull`), не чіпаючи ваших значень. Запускайте його після кожного оновлення platform.

`make up` чекає, поки всі контейнери пройдуть healthcheck. Перевірити стан — `make ps`, список усіх команд — `make`.

## Що всередині

| Сервіс | Контейнер | Адреса з хоста | Адреса з контейнерів |
|---|---|---|---|
| PostgreSQL 16.15 | `lad-postgres` | `localhost:5432` | `postgres:5432` |
| Kafka 4.3.2 (KRaft, один вузол) | `lad-kafka` | `localhost:29092` | `kafka:9092` |
| Traefik v3.7.17 | `lad-traefik` | `http://localhost` | — |
| Keycloak 26.8.1 | `lad-keycloak` | `http://localhost/idp` (через шлюз) | `keycloak:8080/idp` |
| solver (профіль `solver`) | `lad-solver` | — | — (лише Kafka) |

PostgreSQL, Kafka і прямий порт Keycloak (8180, для адмін-консолі) слухають лише `127.0.0.1`: ззовні машини вони недоступні.

`db-init` — одноразовий контейнер, який при кожному `make up` створює ролі й бази й завершується. Зараз це Keycloak (`keycloak`) і три бази сервісів — `tenant`, `school`, `timetable`, кожна з ролями `<svc>_owner`, `<svc>_app`, `<svc>_relay`, `<svc>_maint` (паролі — `TENANT_*`, `SCHOOL_*`, `TIMETABLE_*_DB_PASSWORD` у `.env`). Робоча роль одного сервісу до бази іншого не під'єднується. Наступний сервіс додається одним рядком `service_database <svc>` у `db-init/init.sh` плюс чотири паролі в `.env.example` і `docker-compose.yml`.

Автостворення топіків у Kafka вимкнене. Топіки створює `kafka-init` — одноразовий контейнер, як `db-init`. Він бере список з маніфесту `contracts/topics.v1.json` (contracts v0.2.0): 6 топіків по 3 партиції зі строком зберігання 7 днів і до кожного `<топік>.dlq` на 14 днів. Повторний запуск нічого не перестворює, лише повертає строк зберігання до значення з маніфесту. Змінився маніфест у contracts — оновіть список у `kafka-init/init.sh`.

### Сервіси в контейнерах (профіль `apps`)

Для розробки сервіси запускаються на хості (`make dev` у їхніх репозиторіях), а `make up` піднімає лише інфраструктуру. Щоб підняти систему цілком, як на ВМ:

```bash
make up-apps   # збирає образи з ../frontend, ../tenant-service, ../school-service, ../timetable-service і піднімає все
make smoke     # шлюз → сервіси → Keycloak → PostgreSQL → Kafka: реєстрація закладу доходить до school
make down-apps # зупинити все, включно з контейнерами сервісів
```

Перед кожним сервісом окремий одноразовий контейнер `<svc>-migrate` застосовує міграції під роллю `<svc>_owner`; сервіс стартує лише після нього. `make up-apps` сам перемикає шлюз на контейнери (web — nginx зі статикою з репо frontend), `.env` для розробки на хості не змінюється. Порт `/internal/v1` school-service (3102) доступний лише в мережі compose. Коли образи з'являться в реєстрі — `WEB_IMAGE`, `TENANT_IMAGE`, `SCHOOL_IMAGE`, `TIMETABLE_IMAGE` у `.env`.

### solver

Kafka-воркер CP-SAT (`lad-solver`) вмикається профілем: `COMPOSE_PROFILES=solver` у `.env`, далі звичайний `make up`. Поки образу немає в реєстрі, compose збирає `lad-solver:local` з клону репо solver поруч (`SOLVER_SRC=../solver`). Коли образ з'явиться в GHCR — `SOLVER_IMAGE=ghcr.io/diploma-project-group-5/solver:<тег>`.

| Параметр | Значення | Чому |
|---|---|---|
| `cpus` | 1.5 | ВМ має 2 vCPU; ~0.5 CPU лишається API, Kafka і PostgreSQL |
| `SOLVER_NUM_WORKERS` | 2 | 2 потоки CP-SAT на 1.5 CPU дають найкращу якість за замірами |
| `mem_limit` | 768m | пік 222 МБ на закладі з 45 класів; CP-SAT обмежено 512 МБ |
| `stop_grace_period` | 30s | на SIGTERM solver публікує найкращий розв'язок і виходить з кодом 0 |
| `SOLVER_STALL_MIN_S` | 0 (вимкнено) | рання зупинка; ставити 8, коли timetable прийматиме `stop_reason: "no_improvement"` |

Портів у solver немає; стан — healthcheck образу за файлом-пульсом. Повний опис змінних — у README репо solver.

## Keycloak

Realm `lad` описано у файлі `keycloak/realm/lad-realm.json`. До демо 13.11 realm змінюється лише через цей файл (рішення 60). Keycloak імпортує файл тільки тоді, коли realm ще немає, тож після зміни файлу потрібен `make kc-reset`: він видаляє базу Keycloak і імпортує realm заново.

| Що | Значення |
|---|---|
| Ролі | `sysadmin`, `scheduler` |
| Група `schedulers` | дає роль `scheduler`; tenant-service створює укладача одразу в ній |
| Атрибут `school_id` | лише адмін бачить і змінює; користувач змінити не може (перевірено) |
| Клієнт `web` | публічний, вхід з PKCE (S256), без пароля напряму; `school_id` у токені |
| Клієнт `tenant-service` | секретний, сервісний акаунт з правами лише на користувачів |
| Користувачі | `sysadmin` і демо-укладач `demo` (`school_id` = `DEMO_SCHOOL_ID`); паролі з `.env` |
| Паролі | від 10 символів, не дорівнює логіну; після 5 невдалих спроб — тимчасове блокування до 15 хв |
| Токени | access-токен 15 хв, сесія 8 год |
| Мови | українська (за замовчуванням), англійська |

Головне в токені укладача:

```json
{
  "iss": "http://localhost/idp/realms/lad",
  "azp": "web",
  "realm_access": { "roles": ["scheduler"] },
  "school_id": "5d0b6a1e-7c3f-4b2a-9e41-0a1d2c3b4e5f"
}
```

### Перевірка JWT у сервісах

`iss` у токені — публічна адреса (`LAD_PUBLIC_URL`), а ключі сервіс у контейнері бере внутрішньою мережею. Тому в сервісі дві змінні:

| Змінна | Локально (сервіс на хості) | Сервіс у compose |
|---|---|---|
| `OIDC_ISSUER` | `http://localhost/idp/realms/lad` | `http://localhost/idp/realms/lad` (на ВМ — `https://<домен>/idp/realms/lad`) |
| `OIDC_JWKS_URL` | `http://localhost/idp/realms/lad/protocol/openid-connect/certs` | `http://keycloak:8080/idp/realms/lad/protocol/openid-connect/certs` |

Сервіс перевіряє підпис, `iss`, `exp`, `azp = web` і роль у `realm_access.roles`.

### Токен для перевірки свого API

```bash
make token                                  # демо-укладач
make token u=sysadmin p=<SYSADMIN_PASSWORD> # системний адмін
curl -H "Authorization: Bearer $(make -s token)" http://localhost/api/v1/school/...
```

### Адмін-консоль

Локально: `http://localhost:8180/idp/admin`, логін `admin`, пароль `KC_ADMIN_PASSWORD`. Через шлюз (`http://localhost/idp/admin`) консоль закрита навмисно. На ВМ — через SSH-тунель: `ssh -L 8180:127.0.0.1:8180 <ВМ>`, потім та сама адреса.


### Тема входу «Лад»

Сторінка входу, зміна тимчасового пароля й сторінки помилок мають вигляд прототипу: власна тема `keycloak/themes/lad` (шаблони FreeMarker, стилі з дизайн-токенами frontend, шрифт Onest локально). Поле — «Логін», бо пошту система не зберігає; скидання пароля — через адміністратора. Тема записана в realm (`"loginTheme": "lad"`) для чистих установок. У Keycloak, що вже працює, її вмикає `make kc-theme` без `make kc-reset` — користувачі лишаються. Після зміни файлів теми — `make restart s=keycloak`.

## Маршрути шлюзу

| Шлях | Куди | Примітка |
|---|---|---|
| `/` | web | |
| `/idp/…` | Keycloak | вхід і токени |
| `/idp/admin`, `/idp/realms/master`, `/idp/realms/lad/account` | — | 403 ззовні; адмін-консоль — через SSH-тунель |
| `/api/v1/tenant/…` | tenant-service | |
| `/api/v1/school/…` | school-service | |
| `/api/v1/timetable/…` | timetable-service | |
| `/api/v1/public/…` | timetable-service | 10 запитів/с з однієї IP, сплеск до 20, далі 429 |

Маршрути описано в `traefik/dynamic/routes.yml`. Traefik перечитує файл сам, перезапуск не потрібен.

## Правила для авторів сервісів

Під час розробки сервіс запускається на хості (`npm run dev`), а шлюз веде на нього через `host.docker.internal`. Порти домовлені для всіх:

| Сервіс | Порт |
|---|---|
| web | 5173 |
| tenant-service | 3001 |
| school-service | 3002 |
| timetable-service | 3003 |

Шлюз **не зрізає** префікс: сервіс отримує запит повністю, наприклад `/api/v1/school/classes`, і маршрути в коді оголошуються разом з префіксом.

Внутрішні маршрути `/internal/v1/…` слухають на **окремому порту**, на який шлюз не веде. Інакше `GET /api/v1/school/internal/v1/…` через шлюз дійшов би до сервісу. На публічному порту сервіс повинен віддавати 404 на такі шляхи.

Коли сервіс переїде в контейнер compose, його адресу змінюють у `.env`, наприклад `TENANT_UPSTREAM=http://tenant-service:8080`.

## Тести

```bash
make test
```

Піднімає окремий стенд `lad-test` (свої томи й мережа, порти назовні не відкриваються, робоче оточення `make up` не зачіпає), проганяє всі тести й прибирає стенд за собою. Перший запуск — до 2 хвилин, далі швидше. Якщо `make test` перервали, стенд прибирає `make test-down`.

| Файл | Що перевіряє |
|---|---|
| `tests/gateway.test.mjs` | маршрути шлюзу без зрізання префікса; адмінка Keycloak закрита разом з відомими обходами; ліміт `/api/v1/public`; заголовки безпеки; закодовані символи й заголовки-аліаси |
| `tests/keycloak.test.mjs` | вхід і вміст токенів; перший вхід зі зміною пароля; незмінність `school_id`; блокування підбору; права сервісного акаунта tenant-service; адмін-консоль |
| `tests/realm.test.mjs` | статичні перевірки `lad-realm.json` і файлів теми входу, без запуску Keycloak |
| `tests/db-init.sh` | ідемпотентність `db-init`; ролі keycloak, tenant, school, timetable без зайвих прав і власники баз; межа між базами сервісів; `btree_gist` для timetable |
| `tests/kafka-init.sh` | ідемпотентність `kafka-init`; рівно 6 топіків з маніфесту + 6 `.dlq`; строки зберігання 7 і 14 днів; 3 партиції |

Тести — JavaScript (`node --test`, без залежностей), запускаються в контейнері `node:24`, тож Node на машині не потрібен. Той самий `make test` запускає GitHub Actions на кожен пуш (`.github/workflows/test.yml`).

Правило: нова поведінка — новий тест у тій самій гілці; знайдена помилка — спершу тест, що її відтворює.

## Команди

| Команда | Що робить |
|---|---|
| `make up` | підняти все й дочекатися healthcheck |
| `make down` | зупинити (дані лишаються) |
| `make ps` | стан контейнерів |
| `make logs s=kafka` | логи одного сервісу (без `s` — усіх) |
| `make restart s=traefik` | перезапустити сервіс |
| `make config` | перевірити compose і `.env` без запуску |
| `make psql` | консоль PostgreSQL |
| `make kafka-topics` | список топіків |
| `make token` | access-токен демо-укладача (`u=… p=…` — іншого користувача) |
| `make test` | усі тести на окремому стенді |
| `make kc-reset` | перестворити realm з файлу (видаляє користувачів Keycloak, з підтвердженням) |
| `make reset` | зупинити й видалити всі дані (з підтвердженням) |
