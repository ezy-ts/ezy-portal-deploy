#!/bin/bash
# =============================================================================
# EZY Portal - Add Module Script
# =============================================================================
# Hot-add a micro-frontend module to a running portal installation.
#
# Usage:
#   ./add-module.sh items                     # Add items module (auto-provision key)
#   ./add-module.sh bp                        # Add bp module (requires items)
#   ./add-module.sh prospects                 # Add prospects module (requires bp)
#   ./add-module.sh items --api-key <key>     # Use explicit API key
#
# API Key Provisioning:
#   If --api-key is not provided, the script will auto-provision an API key
#   using DEPLOYMENT_SECRET (generated during install.sh).
#
# The portal must be running before adding modules.
# =============================================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_ROOT="$SCRIPT_DIR"

# Source library scripts
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/checks.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/api-keys.sh"
source "$SCRIPT_DIR/lib/module-installer.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
MODULE=""
API_KEY=""
VERSION="${VERSION:-latest}"
RESTART_MODE=false

# Module dependencies (all modules are independent)
declare -A MODULE_DEPENDENCIES=(
    ["items"]=""
    ["bp"]=""
    ["prospects"]=""
    ["pricing-tax"]=""
    ["crm"]=""
)

# API key variable names
declare -A MODULE_API_KEY_VARS=(
    ["items"]="ITEMS_API_KEY"
    ["bp"]="BP_API_KEY"
    ["prospects"]="PROSPECTS_API_KEY"
    ["pricing-tax"]="PRICING_TAX_API_KEY"
    ["crm"]="CRM_API_KEY"
)

# Modules with separated frontend artifacts (downloaded separately from backend)
declare -A MODULE_HAS_FRONTEND=(
    ["items"]="true"
    ["bp"]="true"
    ["prospects"]="true"
    ["pricing-tax"]="true"
    ["crm"]="true"
)

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
parse_arguments() {
    if [[ $# -lt 1 ]]; then
        show_help
        exit 1
    fi

    MODULE="$1"
    shift

    # Validate module name
    if [[ ! "$MODULE" =~ ^(items|bp|prospects|pricing-tax|crm)$ ]]; then
        print_error "Invalid module: $MODULE"
        print_info "Available modules: items, bp, prospects, pricing-tax, crm"
        exit 1
    fi

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --api-key)
                API_KEY="$2"
                shift 2
                ;;
            --version)
                VERSION="$2"
                shift 2
                ;;
            --restart|-r)
                RESTART_MODE=true
                shift
                ;;
            --debug)
                DEBUG=true
                export DEBUG
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

show_help() {
    echo "EZY Portal - Add Module"
    echo ""
    echo "Usage: ./add-module.sh <module> [OPTIONS]"
    echo ""
    echo "Modules:"
    echo "  items        Items micro-frontend (base module)"
    echo "  bp           Business Partners (requires: items)"
    echo "  prospects    Prospects (requires: bp, items)"
    echo "  pricing-tax  Pricing & Tax module (separated frontend/backend)"
    echo "  crm          CRM module (sales pipeline management)"
    echo ""
    echo "Options:"
    echo "  --api-key KEY    API key for the module (optional - auto-provisioned if not provided)"
    echo "  --version VER    Image version tag (default: latest)"
    echo "  --restart, -r    Restart module to reload portal.env configuration"
    echo "  --debug          Enable debug output"
    echo "  --help, -h       Show this help message"
    echo ""
    echo "API Key Provisioning:"
    echo "  If --api-key is not provided, the script will:"
    echo "    1. Use existing key from portal.env (if present)"
    echo "    2. Auto-provision via DEPLOYMENT_SECRET (if configured)"
    echo "    3. Prompt for manual key generation"
    echo ""
    echo "Examples:"
    echo "  ./add-module.sh items                      # Auto-provision API key"
    echo "  ./add-module.sh items --api-key abc123     # Use explicit API key"
    echo "  ./add-module.sh bp --version 1.0.2         # Specific version"
    echo "  ./add-module.sh pricing-tax --version 1.0.0 # Add pricing-tax module"
    echo "  ./add-module.sh items --restart            # Restart to reload config"
}

