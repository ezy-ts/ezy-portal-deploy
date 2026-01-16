# EZY Portal Deployment - Development Guide

## Adding a New Module

When adding a new module (e.g., `sbo-insights`, `crm`), update these files:

### 1. `lib/docker.sh` (CRITICAL - often missed)

**Add to `MODULE_IMAGES` array:**
```bash
declare -A MODULE_IMAGES=(
    ["portal"]="ezy-portal-backend"
    ["bp"]="ezy-portal-bp"
    ["items"]="ezy-portal-items"
    ["prospects"]="ezy-portal-prospects"
    ["pricing-tax"]="ezy-portal-pricing-tax"
    ["crm"]="ezy-portal-crm"
    ["NEW_MODULE"]="ezy-portal-NEW_MODULE"  # <-- ADD HERE
)
```

**Add to `ordered_modules` array in `get_compose_files_for_modules()`:**
```bash
local ordered_modules=("items" "bp" "prospects" "pricing-tax" "crm" "NEW_MODULE")
```

### 2. `add-module.sh`

- `MODULE_DEPENDENCIES` array
- `MODULE_API_KEY_VARS` array
- `MODULE_HAS_FRONTEND` array
- Validation regex in `parse_arguments()`
- Help text in `show_help()`
- `ordered_modules` array in `start_module()`

### 3. `remove-module.sh`

- `REVERSE_DEPENDENCIES` array
- `MODULE_API_KEY_VARS` array
- Validation regex in `parse_arguments()`
- Help text in `show_help()`

### 4. `lib/module-installer.sh`

- `ordered_modules` array in `start_module()`

### 5. `docker/` directory

Create these files:
- `docker-compose.module-MODULE_NAME.yml` - Main service definition
- `docker-compose.module-MODULE_NAME-limits.yml` - Resource limits for high-performance mode

### 6. `nginx/conf.d/portal-https.conf`

Add location blocks for:
- Health check: `/api/MODULE_NAME/health`
- API routes: `/api/MODULE_NAME/`
- MFE remoteEntry.js (no-cache): `/MODULE_NAME_mfe/remoteEntry.js`
- MFE static files (cached): `/MODULE_NAME_mfe/`

### 7. `portal.env`

- Add module to `MODULES=` list
- Add `MODULE_NAME_IMAGE=ghcr.io/ezy-ts/ezy-portal-MODULE_NAME`
- Add `MODULE_NAME_VERSION=x.x.x`

## Customer Modules

Customer modules use a different pattern - see `add-customer-module.sh` and `lib/customer-module.sh`.

## Common Issues

### Module image defaults to `ezy-portal-backend`
If you forgot to add the module to `MODULE_IMAGES` in `lib/docker.sh`, the `get_module_image()` function returns the default backend image instead of the module-specific image.

### Migrations fail with malformed table names
Some modules have bugs where the schema_migrations table gets created with a literal dot in the name (e.g., `sbo_insights.schema_migrations` as table name instead of `schema_migrations` in schema `sbo_insights`).

### Portal fails with "Access to path '/app/uploads/data-protection-keys' is denied"
The portal backend needs write access to the uploads directory mounted from `$DEPLOY_ROOT/uploads`. The install.sh script now checks this and prompts for sudo if needed. To fix manually:
```bash
sudo chmod -R 777 /path/to/deploy/uploads
sudo chown -R $(id -u):$(id -g) /path/to/deploy/uploads
```

## Directory Permissions

The following directories need to be writable by Docker containers:
- `uploads/` - Portal creates `data-protection-keys/` subdirectory at startup
- `logs/portal/` - Portal backend logs

## Module Environment Variables

### SBO Insights Module

**In `portal.env`:**
```bash
# -----------------------------------------------------------------------------
# SBO INSIGHTS MODULE
# -----------------------------------------------------------------------------
# Docker image settings
SBO_INSIGHTS_IMAGE=ghcr.io/ezy-ts/ezy-portal-sbo-insights
SBO_INSIGHTS_VERSION=1.0.0

# API Key (auto-provisioned by add-module.sh, or set manually)
SBO_INSIGHTS_API_KEY=<auto-provisioned>
```

