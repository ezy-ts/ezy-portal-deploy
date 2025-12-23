#!/bin/bash
# =============================================================================
# EZY Portal Installation Script
# =============================================================================
# Single-command installation for EZY Portal and micro-frontends
#
# Usage:
#   ./install.sh                              # Interactive installation
#   ./install.sh --version 1.0.0              # Install specific version
#   ./install.sh --modules portal,bp          # Install portal + Business Partners
#   ./install.sh --modules all                # Install all modules
#   ./install.sh --local                      # Use local Docker images
#   ./install.sh --full-infra                 # Deploy with full infrastructure
#   ./install.sh --external-infra             # Use external PostgreSQL/Redis/RabbitMQ
#   ./install.sh --non-interactive            # Use defaults/existing config
#
# Modules:
#   portal      - Core portal shell (required)
#   bp          - Business Partners micro-frontend
#   items       - Items micro-frontend
#   prospects   - Prospects micro-frontend
#   all         - All modules
#
# Prerequisites:
#   - Docker and Docker Compose v2
#   - GITHUB_PAT environment variable set (for pulling from ghcr.io)
#   - Ports 80 and 443 available (or configure custom ports)
#
# Environment Variables:
#   GITHUB_PAT          - GitHub Personal Access Token (required for GHCR)
#   VERSION             - Portal version to install (default: latest)
#   PROJECT_NAME        - Container name prefix (default: ezy-portal)
#
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
source "$SCRIPT_DIR/lib/ssl.sh"

# -----------------------------------------------------------------------------
# Default Values
# -----------------------------------------------------------------------------
VERSION="${VERSION:-latest}"
PROJECT_NAME="${PROJECT_NAME:-ezy-portal}"
INFRASTRUCTURE_MODE=""
INTERACTIVE=true
SKIP_SSL=false
USE_LOCAL_IMAGES=false
MODULES="portal"  # Default to portal only

# Available modules (in dependency order: items -> bp -> prospects)
AVAILABLE_MODULES=("portal" "items" "bp" "prospects")

# Module dependencies (module -> required modules)
declare -A MODULE_DEPENDENCIES=(
    ["items"]=""
    ["bp"]="items"
    ["prospects"]="items,bp"
)

# -----------------------------------------------------------------------------
# Module Dependency Resolution
# -----------------------------------------------------------------------------
resolve_module_dependencies() {
    local input_modules="$1"
    local resolved=""
    local -A seen=()

    # Always include portal
    seen["portal"]=1
    resolved="portal"

    # Parse input modules
    IFS=',' read -ra module_array <<< "$input_modules"

    for module in "${module_array[@]}"; do
        module=$(echo "$module" | xargs)  # trim whitespace
        [[ -z "$module" ]] && continue
        [[ "$module" == "portal" ]] && continue

        # Add dependencies first (in order)
        local deps="${MODULE_DEPENDENCIES[$module]:-}"
        if [[ -n "$deps" ]]; then
            IFS=',' read -ra dep_array <<< "$deps"
            for dep in "${dep_array[@]}"; do
                dep=$(echo "$dep" | xargs)
                if [[ -z "${seen[$dep]:-}" ]]; then
                    seen["$dep"]=1
                    resolved="$resolved,$dep"
                fi
            done
        fi

        # Add the module itself
        if [[ -z "${seen[$module]:-}" ]]; then
            seen["$module"]=1
            resolved="$resolved,$module"
        fi
    done

    echo "$resolved"
}

# -----------------------------------------------------------------------------
# Parse Command Line Arguments
# -----------------------------------------------------------------------------
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --version)
                VERSION="$2"
                shift 2
                ;;
            --modules)
                MODULES="$2"
                shift 2
                ;;
            --local)
                USE_LOCAL_IMAGES=true
                shift
                ;;
            --full-infra)
                INFRASTRUCTURE_MODE="full"
                shift
                ;;
            --external-infra)
                INFRASTRUCTURE_MODE="external"
                shift
                ;;
            --non-interactive)
                INTERACTIVE=false
                shift
                ;;
            --skip-ssl)
                SKIP_SSL=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Expand "all" to all modules (in dependency order)
    if [[ "$MODULES" == "all" ]]; then
        MODULES="portal,items,bp,prospects"
    else
        # Resolve dependencies for specified modules
        MODULES=$(resolve_module_dependencies "$MODULES")
    fi

    # Export for use in lib scripts
    export MODULES
    export USE_LOCAL_IMAGES
}