# -----------------------------------------------------------------------------
# Module Configuration
# -----------------------------------------------------------------------------

# Add module to MODULES list in portal.env if not already present
add_module_to_config() {
    local module="$1"
    local config_file="${DEPLOY_ROOT}/portal.env"

    # Get current MODULES value
    local current_modules
    current_modules=$(grep "^MODULES=" "$config_file" 2>/dev/null | cut -d'=' -f2)

    if [[ -z "$current_modules" ]]; then
        # MODULES not set, create it
        save_config_value "MODULES" "portal,$module" "$config_file"
        print_info "Added MODULES=portal,$module to config"
    elif [[ ! ",$current_modules," =~ ",$module," ]]; then
        # Module not in list, add it
        local new_modules="${current_modules},$module"
        save_config_value "MODULES" "$new_modules" "$config_file"
        print_info "Added '$module' to MODULES list"
    else
        debug "Module '$module' already in MODULES list"
    fi
}

# -----------------------------------------------------------------------------
# Module-specific Checks
# -----------------------------------------------------------------------------
check_module_dependencies_for() {
    local module="$1"
    local deps="${MODULE_DEPENDENCIES[$module]}"

    if [[ -z "$deps" ]]; then
        return 0
    fi

    check_module_dependencies "$deps"
}

check_module_not_running() {
    local module="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-${module}"

    check_not_running "$container"
}

# -----------------------------------------------------------------------------
# API Key Handling (uses lib/api-keys.sh)
# -----------------------------------------------------------------------------
handle_api_key() {
    local module="$1"
    local api_key="$2"
    local var_name="${MODULE_API_KEY_VARS[$module]}"

    get_or_provision_api_key "$module" "$var_name" "$api_key"
}

# -----------------------------------------------------------------------------
# Container Operations
# -----------------------------------------------------------------------------
stop_module() {
    local module="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-${module}"

    debug "Stopping container: $container"

    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_info "Stopping container: $container"
        docker stop "$container" 2>/dev/null || true
        docker rm "$container" 2>/dev/null || true
        print_success "Container stopped"
    fi
}

check_module_is_running() {
    local module="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-${module}"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_error "Module '$module' is not running"
        print_info "Cannot restart a module that is not running"
        print_info "Use: ./add-module.sh $module (without --restart) to add it"
        return 1
    fi
    return 0
}

start_module() {
    local module="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"

    # Load config to get infrastructure mode
    load_config "$DEPLOY_ROOT/portal.env"

    local infra_mode="${INFRASTRUCTURE_MODE:-full}"

    # Build compose file arguments
    local base_compose
    base_compose=$(get_compose_file "$infra_mode")

    local module_compose="$DEPLOY_ROOT/docker/docker-compose.module-${module}.yml"

    if [[ ! -f "$module_compose" ]]; then
        print_error "Module compose file not found: $module_compose"
        return 1
    fi

    # Include dependency compose files in order
    local compose_args="-f $base_compose"
    local ordered_modules=("items" "bp" "prospects" "pricing-tax" "crm")

    for m in "${ordered_modules[@]}"; do
        local m_compose="$DEPLOY_ROOT/docker/docker-compose.module-${m}.yml"
        if [[ -f "$m_compose" ]]; then
            # Include if it's the target module or a running dependency
            local container="${project_name}-${m}"
            if [[ "$m" == "$module" ]] || docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                compose_args="$compose_args -f $m_compose"
                # Add limits overlay for this module if high-performance mode
                if [[ "${PERF_MODE:-}" == "high" ]]; then
                    local limits_file="$DEPLOY_ROOT/docker/docker-compose.module-${m}-limits.yml"
                    if [[ -f "$limits_file" ]]; then
                        compose_args="$compose_args -f $limits_file"
                    fi
                fi
            fi
        fi
        [[ "$m" == "$module" ]] && break
    done

    # Set image environment variable
    local image
    image=$(get_module_image "$module")
    local var_name
    # Convert to uppercase and replace hyphens with underscores for valid bash variable names
    var_name="$(echo "${module}_IMAGE" | tr '[:lower:]-' '[:upper:]_')"
    export "$var_name=$image"

    print_info "Starting module: $module"
    print_info "Image: $image:$VERSION"

    # Use --no-recreate to avoid touching existing containers (portal, infra)
    # Use --pull always for 'latest' to ensure we get the newest images
    local pull_flag=""
    if [[ "$VERSION" == "latest" ]]; then
        pull_flag="--pull always"
    fi

    local cmd="docker compose $compose_args --env-file $DEPLOY_ROOT/portal.env up -d --no-recreate $pull_flag $module"
    log_info "Running: $cmd"

    if eval "$cmd"; then
        print_success "Module '$module' started"
        return 0
    else
        print_error "Failed to start module '$module'"
        return 1
    fi
}

