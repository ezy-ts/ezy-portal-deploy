#!/bin/bash
# =============================================================================
# EZY Portal Upgrade Script
# =============================================================================
# Safely upgrades existing EZY Portal installation with backup and rollback
#
# Usage:
#   ./upgrade.sh                        # Upgrade to latest
#   ./upgrade.sh --version 1.0.1        # Upgrade to specific version
#   ./upgrade.sh --rollback             # Rollback to previous version
#   ./upgrade.sh --skip-backup          # Skip backup (not recommended)
#
# Features:
#   - Automatic backup before upgrade
#   - Health check validation
#   - Automatic rollback on failure
#   - Version comparison
#
# Environment Variables:
#   GITHUB_PAT          - GitHub Personal Access Token (required)
#   VERSION             - Target version (default: latest)
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
source "$SCRIPT_DIR/lib/backup.sh"
source "$SCRIPT_DIR/lib/frontend.sh"

# -----------------------------------------------------------------------------
# Default Values
# -----------------------------------------------------------------------------
VERSION="${VERSION:-latest}"
BACKEND_VERSION="${BACKEND_VERSION:-${VERSION}}"
FRONTEND_VERSION="${FRONTEND_VERSION:-${VERSION}}"
PROJECT_NAME="${PROJECT_NAME:-ezy-portal}"
SKIP_BACKUP=false
DO_ROLLBACK=false
FORCE=false
UPGRADE_MODULES=""          # Empty = upgrade all; comma-separated = selective
SKIP_FRONTEND=false
ONLY_FRONTEND=false

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
            --skip-backup)
                SKIP_BACKUP=true
                shift
                ;;
            --rollback)
                DO_ROLLBACK=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --module)
                UPGRADE_MODULES="$2"
                SKIP_FRONTEND=true
                shift 2
                ;;
            --only-frontend)
                ONLY_FRONTEND=true
                shift
                ;;
            --skip-frontend)
                SKIP_FRONTEND=true
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
}

show_help() {
    echo "EZY Portal Upgrade Script"
    echo ""
    echo "Usage: ./upgrade.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --version VERSION          Upgrade both backend and frontend to specific version (default: latest)"
    echo "  --backend-version VERSION  Upgrade backend to specific version"
    echo "  --frontend-version VERSION Upgrade frontend to specific version"
    echo "  --module MODULE[,MODULE]   Upgrade specific module(s) only (e.g., --module crm or --module bp,items)"
    echo "  --only-frontend            Only upgrade frontend, skip backend/modules"
    echo "  --skip-frontend            Skip frontend upgrade, only upgrade backend/modules"
    echo "  --skip-backup              Skip backup before upgrade (not recommended)"
    echo "  --rollback                 Rollback to previous version from backup"
    echo "  --force                    Force upgrade even if same version"
    echo "  --help, -h                 Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Upgrade everything to latest"
    echo "  ./upgrade.sh"
    echo ""
    echo "  # Upgrade to specific version"
    echo "  ./upgrade.sh --version 1.0.2"
    echo ""
    echo "  # Upgrade only frontend"
    echo "  ./upgrade.sh --only-frontend --frontend-version 1.0.3"
    echo ""
    echo "  # Upgrade a single module"
    echo "  ./upgrade.sh --module crm --version 1.0.2"
    echo ""
    echo "  # Upgrade multiple modules"
    echo "  ./upgrade.sh --module bp,items --version 1.0.2"
    echo ""
    echo "  # Rollback to previous version"
    echo "  ./upgrade.sh --rollback"
}

# -----------------------------------------------------------------------------
# Upgrade Steps
# -----------------------------------------------------------------------------

step_validate_installation() {
    print_section "Step 1: Validating Installation"

    if ! check_existing_installation; then
        print_error "No existing installation found"
        print_info "Run ./install.sh first to install the portal"
        exit 1
    fi

    print_success "Existing installation found"

    # Load configuration
    load_config "$DEPLOY_ROOT/portal.env"

    # Get current versions
    CURRENT_VERSION=$(get_current_portal_version)
    CURRENT_BACKEND_VERSION="${BACKEND_VERSION:-$CURRENT_VERSION}"
    CURRENT_FRONTEND_VERSION=$(get_installed_frontend_version)

    print_info "Current backend version: $CURRENT_BACKEND_VERSION"
    print_info "Current frontend version: $CURRENT_FRONTEND_VERSION"
    print_info "Target backend version: $BACKEND_VERSION"
    print_info "Target frontend version: $FRONTEND_VERSION"

    # Detect infrastructure mode
    INFRASTRUCTURE_MODE=$(detect_infrastructure_type)
    print_info "Infrastructure mode: $INFRASTRUCTURE_MODE"
}

