#!/bin/bash
# =============================================================================
# EZY Portal - Backup and Restore
# =============================================================================
# Backup and restore operations for upgrades and disaster recovery
# =============================================================================

# Source common utilities if not already loaded
if [[ -z "${NC:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

BACKUP_DIR="${DEPLOY_ROOT}/backups"

# -----------------------------------------------------------------------------
# Backup Directory Management
# -----------------------------------------------------------------------------

create_backup_dir() {
    local timestamp
    timestamp=$(get_timestamp)
    local backup_path="${BACKUP_DIR}/${timestamp}"

    mkdir -p "$backup_path"
    echo "$backup_path"
}

list_backups() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        print_info "No backups found"
        return 0
    fi

    print_subsection "Available Backups"

    local backups
    backups=$(ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r)

    if [[ -z "$backups" ]]; then
        print_info "No backups found"
        return 0
    fi

    for backup in $backups; do
        local backup_path="${BACKUP_DIR}/${backup}"
        local size
        size=$(du -sh "$backup_path" 2>/dev/null | awk '{print $1}')

        # Check what's in the backup
        local contents=""
        [[ -f "$backup_path/database.sql" ]] && contents+="db "
        [[ -f "$backup_path/portal.env" ]] && contents+="config "
        [[ -d "$backup_path/uploads" ]] && contents+="uploads "
        [[ -f "$backup_path/metadata.json" ]] && contents+="meta "

        echo "  $backup  ($size)  [$contents]"
    done
}

get_latest_backup() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        return 1
    fi

    ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r | head -1
}

# -----------------------------------------------------------------------------
# Backup Operations
# -----------------------------------------------------------------------------

backup_database() {
    local backup_path="$1"
    local container="${PROJECT_NAME:-ezy-portal}-postgres"

    print_info "Backing up database..."

    # Check if postgres container exists and is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_warning "PostgreSQL container not found, skipping database backup"
        return 0
    fi

    # Load config to get credentials
    local db_user db_name
    if [[ -f "${DEPLOY_ROOT}/portal.env" ]]; then
        source "${DEPLOY_ROOT}/portal.env"
        db_user="${POSTGRES_USER:-postgres}"
        db_name="${POSTGRES_DB:-portal}"
    else
        db_user="postgres"
        db_name="portal"
    fi

    # Perform backup
    if docker exec "$container" pg_dump -U "$db_user" "$db_name" > "$backup_path/database.sql" 2>/dev/null; then
        local size
        size=$(du -h "$backup_path/database.sql" | awk '{print $1}')
        print_success "Database backed up ($size)"
        return 0
    else
        print_error "Database backup failed"
        return 1
    fi
}

backup_uploads() {
    local backup_path="$1"
    local container="${PROJECT_NAME:-ezy-portal}"

    print_info "Backing up uploads..."

    # Check if container exists
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        print_warning "Portal container not found, skipping uploads backup"
        return 0
    fi

    mkdir -p "$backup_path/uploads"

    # Copy uploads from container volume
    if docker cp "$container:/app/uploads/." "$backup_path/uploads/" 2>/dev/null; then
        local count
        count=$(find "$backup_path/uploads" -type f 2>/dev/null | wc -l)
        print_success "Uploads backed up ($count files)"
        return 0
    else
        print_warning "No uploads to backup or backup failed"
        return 0
    fi
}

backup_config() {
    local backup_path="$1"

    print_info "Backing up configuration..."

    local files_backed=0

    # Backup portal.env (non-sensitive config only)
    if [[ -f "${DEPLOY_ROOT}/portal.env" ]]; then
        cp "${DEPLOY_ROOT}/portal.env" "$backup_path/"
        ((files_backed++))
    fi

    # NOTE: portal.secrets.env is intentionally NOT backed up here.
    # Secrets should be managed separately and not stored in backup directories.
    if [[ -f "${DEPLOY_ROOT}/portal.secrets.env" ]]; then
        print_warning "portal.secrets.env was NOT backed up (by design). Manage secrets separately."
    fi

    # Backup SSL certificates
    if [[ -d "${DEPLOY_ROOT}/nginx/ssl" ]]; then
        mkdir -p "$backup_path/ssl"
        cp "${DEPLOY_ROOT}/nginx/ssl/"* "$backup_path/ssl/" 2>/dev/null || true
        ((files_backed++))
    fi

    # Backup any custom nginx configs
    if [[ -f "${DEPLOY_ROOT}/nginx/conf.d/custom.conf" ]]; then
        mkdir -p "$backup_path/nginx"
        cp "${DEPLOY_ROOT}/nginx/conf.d/custom.conf" "$backup_path/nginx/"
        ((files_backed++))
    fi

    print_success "Configuration backed up ($files_backed items)"
    return 0
}

