#!/bin/bash
# =============================================================================
# EZY Portal Installation Script
# =============================================================================
# Single-command installation for the EZY Portal core application.
#
# Usage:
#   ./install.sh                              # Interactive installation
#   ./install.sh --version 1.0.0              # Install specific version
#   ./install.sh --full-infra                 # Deploy with full infrastructure
#   ./install.sh --external-infra             # Use external PostgreSQL/Redis/RabbitMQ
#   ./install.sh --non-interactive            # Use defaults/existing config
#
# After installation, use ./add-module.sh to add micro-frontends:
#   ./add-module.sh items                     # Add Items module
#   ./add-module.sh bp                        # Add Business Partners (requires items)
#   ./add-module.sh prospects                 # Add Prospects (requires bp)
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
source "$SCRIPT_DIR/lib/frontend.sh"

# -----------------------------------------------------------------------------
# Default Values
# -----------------------------------------------------------------------------
VERSION="${VERSION:-latest}"
BACKEND_VERSION="${BACKEND_VERSION:-${VERSION}}"
FRONTEND_VERSION="${FRONTEND_VERSION:-${VERSION}}"
PROJECT_NAME="${PROJECT_NAME:-ezy-portal}"
INFRASTRUCTURE_MODE=""
INTERACTIVE=true
SKIP_SSL=false
PERF_MODE="${PERF_MODE:-}"

# -----------------------------------------------------------------------------
# Parse Command Line Arguments
# -----------------------------------------------------------------------------
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --version)
                VERSION="$2"
                BACKEND_VERSION="${BACKEND_VERSION:-$2}"
                FRONTEND_VERSION="${FRONTEND_VERSION:-$2}"
                shift 2
                ;;
            --backend-version)
                BACKEND_VERSION="$2"
                shift 2
                ;;
            --frontend-version)
                FRONTEND_VERSION="$2"
                shift 2
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
            --debug)
                DEBUG=true
                export DEBUG
                shift
                ;;
            --perf-mode)
                PERF_MODE="$2"
                export PERF_MODE
                shift 2
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

    # Validate perf-mode if provided
    if [[ -n "$PERF_MODE" ]] && [[ "$PERF_MODE" != "high" ]] && [[ "$PERF_MODE" != "default" ]]; then
        print_error "Invalid --perf-mode: $PERF_MODE (valid: default, high)"
        exit 1
    fi
}

show_help() {
    echo "EZY Portal Installation Script"
    echo ""
    echo "Usage: ./install.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --version VERSION          Install specific version for both backend and frontend (default: latest)"
    echo "  --backend-version VERSION  Install specific backend version"
    echo "  --frontend-version VERSION Install specific frontend version"
    echo "  --full-infra               Deploy PostgreSQL, Redis, RabbitMQ as containers"
    echo "  --external-infra           Use existing external infrastructure"
    echo "  --non-interactive          Skip prompts, use defaults or existing config"
    echo "  --skip-ssl                 Skip SSL certificate setup"
    echo "  --perf-mode MODE           Resource mode: 'default' (no limits) or 'high' (32GB+/16+ cores)"
    echo "  --debug                    Enable debug output"
    echo "  --help, -h                 Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  GITHUB_PAT            GitHub Personal Access Token (required for GHCR)"
    echo "  VERSION               Portal version to install (sets both backend and frontend)"
    echo "  BACKEND_VERSION       Backend version to install"
    echo "  FRONTEND_VERSION      Frontend version to install"
    echo "  PROJECT_NAME          Container name prefix"
    echo ""
    echo "Examples:"
    echo "  # Interactive installation"
    echo "  export GITHUB_PAT=ghp_your_token"
    echo "  ./install.sh"
    echo ""
    echo "  # Install specific version"
    echo "  ./install.sh --version 1.0.0"
    echo ""
    echo "  # Non-interactive with existing config"
    echo "  ./install.sh --non-interactive"
    echo ""
    echo "Adding Modules:"
    echo "  After installation, use ./add-module.sh to add micro-frontends:"
    echo "  ./add-module.sh items      # Add Items module"
    echo "  ./add-module.sh bp         # Add Business Partners (requires items)"
    echo "  ./add-module.sh prospects  # Add Prospects (requires bp)"
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
        "$DEPLOY_ROOT/logs/portal"
        "$DEPLOY_ROOT/data"
        "$DEPLOY_ROOT/uploads"
        "$DEPLOY_ROOT/uploads/data-protection-keys"
        "$DEPLOY_ROOT/dist/frontend"
        "$DEPLOY_ROOT/dist/mff"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            print_success "Created: $dir"
        fi
    done

    # Create .gitkeep files for dist directories
    touch "$DEPLOY_ROOT/dist/.gitkeep" 2>/dev/null || true
    touch "$DEPLOY_ROOT/dist/mff/.gitkeep" 2>/dev/null || true

    # Make scripts executable
    chmod +x "$DEPLOY_ROOT/install.sh" 2>/dev/null || true
    chmod +x "$DEPLOY_ROOT/upgrade.sh" 2>/dev/null || true
    chmod +x "$DEPLOY_ROOT/update-frontend.sh" 2>/dev/null || true
    chmod +x "$DEPLOY_ROOT/nginx/ssl/generate-self-signed.sh" 2>/dev/null || true

    print_success "Directories ready"

    # Check and fix uploads directory permissions
    # Docker containers need to create subdirectories in uploads/
    print_subsection "Checking Uploads Directory Permissions"
    if ! fix_uploads_permissions_interactive; then
        print_error "Cannot proceed without correct uploads permissions"
        print_info "The portal backend will fail to start without write access to uploads/"
        exit 1
    fi
}

