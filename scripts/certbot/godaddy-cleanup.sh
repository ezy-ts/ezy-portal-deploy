#!/bin/bash
# =============================================================================
# Certbot GoDaddy DNS Cleanup Hook
# =============================================================================
# Removes _acme-challenge TXT record after Let's Encrypt validation completes.
# Used as --manual-cleanup-hook for certbot wildcard certificates.
#
# Environment variables (from godaddy-credentials.env):
#   GODADDY_API_KEY     - GoDaddy API key
#   GODADDY_API_SECRET  - GoDaddy API secret
#   GODADDY_DOMAIN      - Domain name (e.g., ezyts.com)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source credentials
if [[ -f "$SCRIPT_DIR/godaddy-credentials.env" ]]; then
    source "$SCRIPT_DIR/godaddy-credentials.env"
else
    echo "ERROR: godaddy-credentials.env not found at $SCRIPT_DIR" >&2
    exit 1
fi

# Validate required variables
if [[ -z "$GODADDY_API_KEY" ]] || [[ -z "$GODADDY_API_SECRET" ]]; then
    echo "ERROR: GODADDY_API_KEY and GODADDY_API_SECRET must be set" >&2
    exit 1
fi

DOMAIN="${GODADDY_DOMAIN:-$CERTBOT_DOMAIN}"
RECORD="_acme-challenge"

echo "Removing DNS TXT record: $RECORD.$DOMAIN"

# Delete the TXT record
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X DELETE "https://api.godaddy.com/v1/domains/$DOMAIN/records/TXT/$RECORD" \
    -H "Authorization: sso-key $GODADDY_API_KEY:$GODADDY_API_SECRET")

if [[ "$HTTP_CODE" -ge 200 ]] && [[ "$HTTP_CODE" -lt 300 ]]; then
    echo "TXT record deleted successfully (HTTP $HTTP_CODE)"
elif [[ "$HTTP_CODE" -eq 404 ]]; then
    echo "TXT record not found (already deleted)"
else
    echo "WARNING: Failed to delete TXT record (HTTP $HTTP_CODE)" >&2
    # Don't fail - the record will expire anyway
fi

echo "DNS cleanup hook completed"