show_help() {
    echo "EZY Portal Installation Script"
    echo ""
    echo "Usage: ./install.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --version VERSION     Install specific version (default: latest)"
    echo "  --modules MODULES     Comma-separated modules to install (default: portal)"
    echo "                        Available: portal, bp, items, prospects, all"
    echo "  --local               Use local Docker images instead of GitHub Registry"
    echo "  --full-infra          Deploy PostgreSQL, Redis, RabbitMQ as containers"
    echo "  --external-infra      Use existing external infrastructure"
    echo "  --non-interactive     Skip prompts, use defaults or existing config"
    echo "  --skip-ssl            Skip SSL certificate setup"
    echo "  --help, -h            Show this help message"
    echo ""
    echo "Modules (dependencies auto-resolved):"
    echo "  portal                Core portal shell (always included)"
    echo "  items                 Items micro-frontend (base module)"
    echo "  bp                    Business Partners (requires: items)"
    echo "  prospects             Prospects (requires: bp, items)"
    echo "  all                   All modules"
    echo ""
    echo "Environment Variables:"
    echo "  GITHUB_PAT            GitHub Personal Access Token (required for GHCR)"
    echo "  VERSION               Portal version to install"
    echo "  PROJECT_NAME          Container name prefix"
    echo ""
    echo "Examples:"
    echo "  # Interactive installation (portal only)"
    echo "  export GITHUB_PAT=ghp_your_token"
    echo "  ./install.sh"
    echo ""
    echo "  # Install portal + Business Partners using local images"
    echo "  ./install.sh --modules portal,bp --local"
    echo ""
    echo "  # Install all modules from GitHub Registry"
    echo "  ./install.sh --modules all --version 1.0.0"
    echo ""
    echo "  # Non-interactive with existing config"
    echo "  ./install.sh --non-interactive"
}

# -----------------------------------------------------------------------------
# Main Installation Steps
# -----------------------------------------------------------------------------

step_check_prerequisites() {
    print_section "Step 1: Checking Prerequisites"

    if ! run_all_prerequisite_checks; then
        print_error "Prerequisites check failed. Please fix the issues above."
        exit 1
    fi

    # Login to GHCR
    print_subsection "GitHub Container Registry"
    if ! check_ghcr_login; then
        exit 1
    fi
}

step_check_existing_installation() {
    print_section "Step 2: Checking Existing Installation"

    if check_existing_installation; then
        print_warning "Existing installation detected"

        local current_version
        current_version=$(get_current_portal_version)
        print_info "Current version: $current_version"

        if check_portal_running; then
            print_info "Portal is currently running"
        fi

        if [[ "$INTERACTIVE" == true ]]; then
            echo ""
            if ! confirm "Continue with installation? (This may upgrade/reinstall)" "n"; then
                print_info "Installation cancelled"
                exit 0
            fi
        fi
    else
        print_success "Fresh installation"
    fi
}

