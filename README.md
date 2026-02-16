# XplanePLPG — Crossplane-Style PostgreSQL Provider in PL/pgSQL

A declarative PostgreSQL resource provider implemented **entirely in SQL**. Manage databases, schemas, roles, extensions, and service accounts through a Crossplane-inspired reconciliation loop — no external dependencies, no binaries, no Kubernetes required.

**Your database IS the control plane.**

## Architecture

```
apply()/delete()  →  reconcile()  →  observe/diff/act  →  conditions + events
       API              Loop          CRUD per kind         Status model
```

### Managed Resource Kinds

| Kind | Description |
|------|-------------|
| `Database` | Databases (owner, encoding, connection_limit) |
| `Schema` | Schemas within a database (owner) |
| `Role` | RBAC roles (superuser, createdb, login, membership) |
| `ServiceAccount` | Application roles with LOGIN + granular grants |
| `Extension` | PostgreSQL extensions (version, schema) |

### Status Codes

| Range | Meaning | Examples |
|-------|---------|---------|
| 1xx | In progress | `100_PENDING`, `101_RECONCILING`, `102_CREATING` |
| 2xx | Success | `201_CREATED`, `202_UPDATED`, `203_DELETED`, `204_NO_CHANGE` |
| 4xx | Client error | `400_INVALID_SPEC`, `409_CONFLICT`, `422_UNPROCESSABLE` |
| 5xx | Server error | `500_INTERNAL_ERROR`, `503_UNAVAILABLE` |

### Conditions

Each resource exposes two conditions (like Crossplane/Kubernetes):

- **`Synced`** — communication with PostgreSQL succeeded?
- **`Ready`** — resource is operational and usable?

## Quick Start

### With Docker

```bash
make docker-up
```

This starts PostgreSQL 16 with XplanePLPG pre-installed.

### Manual Installation

Requirements: PostgreSQL 14+, `dblink` extension.

```bash
# Set connection (defaults: localhost:5432/postgres)
export XPLANE_DB_PASSWORD=yourpassword

# Install
make install

# Run demo
make demo
```

### Usage

```sql
-- Declare a resource
SELECT crossplane.apply('Database', 'my-db',
    '{"name":"mydb","owner":"postgres"}'::JSONB);

-- Reconcile (create/update/delete as needed)
SELECT * FROM crossplane.reconcile_all();

-- Check status
SELECT * FROM crossplane.resource_status;

-- Delete
SELECT crossplane.delete('Database', 'my-db');
SELECT * FROM crossplane.reconcile_all();
```

## Project Structure

```
sql/
  00_schema_provider.sql    Schema, enums, tables, indexes
  01_helpers.sql            set_condition, emit_event, observe_resource
  02_actions.sql            CRUD per kind (create/update/delete)
  03_reconciler.sql         reconcile(), reconcile_all(), apply(), delete()
  04_cron_setup.sql         pg_cron automatic reconciliation (optional)
  05_examples.sql           Complete demo scenario
tests/
  unit/                     pgTAP unit tests per kind
  integration/              Lifecycle and idempotency tests
docker/
  Dockerfile                PostgreSQL 16 + XplanePLPG
  docker-compose.yml        Local dev stack (+ optional pgAdmin)
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make install` | Install XplanePLPG on target database |
| `make install-cron` | Install + setup pg_cron reconciliation |
| `make uninstall` | Drop the crossplane schema |
| `make test` | Run all tests (unit + integration) |
| `make test-unit` | Unit tests only |
| `make test-integration` | Integration tests only |
| `make demo` | Run the example scenario |
| `make docker-up` | Start Docker stack |
| `make docker-down` | Stop Docker stack |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `XPLANE_DB_HOST` | `localhost` | PostgreSQL host |
| `XPLANE_DB_PORT` | `5432` | PostgreSQL port |
| `XPLANE_DB_NAME` | `postgres` | Target database |
| `XPLANE_DB_USER` | `postgres` | User (needs CREATEROLE + CREATEDB) |
| `XPLANE_DB_PASSWORD` | *(empty)* | Password |

## Testing

Tests use [pgTAP](https://pgtap.org/). Install pgTAP, then:

```bash
make test
```

Or run in Docker where pgTAP is pre-installed:

```bash
make docker-up
XPLANE_DB_PASSWORD=postgres make test
```

## Requirements

- PostgreSQL 14+ (tested on 14, 15, 16, 17)
- Extension `dblink` (for CREATE/DROP DATABASE outside transactions)
- Extension `pg_cron` (optional, for automatic reconciliation every 30s)
- Extension `pgTAP` (for running tests)

## License

Apache 2.0
