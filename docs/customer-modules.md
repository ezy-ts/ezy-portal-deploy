# Customer Modules

This guide explains how to install, manage, and remove customer-specific micro-service modules.

## Prerequisites

Before installing customer modules, ensure:

1. **Portal is running** - The core portal must be installed and healthy
2. **yq installed** - Required for parsing module manifests
3. **jq installed** - Recommended for module registry management

```bash
# Install yq
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

# Install jq and unzip
# Debian/Ubuntu:
sudo apt install jq unzip

# Fedora/RHEL:
sudo dnf install jq unzip
```

---

## Installing a Customer Module

### Option 1: From GitHub Release (Recommended)

If the customer module is published to GitHub with release assets:

```bash
# Install latest version
./add-customer-module.sh ezy-ts/red-cloud-quotation-tool

# Install specific version
./add-customer-module.sh ezy-ts/red-cloud-quotation-tool --version v1.0.0

# With explicit API key
./add-customer-module.sh ezy-ts/red-cloud-quotation-tool --api-key your-api-key
```

### Option 2: From Local Package File

If you have a deployment package file (`.tar.gz`, `.tgz`, or `.zip`):

```bash
# Install directly from zip or tarball
cd /path/to/ezy-portal-deploy
./add-customer-module.sh --from-file /path/to/red-cloud-quotation-tool-1.0.0.zip

# Or from tarball
./add-customer-module.sh --from-file /path/to/red-cloud-quotation-tool-1.0.0.tar.gz
```

### Option 3: Using Local Docker Image

For development or when the Docker image is built locally:

```bash
# Build the image locally first
cd /path/to/customer-module
docker build -f deploy/Dockerfile.unified -t ghcr.io/ezy-ts/red-cloud-quotation-tool:latest .

# Install with --local flag
./add-customer-module.sh --from-file /tmp/package.tar.gz --local
```

---

## Installation Steps

The `add-customer-module.sh` script performs these steps automatically:

1. **Download/Extract** - Gets the deployment package
2. **Parse Manifest** - Reads `module-manifest.yaml` for configuration
3. **Check Dependencies** - Verifies required modules are running
4. **Pull Image** - Downloads Docker image from registry
5. **Configure Nginx** - Installs routing configuration
6. **Install Compose** - Copies Docker Compose service definition
7. **Provision API Key** - Auto-provisions or uses provided key
8. **Start Module** - Starts the container
9. **Reload Nginx** - Applies routing changes
10. **Health Check** - Waits for module to be healthy

---

## Managing Customer Modules

### List Installed Modules

```bash
# Table format
./list-customer-modules.sh

# JSON format
./list-customer-modules.sh --json
```

Output:
```
MODULE                         VERSION         STATUS       REPOSITORY
------                         -------         ------       ----------
red-cloud-quotation-tool       1.0.0           healthy      ezy-ts/red-cloud-quotation-tool
```

### View Module Logs

```bash
docker logs ezy-portal-red-cloud-quotation-tool
docker logs -f ezy-portal-red-cloud-quotation-tool  # Follow logs
```

### Check Module Health

```bash
# Container health
docker inspect --format='{{.State.Health.Status}}' ezy-portal-red-cloud-quotation-tool

# HTTP health check
curl -k https://localhost/api/red-cloud-quotation-tool/health
```

---

## Removing a Customer Module

```bash
# Interactive (with confirmation)
./remove-customer-module.sh red-cloud-quotation-tool

# Force removal (no confirmation)
./remove-customer-module.sh red-cloud-quotation-tool --force
```

**Note:** Removal does NOT drop the database schema for safety. To remove data:

```sql
-- Connect to PostgreSQL and run:
DROP SCHEMA IF EXISTS red_cloud_quotation_tool CASCADE;
```

---

## Deployment Package Structure

Customer modules are distributed as tarballs containing:

```
module-name-1.0.0.tar.gz
├── module-manifest.yaml      # Required: Module configuration
├── docker-compose.module.yml # Required: Service definition
├── nginx/                    # Optional: Custom nginx configs (unified only)
│   └── module-locations.conf
└── README.md                 # Optional: Installation notes
```

