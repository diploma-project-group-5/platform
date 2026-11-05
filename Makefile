COMPOSE := docker compose
# Окремий тестовий стенд: свій проєкт, томи й мережа; порти назовні не відкриваються.
TEST := docker compose -p lad-test -f docker-compose.yml -f docker-compose.test.yml
TEST_SERVICES := postgres db-init keycloak traefik web-stub tenant-stub school-stub timetable-stub

.DEFAULT_GOAL := help
.PHONY: help env up down restart ps logs config psql kafka-topics token kc-reset reset test test-down

help: ## Список команд
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.env:
	@echo "Немає файлу .env. Створіть його: make env"; exit 1

env: ## Створити .env або дописати змінні, яких бракує, з .env.example (наявні не чіпає)
	@bash scripts/env-sync.sh

up: .env ## Підняти інфраструктуру й дочекатися, поки всі healthcheck зелені
	$(COMPOSE) up -d --wait

down: ## Зупинити контейнери (дані в томах лишаються)
	$(COMPOSE) down

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
	$(TEST) run --rm tests

test-down: ## Прибрати стенд lad-test, якщо make test перервали
	$(TEST) down -v --remove-orphans