step_configure() {
    print_section "Step 3: Configuration"

    local config_file="$DEPLOY_ROOT/portal.env"

    # Check if config exists
    if [[ -f "$config_file" ]]; then
        print_info "Found existing configuration: $config_file"

        if [[ "$INTERACTIVE" == true ]]; then
            if confirm "Use existing configuration?" "y"; then
                load_config "$config_file"
                print_success "Using existing configuration"

                # Detect infrastructure mode from config
                if [[ -z "$INFRASTRUCTURE_MODE" ]]; then
                    INFRASTRUCTURE_MODE=$(detect_infrastructure_type "$config_file")
                fi
                return 0
            fi
        else
            load_config "$config_file"
            if [[ -z "$INFRASTRUCTURE_MODE" ]]; then
                INFRASTRUCTURE_MODE=$(detect_infrastructure_type "$config_file")
            fi
            return 0
        fi
    fi

    # Need to create configuration
    if [[ "$INTERACTIVE" == true ]]; then
        run_config_wizard
        load_config "$config_file"
        INFRASTRUCTURE_MODE=$(detect_infrastructure_type "$config_file")
    else
        # Non-interactive: create default config
        if [[ -z "$INFRASTRUCTURE_MODE" ]]; then
            INFRASTRUCTURE_MODE="full"
        fi
        create_default_config "$INFRASTRUCTURE_MODE"
        load_config "$config_file"

        print_warning "Default configuration created. Please edit $config_file"
        print_warning "At minimum, set: ADMIN_EMAIL, APPLICATION_URL, and OAuth credentials"

        if ! confirm "Continue with default configuration?" "n"; then
            print_info "Please edit $config_file and run install.sh again"
            exit 0
        fi
    fi
}

step_setup_ssl() {
    print_section "Step 4: SSL Certificate Setup"

    if [[ "$SKIP_SSL" == true ]]; then
        print_warning "Skipping SSL setup as requested"
        return 0
    fi

    local ssl_dir="$DEPLOY_ROOT/nginx/ssl"

    if check_ssl_certificates "$ssl_dir"; then
        print_info "SSL certificates found"
        check_ssl_expiry "$ssl_dir/server.crt" || true

        if [[ "$INTERACTIVE" == true ]]; then
            if ! confirm "Use existing SSL certificates?" "y"; then
                setup_ssl_interactive "$ssl_dir" "${SERVER_NAME:-localhost}"
            fi
        fi
    else
        if [[ "$INTERACTIVE" == true ]]; then
            setup_ssl_interactive "$ssl_dir" "${SERVER_NAME:-localhost}"
        else
            # Non-interactive: generate self-signed
            print_info "Generating self-signed certificate..."
            generate_self_signed_cert "${SERVER_NAME:-localhost}" "$ssl_dir"
        fi
    fi
}

