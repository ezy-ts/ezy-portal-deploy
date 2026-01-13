#!/bin/bash
# =============================================================================
# EZY Portal - Remove Customer Module Script
# =============================================================================
# Remove a customer-specific micro-frontend module
#
# Usage:
#   ./remove-customer-module.sh red-cloud-quotation-tool
#   ./remove-customer-module.sh red-cloud-quotation-tool --force
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
source "$SCRIPT_DIR/lib/customer-module.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
MODULE_NAME=""
FORCE=false

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
parse_arguments() {
    if [[ $# -lt 1 ]]; then
        show_help
        exit 1
    fi

    MODULE_NAME="$1"
    shift

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --force|-f)
                FORCE=true
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
    echo "EZY Portal - Remove Customer Module"
    echo ""
    echo "Usage: ./remove-customer-module.sh <module-name> [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  <module-name>  Name of the customer module to remove"
    echo ""
    echo "Options:"
    echo "  --force, -f   Skip confirmation prompt"
    echo "  --help, -h    Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./remove-customer-module.sh red-cloud-quotation-tool"
    echo "  ./remove-customer-module.sh red-cloud-quotation-tool --force"
    echo ""
    echo "Note: This command does NOT drop the database schema for safety."
    echo "      To remove data, manually drop the schema in PostgreSQL."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    init_logging
    parse_arguments "$@"

    echo ""
    print_section "Removing Customer Module: $MODULE_NAME"

    # Load existing config
    if [[ -f "$DEPLOY_ROOT/portal.env" ]]; then
        load_config "$DEPLOY_ROOT/portal.env"
    fi

    # Check if module is registered
    if ! is_customer_module_installed "$MODULE_NAME"; then
        print_error "Module '$MODULE_NAME' is not registered"
        print_info "Use ./list-customer-modules.sh to see installed modules"
        exit 1
    fi

    # Get module info
    local version
    version=$(get_customer_module_version "$MODULE_NAME")
    print_info "Module: $MODULE_NAME"
    print_info "Version: $version"

    # Check if this module has frontend files
    local mff_dir="${DEPLOY_ROOT}/dist/mff/${MODULE_NAME}"
    local has_frontend="false"
    if [[ -d "$mff_dir" ]]; then
        has_frontend="true"
    fi

    # Confirm removal
    if [[ "$FORCE" != "true" ]]; then
        echo ""
        print_warning "This will:"
        echo "  - Stop and remove the container"
        echo "  - Remove nginx configuration"
        echo "  - Remove docker-compose file"
        if [[ "$has_frontend" == "true" ]]; then
            echo "  - Remove frontend files from $mff_dir"
        fi
        echo "  - Unregister the module"
        echo ""
        print_info "This will NOT drop the database schema"
        echo ""
        if ! confirm "Remove customer module '$MODULE_NAME'?" "n"; then
            print_info "Removal cancelled"
            exit 0
        fi
    fi

    # Stop the container
    print_subsection "Stopping Container"
    stop_customer_module "$MODULE_NAME"

    # Remove nginx config
    print_subsection "Removing Nginx Configuration"
    local nginx_config="${CUSTOMER_NGINX_DIR}/${MODULE_NAME}.conf"
    if [[ -f "$nginx_config" ]]; then
        rm -f "$nginx_config"
        print_success "Removed: $nginx_config"
    else
        print_info "No nginx config found"
    fi

    # Remove compose file
    print_subsection "Removing Compose File"
    local compose_file
    compose_file=$(get_customer_compose_file "$MODULE_NAME")
    if [[ -f "$compose_file" ]]; then
        rm -f "$compose_file"
        print_success "Removed: $compose_file"
    else
        print_info "No compose file found"
    fi

    # Remove frontend files if present (separated architecture)
    if [[ "$has_frontend" == "true" ]]; then
        print_subsection "Removing Frontend Files"
        remove_customer_frontend "$MODULE_NAME"
    fi

    # Reload nginx
    print_subsection "Reloading Nginx"
    reload_nginx || true

    # Unregister module
    print_subsection "Unregistering Module"
    unregister_customer_module "$MODULE_NAME"
    print_success "Module unregistered from registry"

    # Success
    echo ""
    print_section "Removal Complete"
    print_success "Customer module '$MODULE_NAME' has been removed"
    echo ""
    print_info "Note: Database schema was NOT dropped for safety"
    print_info "To remove data, run in PostgreSQL:"
    echo "  DROP SCHEMA IF EXISTS <schema_name> CASCADE;"
    echo ""

    log_info "Customer module removed: $MODULE_NAME"
}

main "$@"