**In `docker-compose.module-sbo-insights.yml`:**
The module uses these environment variables (most inherited from portal.env):

| Variable | Source | Description |
|----------|--------|-------------|
| `SBO_INSIGHTS_IMAGE` | portal.env | Docker image name |
| `SBO_INSIGHTS_VERSION` | portal.env | Image version/tag |
| `SBO_INSIGHTS_API_KEY` | portal.env | API key for portal auth |
| `DB_HOST`, `DB_PORT`, etc. | Shared | Database connection (uses postgres container) |
| `RABBITMQ_*` | Shared | RabbitMQ connection settings |
| `APPLICATION_URL` | Shared | Used for CORS allowed origins |
| `LOG_LEVEL` | Shared | Logging level (default: info) |

**Hardcoded in compose file:**
- `PORT=5009` - Internal service port
- `DB_SCHEMA=sbo_insights,public` - PostgreSQL schema
- `MICRO_SERVICE_ID=sboInsightsApp` - Service registration ID
- `SERVICE_URL=http://sbo-insights:5009` - Internal service URL

**SAP Data Source Configuration (SBO Insights specific):**

| Variable | Default | Description |
|----------|---------|-------------|
| `SBO_INSIGHTS_DATA_SOURCE` | `mssql` | Data source type: `mssql`, `hana`, or `artifact` |

**MSSQL Configuration (when DATA_SOURCE=mssql):**

| Variable | Default | Description |
|----------|---------|-------------|
| `SBO_INSIGHTS_MSSQL_SERVER` | `host.docker.internal` | SQL Server hostname |
| `SBO_INSIGHTS_MSSQL_PORT` | `1433` | SQL Server port |
| `SBO_INSIGHTS_MSSQL_USER` | `sa` | SQL Server username |
| `SBO_INSIGHTS_MSSQL_PASSWORD` | - | SQL Server password |
| `SBO_INSIGHTS_MSSQL_DATABASE` | - | SAP company database name |
| `SBO_INSIGHTS_MSSQL_ENCRYPT` | `disable` | TLS encryption mode |

**SAP HANA Configuration (when DATA_SOURCE=hana):**

| Variable | Default | Description |
|----------|---------|-------------|
| `SBO_INSIGHTS_HANA_HOST` | - | HANA server hostname |
| `SBO_INSIGHTS_HANA_PORT` | `30015` | HANA port |
| `SBO_INSIGHTS_HANA_USER` | - | HANA username |
| `SBO_INSIGHTS_HANA_PASSWORD` | - | HANA password |
| `SBO_INSIGHTS_HANA_DATABASE` | - | SAP company database |
| `SBO_INSIGHTS_HANA_TLS` | `false` | Enable TLS |

**Artifact Client Configuration (when DATA_SOURCE=artifact):**

| Variable | Default | Description |
|----------|---------|-------------|
| `SBO_INSIGHTS_ARTIFACT_BASE_URL` | - | On-premise artifact server URL |
| `SBO_INSIGHTS_ARTIFACT_API_KEY` | - | API key for artifact server |
| `SBO_INSIGHTS_ARTIFACT_TIMEOUT` | `30` | Request timeout in seconds |
| `SBO_INSIGHTS_ARTIFACT_INSECURE_SKIP_VERIFY` | `false` | Skip TLS verification |

### Other Modules

Similar pattern applies to other modules:
- `ITEMS_IMAGE`, `ITEMS_VERSION`, `ITEMS_API_KEY`
- `BP_IMAGE`, `BP_VERSION`, `BP_API_KEY`
- `PROSPECTS_IMAGE`, `PROSPECTS_VERSION`, `PROSPECTS_API_KEY`
- `PRICING_TAX_IMAGE`, `PRICING_TAX_VERSION`, `PRICING_TAX_API_KEY`
- `CRM_IMAGE`, `CRM_VERSION`, `CRM_API_KEY`
