# Adding Micro-Services to EZY Portal Deployment

This guide covers how to add new micro-frontend modules to a deployed EZY Portal instance.

## Overview

The EZY Portal uses a micro-frontend architecture where independent services can be hot-added to a running portal without downtime. Each micro-service:

- Runs as a separate Docker container
- Registers itself with the portal backend via the go-portal-sdk
- Serves its frontend assets via Module Federation
- Routes through nginx for unified access

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Nginx Gateway                            │
│                      (ports 80/443)                              │
├─────────────────────────────────────────────────────────────────┤
│  /api/*          → portal:8080      (Portal API)                │
│  /api/items/*    → items:5009       (Items API - rewritten)     │
│  /api/bp/*       → bp:3000          (BP API - rewritten)        │
│  /items_mfe/*    → items:5009       (Items Frontend Assets)     │
│  /bp_mfe/*       → bp:3000          (BP Frontend Assets)        │
│  /*              → portal:8080      (Portal Frontend)           │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

Before adding a micro-service, ensure you have:

1. **Docker image** - Either built locally or available in a container registry
2. **API key** - Generated from Portal Admin → API Keys
3. **Registration configuration** - The micro-service must have a `registration.yaml` file

## Step 1: Create Docker Compose Module File

Create a new compose file in `docker/docker-compose.module-{name}.yml`:

```yaml
# =============================================================================
# EZY Portal - {Name} Micro-Frontend Module
# =============================================================================
# Overlay file for the {Name} module.
# Use with: docker compose -f docker-compose.full.yml -f docker-compose.module-{name}.yml up -d
# =============================================================================

services:
  {name}:
    image: ${NAME_IMAGE:-ghcr.io/org/repo}:${VERSION:-latest}
    container_name: ${PROJECT_NAME:-ezy-portal}-{name}
    expose:
      - "{port}"
    environment:
      # Database (shared with portal)
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_USER=${POSTGRES_USER:-postgres}
      - DB_PASSWORD=${POSTGRES_PASSWORD}
      - DB_NAME=${POSTGRES_DB:-portal}
      - DB_SCHEMA={name},public

      # Portal Integration
      - PORTAL_API_URL=http://portal:8080
      - PORTAL_API_KEY=${NAME_API_KEY}
      - MICRO_SERVICE_ID={name}App

      # Server
      - PORT={port}

      # Service URL for registration (Docker network hostname)
      # CRITICAL: This must use the Docker network hostname, not localhost
      - SERVICE_URL=http://{name}:{port}

      # RabbitMQ (optional)
      - RABBITMQ_ENABLED=${RabbitMq__Enabled:-false}
      - RABBITMQ_HOST=${RabbitMq__Host:-rabbitmq}
      - RABBITMQ_PORT=${RabbitMq__Port:-5672}
      - RABBITMQ_USER=${RabbitMq__User:-portal}
      - RABBITMQ_PASSWORD=${RabbitMq__Password}
      - RABBITMQ_VHOST=/

    depends_on:
      portal:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "-", "http://localhost:{port}/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    restart: unless-stopped
    networks:
      - portal-network

networks:
  portal-network:
    external: true
    name: ${PROJECT_NAME:-ezy-portal}-network
```

### Critical Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `SERVICE_URL` | **CRITICAL** - Docker network URL for health checks. Portal validates this URL during registration. Must use container hostname, not `localhost`. | `http://items:5009` |
| `PORTAL_API_URL` | Portal backend URL for SDK communication | `http://portal:8080` |
| `PORTAL_API_KEY` | API key for service authentication | Generated from Admin UI |
| `MICRO_SERVICE_ID` | Unique identifier matching registration.yaml | `itemsApp` |

## Step 2: Configure Nginx Routes

Add routes to `nginx/conf.d/portal-https.conf`:

```nginx
# -------------------------------------------------------------------------
# {Name} Module
# -------------------------------------------------------------------------

# Health endpoint (specific - must come before general API location)
location = /api/{name}/health {
    set ${name}_backend "http://{name}:{port}";
    rewrite ^/api/{name}/health$ /health break;
    proxy_pass ${name}_backend;
    include snippets/proxy-headers-common.conf;
}

# {Name} API routes
location /api/{name}/ {
    set ${name}_backend "http://{name}:{port}";
    rewrite ^/api/{name}/(.*)$ /api/$1 break;
    proxy_pass ${name}_backend;
    include snippets/proxy-headers-common.conf;

    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Origin, Content-Type, Accept, Authorization" always;
}

# {Name} frontend static assets (Module Federation)
location /{name}_mfe/ {
    set ${name}_backend "http://{name}:{port}";
    proxy_pass ${name}_backend;
    include snippets/proxy-headers-common.conf;

    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
}
```

### Why Variables for Backend URLs?

Using `set $backend "http://..."` enables **lazy DNS resolution**. This allows nginx to start even if the micro-service container isn't running yet. Without variables, nginx would fail to start if it can't resolve the hostname at startup time.

### URL Rewriting Pattern

The pattern `rewrite ^/api/{name}/(.*)$ /api/$1 break;` transforms:
- External: `/api/items/products` → Internal: `/api/products`
- External: `/api/items/health` → Internal: `/health`

This allows micro-services to use clean `/api/*` routes internally while being namespaced externally.

## Step 3: Add API Key to portal.env

Generate an API key from Portal Admin UI, then add to `portal.env`:

```bash
# Module API Keys
ITEMS_API_KEY=your-generated-api-key-here
BP_API_KEY=
PROSPECTS_API_KEY=
```

For local development images, also add:

```bash
# Local images (comment out for GHCR images)
ITEMS_IMAGE=ezy-portal-items
BP_IMAGE=ezy-portal-bp
```

## Step 4: Add Module to add-module.sh

Update the `add-module.sh` script to recognize the new module:

```bash
# In get_module_dependencies()
case "$module" in
    items)
        echo ""  # No dependencies
        ;;
    bp)
        echo "items"  # BP depends on items
        ;;
    prospects)
        echo "bp"  # Prospects depends on BP (which depends on items)
        ;;
    {name})
        echo "{dependencies}"  # Add your module's dependencies
        ;;
esac
```

## Step 5: Deploy the Module

### Option A: Using add-module.sh (Recommended)

```bash
# Add module using GHCR image
./add-module.sh {name}

# Add module using local image
./add-module.sh {name} --local
```

### Option B: Manual Docker Compose

```bash
# Load environment variables
set -a && source portal.env && set +a

# Start the module
docker compose \
  -f docker/docker-compose.full.yml \
  -f docker/docker-compose.module-{name}.yml \
  up -d {name}
```

### Option C: Recreate existing module

```bash
set -a && source portal.env && set +a

docker compose \
  -f docker/docker-compose.full.yml \
  -f docker/docker-compose.module-{name}.yml \
  up -d --force-recreate {name}
```

## Step 6: Verify Registration

Check the module logs for successful registration:

```bash
docker logs ${PROJECT_NAME}-{name} --tail 50
```

Look for:
```
✅ Micro-service registered successfully with portal  id=xxx name={name}App
```

Verify health endpoint:
```bash
curl -k https://localhost/api/{name}/health
```

Verify frontend assets:
```bash
curl -k -I https://localhost/{name}_mfe/remoteEntry.js
```

## Troubleshooting

### Registration fails with "Invalid operation" (400)

**Cause**: The micro-service record doesn't exist in the portal database yet.

**Solution**: The SDK retries registration. On first attempt, portal creates the record. If it persists, check API key validity.

### Health check fails with "Connection refused (localhost:PORT)"

**Cause**: `SERVICE_URL` environment variable is missing or set to `localhost`.

**Solution**: Set `SERVICE_URL=http://{container-name}:{port}` in the compose file. The portal backend runs in a separate container and cannot reach `localhost` of the micro-service.

### Nginx returns 502 Bad Gateway

**Cause**: Micro-service container isn't running or isn't healthy.

**Solution**:
```bash
docker ps | grep {name}
docker logs ${PROJECT_NAME}-{name}
```

### Health check returns 404

**Cause**: Health endpoint not configured or wrong HTTP method.

**Solution**:
- Ensure `/health` endpoint exists and responds to GET requests
- Use `wget -q -O -` (GET) instead of `wget --spider` (HEAD) in healthcheck

### Frontend assets return 404

**Cause**: Static file serving not configured or wrong path.

**Solution**: Verify the micro-service serves files at `/{name}_mfe/` path and `remoteEntry.js` exists.

### Database table doesn't exist

**Cause**: Migrations haven't run for the new schema.

**Solution**: Run database migrations for the micro-service or check schema configuration.

## Module Dependency Chain

Current dependencies:
```
items (no dependencies)
   └── bp (depends on items)
       └── prospects (depends on bp)
```

When adding a module with dependencies, ensure dependent modules are running first. The `add-module.sh` script handles this automatically.

## Checklist

- [ ] Docker compose module file created
- [ ] `SERVICE_URL` environment variable set to Docker network hostname
- [ ] Nginx routes configured with lazy DNS resolution
- [ ] API key generated and added to portal.env
- [ ] Local image name added to portal.env (if using local images)
- [ ] Module added to add-module.sh dependency resolver
- [ ] Registration successful in logs
- [ ] Health endpoint accessible via nginx
- [ ] Frontend assets (remoteEntry.js) accessible
- [ ] Module appears in portal navigation