## Architecture Types

Customer modules support two architecture types:

### Unified Architecture (v1.0)
A single Docker container serves both the backend API and frontend MFE. This is the traditional approach.

### Separated Architecture (v1.1)
The backend runs in a Docker container and the frontend is downloaded as a separate artifact (zip file) and served as static files. This architecture:
- Reduces container size
- Enables independent frontend/backend versioning
- Improves static file serving performance
- Follows the same pattern as standard modules (items, bp, prospects)

## Module Manifest Examples

### Unified Architecture (v1.0)

```yaml
version: "1.0"

module:
  name: example-module
  displayName: Example Module
  moduleVersion: "1.0.0"

  # Single container serves both API and MFE
  image:
    repository: ghcr.io/ezy-ts/example-module
    tag: "1.0.0"

  port: 5012
  healthEndpoint: /health

  database:
    schema: example_module

  dependencies:
    modules: []  # e.g., ["items", "bp"]

  environment:
    apiKeyEnvVar: EXAMPLE_MODULE_API_KEY

  routing:
    apiPrefix: /api/example-module
    mfePrefix: /example-module_mfe

# Optional: Custom nginx configs
nginx:
  customConfigs:
    - source: nginx/module-locations.conf
      target: conf.d/customer/example-module.conf
```

### Separated Architecture (v1.1) - Recommended

```yaml
version: "1.1"

module:
  name: red-cloud-quotation-tool
  displayName: Quotation Tool
  moduleVersion: "1.0.0"

  # Backend and frontend are separate
  architecture: separated

  # Backend (Docker container)
  backend:
    image:
      repository: ghcr.io/ezy-ts/red-cloud-quotation-tool
      tag: "1.0.0"
    port: 5012
    healthEndpoint: /health

  # Frontend (static files downloaded from release)
  frontend:
    artifactPattern: "red-cloud-quotation-tool-frontend-{version}.zip"
    repository: "ezy-ts/red-cloud-quotation-tool"
    mffDir: "red-cloud-quotation-tool"

  database:
    schema: red_cloud_quotation_tool

  dependencies:
    modules: []
    services:
      - report-generator-api

  environment:
    apiKeyEnvVar: RED_CLOUD_QUOTATION_TOOL_API_KEY

  routing:
    apiPrefix: /api/red-cloud-quotation-tool
    mfePrefix: /red-cloud-quotation-tool_mfe

# Nginx config is auto-generated for separated architecture:
# - API routes proxy to backend container
# - MFE served from static files in /dist/mff/{mffDir}/
```

---

## Troubleshooting

### Module not starting

```bash
# Check container logs
docker logs ezy-portal-red-cloud-quotation-tool

# Check if dependencies are running
docker ps | grep -E 'portal|items|bp'
```

### API key issues

```bash
# Check if API key is set in portal.env
grep RED_CLOUD_QUOTATION_TOOL_API_KEY portal.env

# Re-provision API key
./add-customer-module.sh --from-file package.tar.gz --api-key new-key
```

### Nginx configuration errors

```bash
# Test nginx config
docker exec ezy-portal-nginx nginx -t

# Check customer nginx configs
ls -la nginx/conf.d/customer/

# View generated config
cat nginx/conf.d/customer/red-cloud-quotation-tool.conf
```

### Module not accessible

```bash
# Check nginx is routing correctly
curl -k https://localhost/api/red-cloud-quotation-tool/health

# Check container is on the right network
docker network inspect ezy-portal-network | grep red-cloud
```

---

## API Key Management

Customer modules authenticate with the portal using API keys. Keys can be:

1. **Auto-provisioned** - Uses `DEPLOYMENT_SECRET` to call portal API
2. **Manually provided** - Via `--api-key` flag
3. **Pre-configured** - Set in `portal.env` before installation

The API key environment variable name is defined in the manifest's `environment.apiKeyEnvVar` field.