backup_logs() {
    local backup_path="$1"
    local container="${PROJECT_NAME:-ezy-portal}"

    print_info "Backing up recent logs..."

    mkdir -p "$backup_path/logs"

    # Get container logs
    docker logs --tail 1000 "$container" > "$backup_path/logs/portal.log" 2>&1 || true

    # Get docker-compose ps output
    local compose_file
    compose_file=$(get_compose_file "$(detect_infrastructure_type)")

    if [[ -f "$compose_file" ]]; then
        docker compose -f "$compose_file" ps > "$backup_path/logs/services.txt" 2>&1 || true
    fi

    print_success "Logs backed up"
    return 0
}

create_backup_metadata() {
    local backup_path="$1"
    local reason="${2:-manual}"

    local version
    version=$(get_current_portal_version 2>/dev/null || echo "unknown")

    cat > "$backup_path/metadata.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "version": "$version",
    "reason": "$reason",
    "hostname": "$(hostname)",
    "user": "$(whoami)"
}
EOF
}

create_full_backup() {
    local reason="${1:-manual}"

    print_section "Creating Full Backup" >&2

    local backup_path
    backup_path=$(create_backup_dir)

    print_info "Backup location: $backup_path" >&2
    echo "" >&2

    local failed=0

    backup_database "$backup_path" >&2 || ((failed++))
    backup_uploads "$backup_path" >&2 || ((failed++))
    backup_config "$backup_path" >&2 || :  # Config backup is optional
    backup_logs "$backup_path" >&2 || :    # Logs backup is optional
    create_backup_metadata "$backup_path" "$reason"

    if [[ $failed -gt 0 ]]; then
        print_warning "Backup completed with $failed warnings" >&2
    else
        print_success "Full backup completed: $backup_path" >&2
    fi

    # Show backup size
    local size
    size=$(du -sh "$backup_path" | awk '{print $1}')
    print_info "Backup size: $size" >&2

    echo "$backup_path"
}

# -----------------------------------------------------------------------------
# Restore Operations
# -----------------------------------------------------------------------------

restore_database() {
    local backup_path="$1"
    local container="${PROJECT_NAME:-ezy-portal}-postgres"

    if [[ ! -f "$backup_path/database.sql" ]]; then
        print_warning "No database backup found in $backup_path"
        return 0
    fi

    print_info "Restoring database..."

    # Load config to get credentials
    local db_user db_name
    if [[ -f "${DEPLOY_ROOT}/portal.env" ]]; then
        source "${DEPLOY_ROOT}/portal.env"
        db_user="${POSTGRES_USER:-postgres}"
        db_name="${POSTGRES_DB:-portal}"
    else
        db_user="postgres"
        db_name="portal"
    fi

    # Restore database
    if cat "$backup_path/database.sql" | docker exec -i "$container" psql -U "$db_user" "$db_name" &>/dev/null; then
        print_success "Database restored"
        return 0
    else
        print_error "Database restore failed"
        return 1
    fi
}

restore_uploads() {
    local backup_path="$1"
    local container="${PROJECT_NAME:-ezy-portal}"

    if [[ ! -d "$backup_path/uploads" ]]; then
        print_warning "No uploads backup found in $backup_path"
        return 0
    fi

    print_info "Restoring uploads..."

    if docker cp "$backup_path/uploads/." "$container:/app/uploads/" 2>/dev/null; then
        print_success "Uploads restored"
        return 0
    else
        print_error "Uploads restore failed"
        return 1
    fi
}

