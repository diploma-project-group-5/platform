COMPOSE := docker compose
# Окремий тестовий стенд: свій проєкт, томи й мережа; порти назовні не відкриваються.
TEST := docker compose -p lad-test -f docker-compose.yml -f docker-compose.test.yml
TEST_SERVICES := postgres db-init kafka kafka-init keycloak traefik web-stub tenant-stub school-stub timetable-stub

.DEFAULT_GOAL := help
.PHONY: help env up up-apps down down-apps smoke seed kc-theme restart ps logs config psql kafka-topics token kc-reset reset test test-down

help: ## Список команд
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.env:
	@echo "Немає файлу .env. Створіть його: make env"; exit 1

env: ## Створити .env або дописати змінні, яких бракує, з .env.example (наявні не чіпає)
	@bash scripts/env-sync.sh

up: .env ## Підняти інфраструктуру й дочекатися, поки всі healthcheck зелені
	$(COMPOSE) up -d --wait

# Шлюз веде на контейнери сервісів замість сервісів на хості (make dev). Змінні оболонки
# мають пріоритет над .env, тож .env для розробки на хості лишається без змін.
APPS_UPSTREAMS := WEB_UPSTREAM=http://web:8080 TENANT_UPSTREAM=http://tenant-service:3001 SCHOOL_UPSTREAM=http://school-service:3002 TIMETABLE_UPSTREAM=http://timetable-service:3003

up-apps: .env ## Підняти все разом із web, tenant, school і timetable у контейнерах (збирає образи з сусідніх папок)
	$(APPS_UPSTREAMS) $(COMPOSE) --profile apps up -d --wait --build

down: ## Зупинити контейнери (дані в томах лишаються)
	$(COMPOSE) down

down-apps: ## Зупинити все, включно з контейнерами сервісів і solver (дані в томах лишаються)
	$(COMPOSE) --profile apps --profile solver down

smoke: .env ## Наскрізна перевірка після make up-apps: шлюз, сервіси, реєстрація закладу доходить до school
	@bash tests/smoke.sh

seed: .env ## Завантажити демо-заклад із seed/demo-school.json (після make up-apps; повтор повертає дані до файлу)
	@bash scripts/seed.sh

restart: .env ## Перезапустити все або один сервіс: make restart s=traefik
	$(COMPOSE) restart $(s)

ps: ## Стан контейнерів і healthcheck
	$(COMPOSE) ps

logs: ## Логи всіх або одного сервісу: make logs s=kafka
	$(COMPOSE) logs -f --tail=200 $(s)

config: .env ## Перевірити docker-compose.yml і .env без запуску
	$(COMPOSE) config --quiet && echo "docker-compose.yml: OK"

psql: ## Консоль PostgreSQL від суперкористувача
	$(COMPOSE) exec postgres sh -c 'psql -U "$$POSTGRES_USER" -d postgres'

kafka-topics: ## Список топіків Kafka
	$(COMPOSE) exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

token: .env ## Access-токен: make token (демо-укладач) або make token u=sysadmin p=<пароль>
	@set -a; . ./.env; set +a; bash scripts/token.sh "$(or $(u),demo)" "$(or $(p),$$DEMO_SCHEDULER_PASSWORD)" "$$LAD_PUBLIC_URL"

kc-theme: .env ## Увімкнути тему входу «Лад» у вже працюючому Keycloak без перестворення realm (користувачі лишаються)
	$(COMPOSE) exec -T keycloak bash -c '/opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm.config \
	  --server http://localhost:8080/idp --realm master --user admin --password "$$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null \
	  && /opt/keycloak/bin/kcadm.sh update realms/lad --config /tmp/kcadm.config -s loginTheme=lad \
	  && echo "▶ тема входу lad увімкнена"'

kc-reset: .env ## Перестворити realm lad з keycloak/realm/lad-realm.json (ВИДАЛЯЄ користувачів Keycloak)
	@read -p "Видалити базу Keycloak і заново імпортувати realm lad? [y/N] " a; [ "$$a" = "y" ] || { echo "Скасовано"; exit 1; }
	$(COMPOSE) stop keycloak
	$(COMPOSE) exec postgres sh -c 'psql -U "$$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS keycloak WITH (FORCE)"'
	$(COMPOSE) up -d --wait

reset: ## Зупинити й ВИДАЛИТИ всі дані (бази, топіки) — питає підтвердження
	@read -p "Видалити всі дані PostgreSQL і Kafka? [y/N] " a; [ "$$a" = "y" ] || { echo "Скасовано"; exit 1; }
	$(COMPOSE) down -v

test: .env ## Усі тести platform на окремому стенді lad-test (робоче оточення не зачіпає)
	@bash tests/env-sync.sh
	@$(COMPOSE) config --quiet && echo "▶ docker-compose.yml і .env: OK"
	@set -e; \
	trap '$(TEST) down -v --remove-orphans >/dev/null 2>&1' EXIT; \
	echo "▶ Піднімаю стенд lad-test (перший раз — до 2 хв)…"; \
	$(TEST) up -d --wait --quiet-pull $(TEST_SERVICES); \
	bash tests/db-init.sh "$(TEST)"; \
	bash tests/kafka-init.sh "$(TEST)"; \
	$(TEST) run --rm tests

test-down: ## Прибрати стенд lad-test, якщо make test перервали
	$(TEST) down -v --remove-orphans