step_pull_image() {
    print_section "Step 6: Pulling Backend Image"

    print_info "Backend version: $BACKEND_VERSION"

    if ! docker_pull_image "$BACKEND_VERSION"; then
        print_error "Failed to pull backend image"
        exit 1
    fi
}

step_install_frontend() {
    print_section "Step 7: Installing Frontend"

    print_info "Frontend version: $FRONTEND_VERSION"

    if download_frontend "$FRONTEND_VERSION"; then
        print_success "Frontend installed"
    else
        print_error "Failed to install frontend"
        exit 1
    fi
}

step_start_services() {
    print_section "Step 8: Starting Services"

    local compose_file
    compose_file=$(get_compose_file "$INFRASTRUCTURE_MODE")

    print_info "Infrastructure mode: $INFRASTRUCTURE_MODE"
    print_info "Compose file: $compose_file"

    # Save versions to config for upgrade tracking
    save_config_value "VERSION" "$VERSION" "$DEPLOY_ROOT/portal.env"
    save_config_value "BACKEND_VERSION" "$BACKEND_VERSION" "$DEPLOY_ROOT/portal.env"
    save_config_value "FRONTEND_VERSION" "$FRONTEND_VERSION" "$DEPLOY_ROOT/portal.env"

    # Export versions for docker compose
    export BACKEND_VERSION
    export FRONTEND_VERSION

    # Save performance mode if specified
    if [[ -n "$PERF_MODE" ]]; then
        save_config_value "PERF_MODE" "$PERF_MODE" "$DEPLOY_ROOT/portal.env"
        print_info "Performance mode: $PERF_MODE"
    fi

    # Generate deployment secret if not already set (used for API key provisioning)
    local existing_secret
    existing_secret=$(grep "^DEPLOYMENT_SECRET=" "$DEPLOY_ROOT/portal.env" 2>/dev/null | cut -d= -f2-)
    if [[ -z "$existing_secret" ]]; then
        local deployment_secret
        deployment_secret=$(generate_password_alphanum 64)
        save_config_value "DEPLOYMENT_SECRET" "$deployment_secret" "$DEPLOY_ROOT/portal.env"
        print_success "Generated deployment secret for API key provisioning"
    fi

    # Generate encryption key if not already set (used by prospects module for sensitive data)
    local existing_encryption_key
    existing_encryption_key=$(grep "^ENCRYPTION_KEY=" "$DEPLOY_ROOT/portal.env" 2>/dev/null | cut -d= -f2-)
    if [[ -z "$existing_encryption_key" ]]; then
        local encryption_key
        encryption_key=$(generate_password_alphanum 32)
        save_config_value "ENCRYPTION_KEY" "$encryption_key" "$DEPLOY_ROOT/portal.env"
        print_success "Generated encryption key for module data encryption"
    fi

    # Start services
    # Use --pull always for 'latest' to ensure we get the newest images
    local pull_flag=""
    if [[ "$BACKEND_VERSION" == "latest" ]]; then
        pull_flag="--pull always"
    fi

    local cmd="docker compose -f $compose_file --env-file $DEPLOY_ROOT/portal.env up -d $pull_flag"
    print_info "Running: $cmd"
    log_info "Running: $cmd"

    if eval "$cmd"; then
        print_success "Services started"
    else
        print_error "Failed to start services"
        print_info "Check logs with: docker compose -f $compose_file logs"
        exit 1
    fi
}

step_wait_for_healthy() {
    print_section "Step 9: Waiting for Services"

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
    print_section "Step 10: Final Health Check"

    if run_health_checks; then
        print_success "All services are healthy"
    else
        print_warning "Some services may have issues"
        print_info "The portal may still work. Check the dashboard."
    fi
}

show_success() {
    local app_url="${APPLICATION_URL:-https://localhost}"
    local compose_file
    compose_file=$(get_compose_file "$INFRASTRUCTURE_MODE")

    print_section "Installation Complete!"

    echo ""
    print_success "EZY Portal is now running!"
    echo ""
    echo "  Backend version:  $BACKEND_VERSION"
    echo "  Frontend version: $FRONTEND_VERSION"
    echo ""
    echo "  Portal URL:     $app_url"
    echo "  API Swagger:    $app_url/swagger"
    echo "  Hangfire:       $app_url/hangfire"
    echo ""

    if [[ "$INFRASTRUCTURE_MODE" == "full" ]]; then
        echo "Infrastructure:"
        echo "  PostgreSQL:     ${PROJECT_NAME:-ezy-portal}-postgres"
        echo "  Redis:          ${PROJECT_NAME:-ezy-portal}-redis"
        echo "  RabbitMQ:       ${PROJECT_NAME:-ezy-portal}-rabbitmq"
        echo ""
    fi

    echo "Useful Commands:"
    echo "  View logs:        docker logs ${PROJECT_NAME:-ezy-portal}"
    echo "  Stop:             docker compose -f $compose_file down"
    echo "  Upgrade:          ./upgrade.sh --version X.X.X"
    echo "  Update frontend:  ./update-frontend.sh --version X.X.X"
    echo ""
    echo "Add Modules:"
    echo "  ./add-module.sh items      # Items micro-frontend"
    echo "  ./add-module.sh bp         # Business Partners (requires items)"
    echo "  ./add-module.sh prospects  # Prospects (requires bp)"
    echo ""

    if [[ -n "${ADMIN_EMAIL:-}" ]]; then
        print_info "Admin user will be created on first login: $ADMIN_EMAIL"
    fi

    log_info "Installation completed successfully - Backend: $BACKEND_VERSION, Frontend: $FRONTEND_VERSION"
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
    step_install_frontend
    step_start_services
    step_wait_for_healthy
    step_health_check
    show_success
}

# Run main function
main "$@"
