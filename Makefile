# XplanePLPG — Crossplane-style PostgreSQL Provider in PL/pgSQL
# ============================================================================

# Connection settings (override via environment)
XPLANE_DB_HOST     ?= localhost
XPLANE_DB_PORT     ?= 5432
XPLANE_DB_NAME     ?= postgres
XPLANE_DB_USER     ?= postgres
XPLANE_DB_PASSWORD ?=

PSQL = PGPASSWORD="$(XPLANE_DB_PASSWORD)" psql -h $(XPLANE_DB_HOST) -p $(XPLANE_DB_PORT) -U $(XPLANE_DB_USER) -d $(XPLANE_DB_NAME) -v ON_ERROR_STOP=1

.PHONY: install install-cron uninstall test test-unit test-integration demo docker-up docker-down clean

# ----------------------------------------------------------------------------
# Installation
# ----------------------------------------------------------------------------

install:
	@echo "==> Installing XplanePLPG..."
	$(PSQL) -c "DROP SCHEMA IF EXISTS crossplane CASCADE;"
	$(PSQL) -c "CREATE EXTENSION IF NOT EXISTS dblink;"
	$(PSQL) -f sql/00_schema_provider.sql
	$(PSQL) -f sql/01_helpers.sql
	$(PSQL) -f sql/02_actions.sql
	$(PSQL) -f sql/03_reconciler.sql
	@echo "==> XplanePLPG installed successfully"

install-cron: install
	@echo "==> Setting up pg_cron..."
	$(PSQL) -f sql/04_cron_setup.sql

uninstall:
	@echo "==> Uninstalling XplanePLPG..."
	$(PSQL) -c "DROP SCHEMA IF EXISTS crossplane CASCADE;"
	@echo "==> XplanePLPG uninstalled"

# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------

test: test-unit test-integration

test-unit: install
	@echo "==> Running unit tests..."
	$(PSQL) -f tests/framework/tap.sql
	$(PSQL) -f tests/unit/test_helpers.sql
	$(PSQL) -f tests/unit/test_actions_schema.sql
	$(PSQL) -f tests/unit/test_actions_role.sql
	$(PSQL) -f tests/unit/test_actions_extension.sql
	$(PSQL) -f tests/unit/test_actions_service_account.sql
	$(PSQL) -f tests/unit/test_actions_database.sql
	$(PSQL) -f tests/unit/test_reconciler.sql
	@echo "==> All unit tests passed"

test-integration: install
	@echo "==> Running integration tests..."
	$(PSQL) -f tests/framework/tap.sql
	$(PSQL) -f tests/integration/test_full_lifecycle.sql
	$(PSQL) -f tests/integration/test_idempotency.sql
	@echo "==> All integration tests passed"

# ----------------------------------------------------------------------------
# Demo
# ----------------------------------------------------------------------------

demo: install
	@echo "==> Running demo scenario..."
	$(PSQL) -f sql/05_examples.sql

# ----------------------------------------------------------------------------
# Docker
# ----------------------------------------------------------------------------

docker-up:
	docker compose -f docker/docker-compose.yml up -d --build

docker-down:
	docker compose -f docker/docker-compose.yml down

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------

clean: uninstall
	@echo "==> Cleanup complete"
