#!/bin/bash
# =============================================================================
# EZY Portal Reload Script
# =============================================================================
# Reloads services to pick up new portal.env configuration changes
#
# Usage:
#   ./reload.sh                  # Reload all services
#   ./reload.sh portal           # Reload only the portal service
#   ./reload.sh nginx            # Reload only nginx
#   ./reload.sh --list           # List available services
#
# Note: Uses down/up (not restart) to ensure environment changes are applied
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
# Functions
# -----------------------------------------------------------------------------

show_help() {
    echo "EZY Portal Reload Script"
    echo ""
    echo "Reloads services to pick up new portal.env configuration changes."
    echo ""
    echo "Usage: ./reload.sh [SERVICE] [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  SERVICE              Service name to reload (optional, reloads all if omitted)"
    echo ""
    echo "Options:"
    echo "  --list, -l           List available services"
    echo "  --help, -h           Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./reload.sh              # Reload all services"
    echo "  ./reload.sh portal       # Reload only portal backend"
    echo "  ./reload.sh nginx        # Reload only nginx"
    echo "  ./reload.sh bp           # Reload BP module"
}

list_services() {
    local compose_args
    local infra_mode

    infra_mode=$(detect_infrastructure_type)
    compose_args=$(get_compose_files_for_modules "$infra_mode" "${MODULES:-portal}")

    print_info "Available services:"
    echo ""
    docker compose $compose_args --env-file "$DEPLOY_ROOT/portal.env" ps --services 2>/dev/null | sort
}

reload_service() {
    local service="$1"
    local compose_args
    local infra_mode

    # Load config
    load_config "$DEPLOY_ROOT/portal.env"

    # Detect infrastructure mode
    infra_mode=$(detect_infrastructure_type)

    # Get compose files for all configured modules
    compose_args=$(get_compose_files_for_modules "$infra_mode" "${MODULES:-portal}")

    if [[ -n "$service" ]]; then
        print_section "Reloading: $service"

        # Stop the specific service
        print_info "Stopping $service..."
        docker compose $compose_args --env-file "$DEPLOY_ROOT/portal.env" stop "$service"
        docker compose $compose_args --env-file "$DEPLOY_ROOT/portal.env" rm -f "$service"

        # Start it back up
        print_info "Starting $service..."
        docker compose $compose_args --env-file "$DEPLOY_ROOT/portal.env" up -d "$service"

        print_success "$service reloaded with new configuration"
    else
        print_section "Reloading All Services"

        # Down then up to pick up all env changes
        print_info "Stopping all services..."
        docker compose $compose_args --env-file "$DEPLOY_ROOT/portal.env" down

        print_info "Starting all services..."
        docker compose $compose_args --env-file "$DEPLOY_ROOT/portal.env" up -d

        print_success "All services reloaded with new configuration"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    local service=""

    # Parse arguments
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --list|-l)
                load_config "$DEPLOY_ROOT/portal.env"
                list_services
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                service="$1"
                shift
                ;;
        esac
    done

    # Check if portal.env exists
    if [[ ! -f "$DEPLOY_ROOT/portal.env" ]]; then
        print_error "portal.env not found"
        print_info "Run ./install.sh first to set up the portal"
        exit 1
    fi

    reload_service "$service"
}

main "$@"
