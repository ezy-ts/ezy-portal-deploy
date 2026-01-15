#!/bin/bash
# =============================================================================
# Certbot GoDaddy DNS Authentication Hook
# =============================================================================
# Creates _acme-challenge TXT record for Let's Encrypt DNS-01 validation.
# Used as --manual-auth-hook for certbot wildcard certificates.
#
# Environment variables (from godaddy-credentials.env):
#   GODADDY_API_KEY     - GoDaddy API key
#   GODADDY_API_SECRET  - GoDaddy API secret
#   GODADDY_DOMAIN      - Domain name (e.g., ezyts.com)
#
# Certbot provides:
#   CERTBOT_DOMAIN      - Domain being validated
#   CERTBOT_VALIDATION  - Validation string to set as TXT record
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source credentials
if [[ -f "$SCRIPT_DIR/godaddy-credentials.env" ]]; then
    source "$SCRIPT_DIR/godaddy-credentials.env"
else
    echo "ERROR: godaddy-credentials.env not found at $SCRIPT_DIR" >&2
    echo "Copy godaddy-credentials.env.example and fill in your credentials." >&2
    exit 1
fi

# Validate required variables
if [[ -z "$GODADDY_API_KEY" ]] || [[ -z "$GODADDY_API_SECRET" ]]; then
    echo "ERROR: GODADDY_API_KEY and GODADDY_API_SECRET must be set" >&2
    exit 1
fi

DOMAIN="${GODADDY_DOMAIN:-$CERTBOT_DOMAIN}"
RECORD="_acme-challenge"
DATA="$CERTBOT_VALIDATION"

echo "Setting DNS TXT record for $RECORD.$DOMAIN"
echo "Validation value: $DATA"

# Create/Update the TXT record
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "https://api.godaddy.com/v1/domains/$DOMAIN/records/TXT/$RECORD" \
    -H "Authorization: sso-key $GODADDY_API_KEY:$GODADDY_API_SECRET" \
    -H "Content-Type: application/json" \
    -d "[{\"data\":\"$DATA\",\"ttl\":600}]")

if [[ "$HTTP_CODE" -ge 200 ]] && [[ "$HTTP_CODE" -lt 300 ]]; then
    echo "TXT record created/updated successfully (HTTP $HTTP_CODE)"
else
    echo "ERROR: Failed to set TXT record (HTTP $HTTP_CODE)" >&2
    exit 1
fi

# Wait for DNS propagation
echo "Waiting 60 seconds for DNS propagation..."
sleep 60

echo "DNS authentication hook completed"
