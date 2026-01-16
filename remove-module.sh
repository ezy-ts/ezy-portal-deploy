#!/bin/bash
# =============================================================================
# EZY Portal - Remove Module Script
# =============================================================================
# Remove a built-in micro-frontend module (items, bp, prospects)
#
# Usage:
#   ./remove-module.sh items                # Remove items module
#   ./remove-module.sh bp --remove-key      # Remove bp and its API key
#   ./remove-module.sh prospects --force    # Skip confirmation
#
# Note: This does NOT drop the database schema for safety.
# =============================================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_ROOT="$SCRIPT_DIR"

# Source library scripts
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/docker.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
MODULE=""
FORCE=false
REMOVE_KEY=false

# Reverse dependency map (module -> modules that depend on it)
declare -A REVERSE_DEPENDENCIES=(
    ["items"]="bp"
    ["bp"]="prospects"
    ["prospects"]=""
    ["pricing-tax"]=""
    ["crm"]=""
    ["sbo-insights"]=""
)

# API key variable names
declare -A MODULE_API_KEY_VARS=(
    ["items"]="ITEMS_API_KEY"
    ["bp"]="BP_API_KEY"
    ["prospects"]="PROSPECTS_API_KEY"
    ["pricing-tax"]="PRICING_TAX_API_KEY"
    ["crm"]="CRM_API_KEY"
    ["sbo-insights"]="SBO_INSIGHTS_API_KEY"
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
    if [[ ! "$MODULE" =~ ^(items|bp|prospects|pricing-tax|crm|sbo-insights)$ ]]; then
        print_error "Invalid module: $MODULE"
        print_info "Available modules: items, bp, prospects, pricing-tax, crm, sbo-insights"
        exit 1
    fi

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --force|-f)
                FORCE=true
                shift
                ;;
            --remove-key)
                REMOVE_KEY=true
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
    echo "EZY Portal - Remove Module"
    echo ""
    echo "Usage: ./remove-module.sh <module> [OPTIONS]"
    echo ""
    echo "Modules:"
    echo "  items        Items micro-frontend (base module)"
    echo "  bp           Business Partners (requires: items)"
    echo "  prospects    Prospects (requires: bp, items)"
    echo "  pricing-tax  Pricing & Tax module"
    echo "  crm          CRM module (sales pipeline management)"
    echo "  sbo-insights SBO Insights module (price lists, analytics)"
    echo ""
    echo "Options:"
    echo "  --force, -f     Skip confirmation prompt"
    echo "  --remove-key    Also remove API key from portal.env"
    echo "  --debug         Enable debug output"
    echo "  --help, -h      Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./remove-module.sh prospects              # Remove prospects"
    echo "  ./remove-module.sh bp --remove-key        # Remove bp and its API key"
    echo "  ./remove-module.sh items --force          # Force remove items"
    echo ""
    echo "Note: This command does NOT drop the database schema for safety."
    echo "      Modules must be removed in reverse order (prospects → bp → items)"
}

# -----------------------------------------------------------------------------
# Checks
# -----------------------------------------------------------------------------
check_reverse_dependencies() {
    local module="$1"
    local deps="${REVERSE_DEPENDENCIES[$module]}"
    local project_name="${PROJECT_NAME:-ezy-portal}"

    if [[ -z "$deps" ]]; then
        return 0
    fi

    debug "Checking reverse dependencies for $module: $deps"

    # Check if any dependent module is running
    local container="${project_name}-${deps}"
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_error "Cannot remove '$module' - module '$deps' depends on it and is running"
        print_info "Remove '$deps' first with: ./remove-module.sh $deps"
        return 1
    fi

    return 0
}

check_module_running() {
    local module="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-${module}"

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        print_warning "Module '$module' container not found"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Configuration Operations
# -----------------------------------------------------------------------------

# Remove module from MODULES list in portal.env
remove_module_from_config() {
    local module="$1"
    local config_file="${DEPLOY_ROOT}/portal.env"

    # Get current MODULES value
    local current_modules
    current_modules=$(grep "^MODULES=" "$config_file" 2>/dev/null | cut -d'=' -f2)

    if [[ -z "$current_modules" ]]; then
        return 0
    fi

    # Check if module is in the list
    if [[ ",$current_modules," =~ ",$module," ]]; then
        # Remove the module from the list
        local new_modules
        new_modules=$(echo "$current_modules" | sed -e "s/,$module,/,/g" -e "s/^$module,//" -e "s/,$module$//" -e "s/^$module$//")
        save_config_value "MODULES" "$new_modules" "$config_file"
        print_info "Removed '$module' from MODULES list"
    else
        debug "Module '$module' not in MODULES list"
    fi
}

# -----------------------------------------------------------------------------
# Removal Operations
# -----------------------------------------------------------------------------
stop_module() {
    local module="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-${module}"

    debug "Stopping container: $container"

    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        print_info "Stopping container: $container"
        docker stop "$container" 2>/dev/null || true
        docker rm "$container" 2>/dev/null || true
        print_success "Container stopped and removed"
    else
        print_info "Container not found (already removed)"
    fi
}

remove_api_key() {
    local module="$1"
    local var_name="${MODULE_API_KEY_VARS[$module]}"
    local config_file="$DEPLOY_ROOT/portal.env"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    if grep -q "^${var_name}=" "$config_file" 2>/dev/null; then
        sed -i "/^${var_name}=/d" "$config_file"
        print_success "Removed $var_name from portal.env"
    else
        print_info "No API key found in portal.env"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    init_logging
    parse_arguments "$@"

    echo ""
    print_section "Removing Module: $MODULE"

    # Load existing config
    if [[ -f "$DEPLOY_ROOT/portal.env" ]]; then
        load_config "$DEPLOY_ROOT/portal.env"
    fi

    # Check reverse dependencies
    check_reverse_dependencies "$MODULE" || exit 1

    # Check if module exists
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-${MODULE}"

    # Confirm removal
    if [[ "$FORCE" != "true" ]]; then
        echo ""
        print_warning "This will:"
        echo "  - Stop and remove the container: $container"
        if [[ "$REMOVE_KEY" == "true" ]]; then
            echo "  - Remove API key from portal.env"
        else
            echo "  - Keep API key in portal.env (use --remove-key to remove)"
        fi
        echo ""
        print_info "This will NOT drop the database schema"
        echo ""
        if ! confirm "Remove module '$MODULE'?" "n"; then
            print_info "Removal cancelled"
            exit 0
        fi
    fi

    # Stop the container
    print_subsection "Stopping Container"
    stop_module "$MODULE"

    # Remove from MODULES list
    print_subsection "Updating Configuration"
    remove_module_from_config "$MODULE"

    # Remove API key if requested
    if [[ "$REMOVE_KEY" == "true" ]]; then
        print_subsection "Removing API Key"
        remove_api_key "$MODULE"
    fi

    # Success
    echo ""
    print_section "Removal Complete"
    print_success "Module '$MODULE' has been removed"
    echo ""
    if [[ "$REMOVE_KEY" != "true" ]]; then
        print_info "API key was kept in portal.env (use --remove-key to remove)"
    fi
    print_info "Note: Database schema was NOT dropped for safety"
    echo ""

    log_info "Module removed: $MODULE"
}

main "$@"