step_check_prerequisites() {
    print_section "Step 2: Checking Prerequisites"

    # Check Docker
    if ! check_docker_installed || ! check_docker_running; then
        exit 1
    fi

    # Check GITHUB_PAT
    if ! check_github_pat; then
        exit 1
    fi

    # Login to GHCR
    if ! check_ghcr_login; then
        exit 1
    fi

    print_success "Prerequisites met"
}

step_compare_versions() {
    print_section "Step 3: Comparing Versions"

    local needs_backend_upgrade=false
    local needs_frontend_upgrade=false

    # Check backend version
    if [[ "$BACKEND_VERSION" == "latest" ]]; then
        needs_backend_upgrade=true
        print_info "Backend: pulling latest (will detect remote changes)"
    elif [[ "$CURRENT_BACKEND_VERSION" != "$BACKEND_VERSION" ]]; then
        needs_backend_upgrade=true
        print_info "Backend: $CURRENT_BACKEND_VERSION -> $BACKEND_VERSION"
    else
        print_info "Backend: already at version $BACKEND_VERSION"
    fi

    # Check frontend version
    # Frontend is a GitHub release artifact, so resolve 'latest' to actual version for comparison
    if [[ "$FRONTEND_VERSION" == "latest" ]]; then
        print_info "Checking latest frontend release..."
        local resolved_frontend
        resolved_frontend=$(get_latest_frontend_version 2>/dev/null || true)
        if [[ -n "$resolved_frontend" ]]; then
            if [[ "$CURRENT_FRONTEND_VERSION" != "$resolved_frontend" ]]; then
                needs_frontend_upgrade=true
                print_info "Frontend: $CURRENT_FRONTEND_VERSION -> $resolved_frontend (latest)"
            else
                print_info "Frontend: already at latest ($resolved_frontend)"
            fi
        else
            # Can't resolve, assume upgrade needed
            needs_frontend_upgrade=true
            print_warning "Frontend: could not resolve latest version, will attempt upgrade"
        fi
    elif [[ "$CURRENT_FRONTEND_VERSION" != "$FRONTEND_VERSION" ]]; then
        needs_frontend_upgrade=true
        print_info "Frontend: $CURRENT_FRONTEND_VERSION -> $FRONTEND_VERSION"
    else
        print_info "Frontend: already at version $FRONTEND_VERSION"
    fi

    if [[ "$needs_backend_upgrade" == false ]] && [[ "$needs_frontend_upgrade" == false ]]; then
        if [[ "$FORCE" != true ]]; then
            print_info "Already running target versions"

            if ! confirm "Force reinstall?" "n"; then
                print_info "Upgrade cancelled"
                exit 0
            fi
        else
            print_warning "Forcing reinstall of current versions"
        fi
    fi

    # Interactive component selection (skip if --module or --only-frontend was specified)
    if [[ -z "$UPGRADE_MODULES" ]] && [[ "$ONLY_FRONTEND" != true ]]; then
        step_select_components
    fi

    if ! confirm "Proceed with upgrade?" "y"; then
        print_info "Upgrade cancelled"
        exit 0
    fi
}

