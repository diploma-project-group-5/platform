COMPOSE := docker compose

.DEFAULT_GOAL := help
.PHONY: help up down restart ps logs config psql kafka-topics reset

help: ## Список команд
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.env:
	@echo "Немає файлу .env. Створіть його: cp .env.example .env"; exit 1

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

reset: ## Зупинити й ВИДАЛИТИ всі дані (бази, топіки) — питає підтвердження
	@read -p "Видалити всі дані PostgreSQL і Kafka? [y/N] " a; [ "$$a" = "y" ] || { echo "Скасовано"; exit 1; }
	$(COMPOSE) down -v