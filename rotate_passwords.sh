#!/bin/bash
# =============================================================================
# EZY Portal - Password Rotation
# =============================================================================
# Rotates database and/or RabbitMQ passwords with zero-downtime.
#
# Usage:
#   ./rotate_passwords.sh                # Rotate all passwords
#   ./rotate_passwords.sh --db-only      # Rotate only database password
#   ./rotate_passwords.sh --rmq-only     # Rotate only RabbitMQ password
#   ./rotate_passwords.sh --dry-run      # Show what would change without modifying
#
# Requirements:
#   - Infrastructure containers must be running and healthy
#   - INFRASTRUCTURE_MODE=full (cannot rotate external service passwords)
# =============================================================================

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_ROOT="$SCRIPT_DIR"

# Source library scripts
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/docker.sh"

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

DRY_RUN=false
ROTATE_DB=true
ROTATE_RMQ=true

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------

show_help() {
    echo "EZY Portal Password Rotation"
    echo ""
    echo "Rotates database and/or RabbitMQ passwords for full-infrastructure deployments."
    echo ""
    echo "Usage: ./rotate_passwords.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run     Show what would change without modifying anything"
    echo "  --db-only     Rotate only the PostgreSQL password"
    echo "  --rmq-only    Rotate only the RabbitMQ password"
    echo "  --help, -h    Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./rotate_passwords.sh              # Rotate all passwords"
    echo "  ./rotate_passwords.sh --dry-run    # Preview changes"
    echo "  ./rotate_passwords.sh --db-only    # Rotate only DB password"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --db-only)
                ROTATE_DB=true
                ROTATE_RMQ=false
                shift
                ;;
            --rmq-only)
                ROTATE_DB=false
                ROTATE_RMQ=true
                shift
                ;;
            -h|--help)
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

# -----------------------------------------------------------------------------
# Pre-flight Checks
# -----------------------------------------------------------------------------

preflight_checks() {
    print_section "Pre-flight Checks"

    # Check portal.env exists
    if [[ ! -f "${DEPLOY_ROOT}/portal.env" ]]; then
        print_error "portal.env not found. Run install.sh first."
        exit 1
    fi

    # Load config
    load_config "${DEPLOY_ROOT}/portal.env"
    local secrets_file="${DEPLOY_ROOT}/portal.secrets.env"
    if [[ -f "$secrets_file" ]]; then
        load_config "$secrets_file"
    fi

    # Check infrastructure mode
    local infra_mode
    infra_mode=$(detect_infrastructure_type)
    if [[ "$infra_mode" != "full" ]]; then
        print_error "Password rotation is only supported for INFRASTRUCTURE_MODE=full"
        print_info "For external infrastructure, rotate passwords using your provider's tools,"
        print_info "then update portal.secrets.env (or portal.env) manually and run ./reload.sh"
        exit 1
    fi
    print_success "Infrastructure mode: full"

    local project_name="${PROJECT_NAME:-ezy-portal}"

    # Check postgres container
    if [[ "$ROTATE_DB" == "true" ]]; then
        local pg_container="${project_name}-postgres"
        local pg_status
        pg_status=$(get_container_status "$pg_container")
        if [[ "$pg_status" != "healthy" && "$pg_status" != "running" ]]; then
            print_error "PostgreSQL container ($pg_container) is not running (status: $pg_status)"
            exit 1
        fi
        print_success "PostgreSQL container: $pg_status"
    fi

    # Check rabbitmq container
    if [[ "$ROTATE_RMQ" == "true" ]]; then
        local rmq_container="${project_name}-rabbitmq"
        local rmq_status
        rmq_status=$(get_container_status "$rmq_container")
        if [[ "$rmq_status" != "healthy" && "$rmq_status" != "running" ]]; then
            print_error "RabbitMQ container ($rmq_container) is not running (status: $rmq_status)"
            exit 1
        fi
        print_success "RabbitMQ container: $rmq_status"
    fi
}