wait_for_module_healthy() {
    local module="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-${module}"

    wait_for_container_healthy "$container" 120
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    init_logging
    parse_arguments "$@"

    # Load existing config
    if [[ -f "$DEPLOY_ROOT/portal.env" ]]; then
        load_config "$DEPLOY_ROOT/portal.env"
    else
        print_error "portal.env not found. Run ./install.sh first."
        exit 1
    fi

    # Restart mode: simplified flow
    if [[ "$RESTART_MODE" == "true" ]]; then
        echo ""
        print_section "Restarting Module: $MODULE"

        # Check module is running
        check_module_is_running "$MODULE" || exit 1

        # Stop and start
        print_info "Reloading configuration from portal.env..."
        stop_module "$MODULE"
        start_module "$MODULE"

        # Wait for healthy
        wait_for_module_healthy "$MODULE" || true

        echo ""
        print_success "Restart complete! $MODULE reloaded with new configuration"
        log_info "Module restarted: $MODULE"
        exit 0
    fi

    # Normal add mode
    echo ""
    print_section "Adding Module: $MODULE"

    # Pre-flight checks
    print_section "Prerequisites"
    check_docker_installed || exit 1
    check_docker_running || exit 1
    check_portal_running || exit 1
    check_module_dependencies_for "$MODULE" || exit 1
    check_module_not_running "$MODULE"

    # Handle API key
    handle_api_key "$MODULE" "$API_KEY" || exit 1

    # Pull/verify image
    print_section "Preparing Image"
    if ! docker_pull_image "$VERSION" "$MODULE"; then
        exit 1
    fi

    # Download frontend artifact for modules with separated frontend
    if [[ "${MODULE_HAS_FRONTEND[$MODULE]:-false}" == "true" ]]; then
        print_section "Installing Frontend"
        source "$SCRIPT_DIR/lib/frontend.sh"
        if ! download_mff_module "$MODULE" "${FRONTEND_VERSION:-$VERSION}"; then
            print_error "Failed to install ${MODULE} frontend"
            exit 1
        fi
        # Reload nginx to pick up new static files
        reload_nginx || true
    fi

    # Start the module
    print_section "Starting Module"
    if ! start_module "$MODULE"; then
        exit 1
    fi

    # Wait for healthy
    wait_for_module_healthy "$MODULE" || true

    # Add module to MODULES list in portal.env
    add_module_to_config "$MODULE"

    # Success
    local app_url="${APPLICATION_URL:-https://localhost}"
    echo ""
    print_success "Module '$MODULE' added successfully!"
    echo ""
    echo "  Module URL: $app_url/mfe/$MODULE/"
    echo "  Container:  ${PROJECT_NAME:-ezy-portal}-$MODULE"
    echo "  Logs:       docker logs ${PROJECT_NAME:-ezy-portal}-$MODULE"
    echo ""

    log_info "Module added: $MODULE"
}

main "$@"