step_select_components() {
    print_subsection "Select Components to Upgrade"
    echo ""

    # Build the list of available components
    local -a component_names=()
    local -a component_labels=()
    local -a component_selected=()

    # Portal backend is always first
    component_names+=("portal")
    component_labels+=("Portal Backend")
    component_selected+=(true)

    # Add each module
    IFS=',' read -ra module_array <<< "${MODULES:-portal}"
    for module in "${module_array[@]}"; do
        module=$(echo "$module" | xargs)
        if [[ "$module" != "portal" && -n "$module" ]]; then
            component_names+=("$module")
            component_labels+=("$module")
            component_selected+=(true)
        fi
    done

    # Frontend
    component_names+=("frontend")
    component_labels+=("Frontend")
    component_selected+=(true)

    # Display the checklist
    echo "  Components available for upgrade:"
    echo ""
    for i in "${!component_names[@]}"; do
        local marker="x"
        printf "  [%s] %d) %s\n" "$marker" $((i + 1)) "${component_labels[$i]}"
    done
    echo ""
    echo "  Enter numbers to toggle (e.g., 1 3 5), 'a' for all, or press Enter to keep all:"
    read -rp "  > " selection

    if [[ -n "$selection" && "$selection" != "a" ]]; then
        # Deselect all first
        for i in "${!component_selected[@]}"; do
            component_selected[$i]=false
        done
        # Select only the ones the user picked
        for num in $selection; do
            local idx=$((num - 1))
            if [[ $idx -ge 0 && $idx -lt ${#component_names[@]} ]]; then
                component_selected[$idx]=true
            fi
        done
    fi

    # Build the selected module list and flags
    local selected_modules=""
    SKIP_FRONTEND=true

    echo ""
    echo "  Upgrading:"
    for i in "${!component_names[@]}"; do
        if [[ "${component_selected[$i]}" == true ]]; then
            echo "    ✓ ${component_labels[$i]}"
            case "${component_names[$i]}" in
                frontend)
                    SKIP_FRONTEND=false
                    ;;
                *)
                    if [[ -n "$selected_modules" ]]; then
                        selected_modules="$selected_modules,${component_names[$i]}"
                    else
                        selected_modules="${component_names[$i]}"
                    fi
                    ;;
            esac
        else
            echo "    - ${component_labels[$i]} (skipped)"
        fi
    done
    echo ""

    # If not all backend modules were selected, set UPGRADE_MODULES for selective upgrade
    local all_modules_str="portal"
    IFS=',' read -ra module_array <<< "${MODULES:-portal}"
    for module in "${module_array[@]}"; do
        module=$(echo "$module" | xargs)
        if [[ "$module" != "portal" && -n "$module" ]]; then
            all_modules_str="$all_modules_str,$module"
        fi
    done

    if [[ "$selected_modules" != "$all_modules_str" ]]; then
        if [[ -n "$selected_modules" ]]; then
            UPGRADE_MODULES="$selected_modules"
        fi
    fi
}

step_create_backup() {
    print_section "Step 4: Creating Backup"

    if [[ "$SKIP_BACKUP" == true ]]; then
        print_warning "Skipping backup as requested"
        print_warning "You will not be able to rollback if upgrade fails!"

        if ! confirm "Continue without backup?" "n"; then
            exit 1
        fi
        return 0
    fi

    BACKUP_PATH=$(create_full_backup "pre-upgrade-to-$VERSION")

    if [[ -z "$BACKUP_PATH" ]] || [[ ! -d "$BACKUP_PATH" ]]; then
        print_error "Backup failed"

        if ! confirm "Continue without backup?" "n"; then
            exit 1
        fi
    else
        # Record rollback info
        record_rollback_info "$BACKUP_PATH" "$CURRENT_VERSION" "$VERSION"
        print_success "Backup created: $BACKUP_PATH"
    fi
}

step_pull_new_image() {
    print_section "Step 5: Pulling Backend Images"

    # Determine which modules to pull
    local pull_modules="${MODULES:-portal}"
    if [[ -n "$UPGRADE_MODULES" ]]; then
        # Filter out nginx from pull list (it's not a custom image)
        pull_modules=$(echo "$UPGRADE_MODULES" | sed 's/,nginx//g; s/nginx,//g; s/^nginx$//')
    fi

    print_info "Backend version: $BACKEND_VERSION"
    print_info "Modules: $pull_modules"

    # Pull images for configured modules
    if ! docker_pull_modules "$BACKEND_VERSION" "$pull_modules"; then
        print_error "Failed to pull images for backend version $BACKEND_VERSION"

        if [[ -n "${BACKUP_PATH:-}" ]]; then
            print_info "Backup is available for rollback: $BACKUP_PATH"
        fi
        exit 1
    fi
}

step_update_frontend() {
    print_section "Step 6: Updating Frontend"

    print_info "Frontend version: $FRONTEND_VERSION"

    if download_frontend "$FRONTEND_VERSION"; then
        print_success "Frontend updated to version $FRONTEND_VERSION"
    else
        print_error "Failed to update frontend"

        if [[ -n "${BACKUP_PATH:-}" ]]; then
            print_info "Backup is available for rollback: $BACKUP_PATH"
        fi
        exit 1
    fi
}

step_stop_services() {
    print_section "Step 7: Stopping Current Services"

    local project_name="${PROJECT_NAME:-ezy-portal}"

    # Determine which modules to stop
    local modules_to_stop="${MODULES:-portal}"
    if [[ -n "$UPGRADE_MODULES" ]]; then
        modules_to_stop="$UPGRADE_MODULES"
        print_info "Selective upgrade - stopping: $modules_to_stop"
    else
        print_info "Stopping all module containers..."
    fi

    IFS=',' read -ra module_array <<< "$modules_to_stop"
    for module in "${module_array[@]}"; do
        module=$(echo "$module" | xargs)
        if [[ -z "$module" ]]; then continue; fi

        if [[ "$module" == "portal" ]]; then
            local container="${project_name}"
        elif [[ "$module" == "nginx" ]]; then
            local container="${project_name}-nginx"
        else
            local container="${project_name}-${module}"
        fi
        print_info "Stopping $container..."
        docker stop "$container" 2>/dev/null || true
        docker rm "$container" 2>/dev/null || true
    done

    print_success "Containers stopped"
}

step_start_new_version() {
    print_section "Step 8: Starting New Version"

    # Update versions in config
    save_config_value "VERSION" "$VERSION" "$DEPLOY_ROOT/portal.env"
    save_config_value "BACKEND_VERSION" "$BACKEND_VERSION" "$DEPLOY_ROOT/portal.env"
    save_config_value "FRONTEND_VERSION" "$FRONTEND_VERSION" "$DEPLOY_ROOT/portal.env"

    # Export versions for docker compose
    export BACKEND_VERSION
    export FRONTEND_VERSION

    # Generate module image environment variables
    generate_module_image_vars "$VERSION" "${MODULES:-portal}"

    # Get compose files for all modules
    local compose_args
    compose_args=$(get_compose_files_for_modules "$INFRASTRUCTURE_MODE" "${MODULES:-portal}")

    # Build env-file args (includes portal.secrets.env if it exists)
    local env_args
    env_args=$(_build_env_file_args "$DEPLOY_ROOT/portal.env")

    print_info "Starting with compose files: $compose_args"
    print_info "Infrastructure (postgres, redis, rabbitmq) will NOT be recreated"

    # Get list of app services to start (exclude infrastructure)
    # Use tr to convert newlines to spaces so they don't break eval
    local app_services
    app_services=$(docker compose $compose_args $env_args config --services 2>/dev/null \
        | grep -v -E '^(postgres|redis|rabbitmq|clamav)$' | tr '\n' ' ' || true)

    # If upgrading specific modules, filter app_services to only those + portal + nginx
    if [[ -n "$UPGRADE_MODULES" ]]; then
        local filtered=""
        IFS=',' read -ra target_modules <<< "$UPGRADE_MODULES"
        for svc in $app_services; do
            for mod in "${target_modules[@]}"; do
                mod=$(echo "$mod" | xargs)
                if [[ "$svc" == "$mod" ]]; then
                    filtered="$filtered $svc"
                fi
            done
        done
        app_services="$filtered"
        if [[ -z "${app_services// /}" ]]; then
            print_error "No matching services found for modules: $UPGRADE_MODULES"
            exit 1
        fi
        print_info "Selective upgrade - services: $app_services"
    fi

    # Start only app services with --no-deps to avoid touching infrastructure
    log_info "Running: docker compose $compose_args $env_args up -d --no-deps --force-recreate $app_services"

    if docker compose $compose_args $env_args up -d --no-deps --force-recreate $app_services; then
        print_success "Services started"
    else
        print_error "Failed to start new version"

        if [[ -n "${BACKUP_PATH:-}" ]]; then
            print_warning "Attempting automatic rollback..."
            do_rollback "$BACKUP_PATH"
        fi
        exit 1
    fi
}

step_verify_health() {
    print_section "Step 9: Verifying Health"

    local project_name="${PROJECT_NAME:-ezy-portal}"
    local timeout=180
    local failed=0

    # Determine which modules to check
    local modules_to_check="${MODULES:-portal}"
    if [[ -n "$UPGRADE_MODULES" ]]; then
        modules_to_check="$UPGRADE_MODULES"
    fi

    IFS=',' read -ra module_array <<< "$modules_to_check"
    for module in "${module_array[@]}"; do
        module=$(echo "$module" | xargs)
        if [[ -z "$module" || "$module" == "nginx" ]]; then continue; fi

        if [[ "$module" == "portal" ]]; then
            local container="${project_name}"
            local check_timeout=$timeout
        else
            local container="${project_name}-${module}"
            local check_timeout=60
        fi

        if ! wait_for_healthy "$container" "$check_timeout"; then
            print_error "$container did not become healthy"
            ((failed++))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        print_error "$failed container(s) failed health check"

        if [[ -n "${BACKUP_PATH:-}" ]]; then
            print_warning "Attempting automatic rollback..."
            do_rollback "$BACKUP_PATH"
        fi
        exit 1
    fi

    print_success "All upgraded containers are healthy"
}

step_cleanup() {
    print_section "Step 10: Cleanup"

    # Clean up old images
    docker_cleanup_old_images 3

    # Clean up old backups
    cleanup_old_backups 5

    # Clean up old frontend backups
    cleanup_frontend_backups 3

    print_success "Cleanup complete"
}

do_rollback() {
    local backup_path="${1:-}"

    if [[ -z "$backup_path" ]]; then
        # Find the latest backup
        local latest
        latest=$(get_latest_backup)

        if [[ -z "$latest" ]]; then
            print_error "No backups available for rollback"
            exit 1
        fi

        backup_path="${BACKUP_DIR}/${latest}"
    fi

    print_section "Rolling Back"
    print_info "Using backup: $backup_path"

    # Get the version to rollback to
    local rollback_version="$CURRENT_VERSION"
    if [[ -f "$backup_path/rollback.json" ]]; then
        rollback_version=$(grep -o '"to_version"[^,]*' "$backup_path/rollback.json" | cut -d'"' -f4)
    fi

    print_info "Rolling back to version: $rollback_version"
    print_info "Infrastructure (postgres, redis, rabbitmq) will NOT be touched"

    # Update version in config
    save_config_value "VERSION" "$rollback_version" "$DEPLOY_ROOT/portal.env"

    # Get compose files
    local compose_args
    compose_args=$(get_compose_files_for_modules "$INFRASTRUCTURE_MODE" "${MODULES:-portal}")

    # Build env-file args (includes portal.secrets.env if it exists)
    local env_args
    env_args=$(_build_env_file_args "$DEPLOY_ROOT/portal.env")

    # Get list of app services (exclude infrastructure)
    local app_services
    app_services=$(docker compose $compose_args $env_args config --services 2>/dev/null \
        | grep -v -E '^(postgres|redis|rabbitmq|clamav)$' | tr '\n' ' ' || true)

    # Stop only app services
    print_info "Stopping app services..."
    for svc in $app_services; do
        docker compose $compose_args $env_args stop "$svc" 2>/dev/null || true
        docker compose $compose_args $env_args rm -f "$svc" 2>/dev/null || true
    done

    # Start app services with rolled back version
    print_info "Starting app services with rolled back version..."
    docker compose $compose_args $env_args up -d --no-deps --force-recreate $app_services

    # Restore database if needed
    if [[ -f "$backup_path/database.sql" ]]; then
        print_info "Restoring database..."
        sleep 10  # Wait for postgres to be ready
        restore_database "$backup_path"
    fi

    # Wait for health
    local container="${PROJECT_NAME:-ezy-portal}"
    if wait_for_healthy "$container" 120; then
        print_success "Rollback completed successfully"
    else
        print_error "Rollback completed but portal is not healthy"
        print_info "Check logs: docker logs $container"
    fi
}

show_success() {
    local app_url="${APPLICATION_URL:-https://localhost}"

    print_section "Upgrade Complete!"

    echo ""
    print_success "EZY Portal upgrade complete!"
    echo ""
    echo "  Backend:  $CURRENT_BACKEND_VERSION -> $BACKEND_VERSION"
    echo "  Frontend: $CURRENT_FRONTEND_VERSION -> $FRONTEND_VERSION"
    echo ""
    echo "  Portal URL:       $app_url"
    echo ""

    if [[ -n "${BACKUP_PATH:-}" ]]; then
        echo "  Backup location:  $BACKUP_PATH"
        echo ""
        echo "  To rollback:      ./upgrade.sh --rollback"
    fi

    log_info "Upgrade completed: Backend $CURRENT_BACKEND_VERSION -> $BACKEND_VERSION, Frontend $CURRENT_FRONTEND_VERSION -> $FRONTEND_VERSION"
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    init_logging
    log_info "Starting upgrade - Target version: $VERSION"

    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║                    EZY Portal Upgrade                         ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    parse_arguments "$@"

    # Handle rollback mode
    if [[ "$DO_ROLLBACK" == true ]]; then
        step_validate_installation
        do_rollback
        exit 0
    fi

    # Normal upgrade flow
    step_validate_installation
    step_check_prerequisites
    step_compare_versions
    step_create_backup

    if [[ "$ONLY_FRONTEND" != true ]]; then
        step_pull_new_image
    fi

    if [[ "$SKIP_FRONTEND" != true ]]; then
        step_update_frontend
    fi

    if [[ "$ONLY_FRONTEND" != true ]]; then
        step_stop_services
        step_start_new_version
        step_verify_health
    fi

    step_cleanup
    show_success
}

# Run main function
main "$@"