# -----------------------------------------------------------------------------
# Determine Config File for Secrets
# -----------------------------------------------------------------------------

# Returns the file path where secrets are stored.
# Uses portal.secrets.env if it exists, otherwise falls back to portal.env.
get_secrets_file() {
    local secrets_file="${DEPLOY_ROOT}/portal.secrets.env"
    if [[ -f "$secrets_file" ]]; then
        echo "$secrets_file"
    else
        echo "${DEPLOY_ROOT}/portal.env"
    fi
}

# -----------------------------------------------------------------------------
# Database Password Rotation
# -----------------------------------------------------------------------------

rotate_database_password() {
    print_subsection "Rotating PostgreSQL Password"

    local project_name="${PROJECT_NAME:-ezy-portal}"
    local pg_container="${project_name}-postgres"
    local db_user="${POSTGRES_USER:-postgres}"
    local db_name="${POSTGRES_DB:-portal}"
    local secrets_file
    secrets_file=$(get_secrets_file)

    # Generate new password
    local new_password
    new_password=$(generate_password_alphanum 32)

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY RUN] Would rotate PostgreSQL password for user '$db_user'"
        print_info "[DRY RUN] Would update POSTGRES_PASSWORD in $secrets_file"
        print_info "[DRY RUN] Would update ConnectionStrings__DefaultConnection in $secrets_file"
        return 0
    fi

    # Change password in PostgreSQL
    print_info "Changing PostgreSQL password for user '$db_user'..."
    if ! docker exec "$pg_container" psql -U "$db_user" -d "$db_name" \
        -c "ALTER USER ${db_user} PASSWORD '${new_password}';" &>/dev/null; then
        print_error "Failed to change PostgreSQL password"
        return 1
    fi
    print_success "PostgreSQL password changed"

    # Verify new password works
    print_info "Verifying new password..."
    if ! docker exec -e PGPASSWORD="$new_password" "$pg_container" \
        psql -U "$db_user" -d "$db_name" -c "SELECT 1;" &>/dev/null; then
        print_error "New password verification failed!"
        print_error "The database password was changed but verification failed."
        print_error "You may need to manually fix the password."
        return 1
    fi
    print_success "New password verified"

    # Update secrets file
    print_info "Updating configuration..."
    save_config_value "POSTGRES_PASSWORD" "$new_password" "$secrets_file"

    # Rebuild connection string
    local pg_host="${POSTGRES_HOST:-postgres}"
    local pg_port="${POSTGRES_PORT:-5432}"
    local conn_string="Host=${pg_host};Port=${pg_port};Database=${db_name};Username=${db_user};Password=${new_password}"
    save_config_value "ConnectionStrings__DefaultConnection" "$conn_string" "$secrets_file"

    print_success "PostgreSQL password rotated successfully"
}

# -----------------------------------------------------------------------------
# RabbitMQ Password Rotation
# -----------------------------------------------------------------------------

rotate_rabbitmq_password() {
    print_subsection "Rotating RabbitMQ Password"

    local project_name="${PROJECT_NAME:-ezy-portal}"
    local rmq_container="${project_name}-rabbitmq"
    local rmq_user="${RABBITMQ_USER:-${RABBITMQ_DEFAULT_USER:-portal}}"
    local secrets_file
    secrets_file=$(get_secrets_file)

    # Generate new password
    local new_password
    new_password=$(generate_password_alphanum 32)

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY RUN] Would rotate RabbitMQ password for user '$rmq_user'"
        print_info "[DRY RUN] Would update RABBITMQ_PASSWORD in $secrets_file"
        print_info "[DRY RUN] Would update RABBITMQ_DEFAULT_PASS in $secrets_file"
        print_info "[DRY RUN] Would update RabbitMq__Password in $secrets_file"
        return 0
    fi

    # Change password in RabbitMQ
    print_info "Changing RabbitMQ password for user '$rmq_user'..."
    if ! docker exec "$rmq_container" rabbitmqctl change_password "$rmq_user" "$new_password" &>/dev/null; then
        print_error "Failed to change RabbitMQ password"
        return 1
    fi
    print_success "RabbitMQ password changed"

    # Verify new password works
    print_info "Verifying new password..."
    if ! docker exec "$rmq_container" rabbitmqctl authenticate_user "$rmq_user" "$new_password" &>/dev/null; then
        print_error "New password verification failed!"
        return 1
    fi
    print_success "New password verified"

    # Update secrets file
    print_info "Updating configuration..."
    save_config_value "RABBITMQ_PASSWORD" "$new_password" "$secrets_file"
    save_config_value "RABBITMQ_DEFAULT_PASS" "$new_password" "$secrets_file"
    save_config_value "RabbitMq__Password" "$new_password" "$secrets_file"

    print_success "RabbitMQ password rotated successfully"
}

