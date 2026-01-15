#!/bin/bash
# =============================================================================
# Certbot Deploy Hook - Sync Certificates to EZY Portal
# =============================================================================
# Copies renewed Let's Encrypt certificates to the portal's nginx/ssl directory
# and reloads the nginx container to apply them.
#
# Used as --deploy-hook for certbot.
#
# Certbot provides:
#   RENEWED_LINEAGE     - Path to renewed certificate (e.g., /etc/letsencrypt/live/ezyts.com)
#   RENEWED_DOMAINS     - Space-separated list of renewed domains
#
# Configuration:
#   DEPLOY_ROOT         - Path to deploy directory (auto-detected if not set)
#   NGINX_CONTAINER     - Container name (default: auto-detect from PROJECT_NAME)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect deploy root (scripts/certbot -> deploy root)
DEPLOY_ROOT="${DEPLOY_ROOT:-$(dirname "$(dirname "$SCRIPT_DIR")")}"

# Source portal.env for PROJECT_NAME if available
if [[ -f "$DEPLOY_ROOT/portal.env" ]]; then
    source "$DEPLOY_ROOT/portal.env" 2>/dev/null || true
fi

# Determine nginx container name
NGINX_CONTAINER="${NGINX_CONTAINER:-${PROJECT_NAME:-ezy-portal}-nginx}"

# Certificate paths (certbot provides RENEWED_LINEAGE)
CERT_SOURCE="${RENEWED_LINEAGE:-/etc/letsencrypt/live/ezyts.com}"
SSL_DEST="$DEPLOY_ROOT/nginx/ssl"

echo "=============================================="
echo "EZY Portal Certificate Deploy Hook"
echo "=============================================="
echo "Source: $CERT_SOURCE"
echo "Destination: $SSL_DEST"
echo "Container: $NGINX_CONTAINER"
echo ""

# Validate source certificates exist
if [[ ! -f "$CERT_SOURCE/fullchain.pem" ]]; then
    echo "ERROR: Certificate not found: $CERT_SOURCE/fullchain.pem" >&2
    exit 1
fi

if [[ ! -f "$CERT_SOURCE/privkey.pem" ]]; then
    echo "ERROR: Private key not found: $CERT_SOURCE/privkey.pem" >&2
    exit 1
fi

# Ensure destination directory exists
mkdir -p "$SSL_DEST"

# Copy certificates
echo "Copying certificates..."
cp "$CERT_SOURCE/fullchain.pem" "$SSL_DEST/server.crt"
cp "$CERT_SOURCE/privkey.pem" "$SSL_DEST/server.key"

# Set permissions
chmod 644 "$SSL_DEST/server.crt"
chmod 600 "$SSL_DEST/server.key"

echo "Certificates copied successfully"

# Reload nginx container
echo "Reloading nginx container..."
if docker ps --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER}$"; then
    docker exec "$NGINX_CONTAINER" nginx -s reload
    echo "Nginx reloaded successfully"
else
    echo "WARNING: Nginx container '$NGINX_CONTAINER' not running" >&2
    echo "Certificates updated but nginx not reloaded" >&2
fi

echo ""
echo "Deploy hook completed successfully"
echo "Certificate valid until: $(openssl x509 -enddate -noout -in "$SSL_DEST/server.crt" | cut -d= -f2)"