step_create_directories() {
    print_section "Step 5: Creating Directories"

    local dirs=(
        "$DEPLOY_ROOT/backups"
        "$DEPLOY_ROOT/logs"
        "$DEPLOY_ROOT/data"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            print_success "Created: $dir"
        fi
    done

    # Make scripts executable
    chmod +x "$DEPLOY_ROOT/install.sh" 2>/dev/null || true
    chmod +x "$DEPLOY_ROOT/upgrade.sh" 2>/dev/null || true
    chmod +x "$DEPLOY_ROOT/nginx/ssl/generate-self-signed.sh" 2>/dev/null || true

    print_success "Directories ready"
}

step_pull_image() {
    print_section "Step 6: Pulling Module Images"

    print_info "Version: $VERSION"
    print_info "Modules: $MODULES"
    print_info "Image source: $([ "$USE_LOCAL_IMAGES" == "true" ] && echo "Local" || echo "GitHub Container Registry")"

    # Generate image environment variables for compose
    generate_module_image_vars "$VERSION" "$MODULES"

    if ! docker_pull_modules "$VERSION" "$MODULES"; then
        print_error "Failed to pull module images"
        if [[ "$USE_LOCAL_IMAGES" == "true" ]]; then
            print_info "Build the images locally first or remove --local flag"
        else
            print_info "Check your GITHUB_PAT and network connection"
        fi
        exit 1
    fi
}

step_start_services() {
    print_section "Step 7: Starting Services"

    local compose_args
    compose_args=$(get_compose_files_for_modules "$INFRASTRUCTURE_MODE" "$MODULES")

    print_info "Infrastructure mode: $INFRASTRUCTURE_MODE"
    print_info "Modules: $MODULES"
    print_info "Compose files: $compose_args"

    # Save version and modules to config for upgrade tracking
    save_config_value "VERSION" "$VERSION" "$DEPLOY_ROOT/portal.env"
    save_config_value "MODULES" "$MODULES" "$DEPLOY_ROOT/portal.env"

    # Generate module image variables
    generate_module_image_vars "$VERSION" "$MODULES"

    # Start services using compose with module files
    local cmd="docker compose $compose_args --env-file $DEPLOY_ROOT/portal.env up -d"
    print_info "Running: $cmd"
    log_info "Running: $cmd"

    if eval "$cmd"; then
        print_success "Services started"
    else
        print_error "Failed to start services"
        print_info "Check logs with: docker compose $compose_args logs"
        exit 1
    fi
}

step_wait_for_healthy() {
    print_section "Step 8: Waiting for Services"

    local container="${PROJECT_NAME:-ezy-portal}"
    local timeout=180

    print_info "Waiting for portal to be healthy (timeout: ${timeout}s)..."

    if wait_for_healthy "$container" "$timeout"; then
        print_success "Portal is healthy!"
    else
        print_error "Portal did not become healthy within ${timeout}s"
        print_info "Check logs: docker logs $container"

        if [[ "$INTERACTIVE" == true ]]; then
            if confirm "Show recent logs?" "y"; then
                docker logs --tail 50 "$container"
            fi
        fi
        exit 1
    fi
}

step_health_check() {
    print_section "Step 9: Final Health Check"

    if run_health_checks; then
        print_success "All services are healthy"
    else
        print_warning "Some services may have issues"
        print_info "The portal may still work. Check the dashboard."
    fi
}

show_success() {
    local app_url="${APPLICATION_URL:-https://localhost}"

    print_section "Installation Complete!"

    echo ""
    print_success "EZY Portal is now running!"
    echo ""
    echo "  Portal URL:     $app_url"
    echo "  API Swagger:    $app_url/swagger"
    echo "  Hangfire:       $app_url/hangfire"
    echo ""

    # Show installed modules (in dependency order)
    echo "Installed Modules:"
    echo "  ✓ Portal (Core Shell)"

    # Display in dependency order
    local ordered_modules=("items" "bp" "prospects")
    for module in "${ordered_modules[@]}"; do
        if [[ ",$MODULES," == *",$module,"* ]]; then
            case "$module" in
                items)
                    echo "  ✓ Items              → $app_url/mfe/items/"
                    ;;
                bp)
                    echo "  ✓ Business Partners  → $app_url/mfe/bp/"
                    ;;
                prospects)
                    echo "  ✓ Prospects          → $app_url/mfe/prospects/"
                    ;;
            esac
        fi
    done
    echo ""

    if [[ "$INFRASTRUCTURE_MODE" == "full" ]]; then
        echo "Infrastructure:"
        echo "  PostgreSQL:     ${PROJECT_NAME:-ezy-portal}-postgres"
        echo "  Redis:          ${PROJECT_NAME:-ezy-portal}-redis"
        echo "  RabbitMQ:       ${PROJECT_NAME:-ezy-portal}-rabbitmq"
        echo ""
    fi

    local compose_args
    compose_args=$(get_compose_files_for_modules "$INFRASTRUCTURE_MODE" "$MODULES")

    echo "Useful Commands:"
    echo "  View logs:      docker logs ${PROJECT_NAME:-ezy-portal}"
    echo "  Stop:           docker compose $compose_args down"
    echo "  Upgrade:        ./upgrade.sh --version X.X.X --modules $MODULES"
    echo ""

    if [[ -n "${ADMIN_EMAIL:-}" ]]; then
        print_info "Admin user will be created on first login: $ADMIN_EMAIL"
    fi

    log_info "Installation completed successfully - Version: $VERSION, Modules: $MODULES"
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    init_logging
    log_info "Starting installation - Version: $VERSION"

    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║                    EZY Portal Installer                       ║"
    echo "  ║                      Version: $VERSION                            ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    parse_arguments "$@"

    step_check_prerequisites
    step_check_existing_installation
    step_configure
    step_setup_ssl
    step_create_directories
    step_pull_image
    step_start_services
    step_wait_for_healthy
    step_health_check
    show_success
}

# Run main function
main "$@"
