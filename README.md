# platform

Інфраструктура «Лад» для локальної розробки й демо-сервера: PostgreSQL, Kafka і шлюз Traefik у docker-compose.

## Що потрібно

Docker Desktop (з Docker Compose v2) і `make`.

## Швидкий старт

```bash
cp .env.example .env
make up
```

`make up` чекає, поки всі контейнери пройдуть healthcheck. Перевірити стан — `make ps`, список усіх команд — `make`.

## Що всередині

| Сервіс | Контейнер | Адреса з хоста | Адреса з контейнерів |
|---|---|---|---|
| PostgreSQL 16.15 | `lad-postgres` | `localhost:5432` | `postgres:5432` |
| Kafka 4.3.2 (KRaft, один вузол) | `lad-kafka` | `localhost:29092` | `kafka:9092` |
| Traefik v3.7.17 | `lad-traefik` | `http://localhost` | — |

PostgreSQL і Kafka слухають лише `127.0.0.1`: ззовні машини вони недоступні.

Автостворення топіків у Kafka вимкнене: топіки створює `kafka-init`. Ролі й бази сервісів створює `db-init`. Обидва — окремі картки.

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
| `make reset` | зупинити й видалити всі дані (з підтвердженням) |