# -----------------------------------------------------------------------------
# Restart Application Services
# -----------------------------------------------------------------------------

restart_app_services() {
    print_subsection "Restarting Application Services"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY RUN] Would restart all application services (not infrastructure)"
        return 0
    fi

    local infra_mode
    infra_mode=$(detect_infrastructure_type)
    local compose_args
    compose_args=$(get_compose_files_for_modules "$infra_mode" "${MODULES:-portal}")

    local env_args
    env_args=$(_build_env_file_args "${DEPLOY_ROOT}/portal.env")

    # Get app services (exclude infrastructure)
    local app_services
    app_services=$(eval "docker compose $compose_args $env_args ps --services 2>/dev/null" | grep -v -E '^(postgres|redis|rabbitmq)$' || true)

    if [[ -z "$app_services" ]]; then
        print_warning "No application services found to restart"
        return 0
    fi

    print_info "Restarting: $(echo $app_services | tr '\n' ' ')"

    for svc in $app_services; do
        print_info "Restarting $svc..."
        eval "docker compose $compose_args $env_args stop $svc" &>/dev/null
        eval "docker compose $compose_args $env_args rm -f $svc" &>/dev/null
        eval "docker compose $compose_args $env_args up -d --no-deps --force-recreate $svc" &>/dev/null
    done

    print_success "Application services restarted"
}

# -----------------------------------------------------------------------------
# Post-rotation Health Check
# -----------------------------------------------------------------------------

post_rotation_health_check() {
    print_subsection "Post-Rotation Health Check"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY RUN] Would run health checks"
        return 0
    fi

    print_info "Waiting for services to start (30s)..."
    sleep 30

    if run_health_checks; then
        print_success "All health checks passed"
        return 0
    else
        print_warning "Some health checks failed. Services may still be starting."
        print_info "Check logs: docker logs ${PROJECT_NAME:-ezy-portal}"
        return 0
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_arguments "$@"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_section "Password Rotation (DRY RUN)"
    else
        print_section "Password Rotation"
    fi

    preflight_checks

    # Backup current secrets file before rotation
    if [[ "$DRY_RUN" == "false" ]]; then
        local secrets_file
        secrets_file=$(get_secrets_file)
        local backup_file="${secrets_file}.pre-rotation.bak"
        cp "$secrets_file" "$backup_file"
        print_success "Secrets backed up to: $backup_file"
    fi

    local rotated=0

    if [[ "$ROTATE_DB" == "true" ]]; then
        rotate_database_password
        ((rotated++))
    fi

    if [[ "$ROTATE_RMQ" == "true" ]]; then
        rotate_rabbitmq_password
        ((rotated++))
    fi

    # Restart app services to pick up new passwords
    if [[ $rotated -gt 0 ]]; then
        restart_app_services
        post_rotation_health_check
    fi

    echo ""
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "Dry run complete. No changes were made."
    else
        print_success "Password rotation complete!"
        print_warning "Delete the backup file when you've confirmed everything works:"
        print_info "  rm ${secrets_file}.pre-rotation.bak"
    fi
}

main "$@"