restore_config() {
    local backup_path="$1"

    print_info "Restoring configuration..."

    local restored=0

    # Restore portal.env
    if [[ -f "$backup_path/portal.env" ]]; then
        cp "$backup_path/portal.env" "${DEPLOY_ROOT}/"
        ((restored++))
    fi

    # Restore SSL certificates
    if [[ -d "$backup_path/ssl" ]]; then
        mkdir -p "${DEPLOY_ROOT}/nginx/ssl"
        cp "$backup_path/ssl/"* "${DEPLOY_ROOT}/nginx/ssl/" 2>/dev/null || true
        ((restored++))
    fi

    print_success "Configuration restored ($restored items)"
    return 0
}

restore_full() {
    local backup_path="$1"

    if [[ ! -d "$backup_path" ]]; then
        print_error "Backup not found: $backup_path"
        return 1
    fi

    print_section "Restoring from Backup"
    print_info "Backup: $backup_path"

    # Show backup metadata if available
    if [[ -f "$backup_path/metadata.json" ]]; then
        echo ""
        print_info "Backup metadata:"
        cat "$backup_path/metadata.json"
        echo ""
    fi

    if ! confirm "Proceed with restore?" "n"; then
        print_info "Restore cancelled"
        return 0
    fi

    local failed=0

    restore_config "$backup_path" || ((failed++))
    restore_database "$backup_path" || ((failed++))
    restore_uploads "$backup_path" || ((failed++))

    if [[ $failed -gt 0 ]]; then
        print_error "Restore completed with $failed errors"
        return 1
    fi

    print_success "Restore completed successfully"
    print_info "Restart services to apply changes"

    return 0
}

# -----------------------------------------------------------------------------
# Rollback Operations
# -----------------------------------------------------------------------------

record_rollback_info() {
    local backup_path="$1"
    local current_version="$2"
    local target_version="$3"

    cat > "$backup_path/rollback.json" << EOF
{
    "from_version": "$target_version",
    "to_version": "$current_version",
    "backup_path": "$backup_path",
    "timestamp": "$(date -Iseconds)"
}
EOF
}

rollback_upgrade() {
    local backup_path="${1:-}"

    if [[ -z "$backup_path" ]]; then
        # Find the latest backup
        local latest
        latest=$(get_latest_backup)

        if [[ -z "$latest" ]]; then
            print_error "No backups available for rollback"
            return 1
        fi

        backup_path="${BACKUP_DIR}/${latest}"
    fi

    print_section "Rolling Back Upgrade"
    print_info "Using backup: $backup_path"

    # Get rollback info
    if [[ -f "$backup_path/rollback.json" ]]; then
        local from_version to_version
        from_version=$(grep -o '"from_version"[^,]*' "$backup_path/rollback.json" | cut -d'"' -f4)
        to_version=$(grep -o '"to_version"[^,]*' "$backup_path/rollback.json" | cut -d'"' -f4)
        print_info "Rolling back from $from_version to $to_version"
    fi

    if ! confirm "Proceed with rollback?" "n"; then
        print_info "Rollback cancelled"
        return 0
    fi

    # Restore configuration first
    restore_config "$backup_path"

    # Get compose file and stop services
    local infra_mode compose_file
    infra_mode=$(detect_infrastructure_type)
    compose_file=$(get_compose_file "$infra_mode")

    docker_compose_down "$compose_file"

    # Restore database
    docker_compose_up "$compose_file" "" "postgres"
    sleep 10  # Wait for postgres to start
    restore_database "$backup_path"

    # Start all services with old version
    docker_compose_up "$compose_file"

    # Restore uploads after portal starts
    sleep 5
    restore_uploads "$backup_path"

    # Health check
    sleep 10
    if run_health_checks; then
        print_success "Rollback completed successfully"
        return 0
    else
        print_error "Rollback completed but health checks failed"
        print_info "Check logs: docker logs ${PROJECT_NAME:-ezy-portal}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------

cleanup_old_backups() {
    local keep="${1:-5}"

    print_info "Cleaning up old backups (keeping last $keep)..."

    if [[ ! -d "$BACKUP_DIR" ]]; then
        return 0
    fi

    local backups
    backups=$(ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r | tail -n +$((keep + 1)))

    if [[ -z "$backups" ]]; then
        print_info "No old backups to clean up"
        return 0
    fi

    for backup in $backups; do
        print_info "Removing: $backup"
        rm -rf "${BACKUP_DIR}/${backup}"
    done

    print_success "Cleanup complete"
}
