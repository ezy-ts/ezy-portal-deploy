#!/bin/bash
# =============================================================================
# EZY Portal - Docker Operations
# =============================================================================
# Docker and Docker Compose operations for portal deployment
# =============================================================================

# Source common utilities if not already loaded
if [[ -z "${NC:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# Default values
REGISTRY="ghcr.io"
GITHUB_ORG="${GITHUB_ORG:-ezy-ts}"

# Module image names
# Note: portal now uses backend-only image (frontend served by nginx)
declare -A MODULE_IMAGES=(
    ["portal"]="ezy-portal-backend"
    ["bp"]="ezy-portal-bp"
    ["items"]="ezy-portal-items"
    ["prospects"]="ezy-portal-prospects"
    ["pricing-tax"]="ezy-portal-pricing-tax"
    ["crm"]="ezy-portal-crm"
)

# Get image name for a module (always returns full GHCR path)
get_module_image() {
    local module="$1"
    local image_name="${MODULE_IMAGES[$module]:-ezy-portal-backend}"

    echo "${REGISTRY}/${GITHUB_ORG}/${image_name}"
}

# Legacy compatibility (now points to backend)
IMAGE_NAME="ezy-portal-backend"
FULL_IMAGE="${REGISTRY}/${GITHUB_ORG}/${IMAGE_NAME}"

# -----------------------------------------------------------------------------
# Registry Operations
# -----------------------------------------------------------------------------

docker_login_ghcr() {
    local username="${GITHUB_USERNAME:-$GITHUB_ORG}"

    if [[ -z "${GITHUB_PAT:-}" ]]; then
        print_error "GITHUB_PAT is not set"
        return 1
    fi

    print_info "Logging in to GitHub Container Registry..."

    if echo "$GITHUB_PAT" | docker login "$REGISTRY" -u "$username" --password-stdin 2>/dev/null; then
        print_success "Logged in to $REGISTRY"
        return 0
    else
        print_error "Failed to login to $REGISTRY"
        return 1
    fi
}

docker_logout_ghcr() {
    docker logout "$REGISTRY" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Image Operations
# -----------------------------------------------------------------------------

docker_pull_image() {
    local tag="${1:-latest}"
    local module="${2:-portal}"
    local image

    image="$(get_module_image "$module"):${tag}"

    # Always pull for 'latest' tag to ensure we have the newest version
    # For specific version tags, skip if already exists locally
    if [[ "$tag" != "latest" ]] && docker image inspect "$image" &>/dev/null; then
        print_success "Image found locally: $image"
        return 0
    fi

    # Pull from registry
    print_info "Pulling image: $image"

    if docker pull "$image"; then
        print_success "Successfully pulled: $image"
        return 0
    else
        print_error "Failed to pull: $image"
        print_info "Check your GITHUB_PAT and network connection, or build/tag the image locally as: $image"
        return 1
    fi
}

# Pull all images for selected modules
docker_pull_modules() {
    local tag="${1:-latest}"
    local modules="${2:-portal}"
    local failed=0

    IFS=',' read -ra module_array <<< "$modules"

    for module in "${module_array[@]}"; do
        module=$(echo "$module" | xargs)  # trim whitespace
        if [[ -n "$module" ]]; then
            print_subsection "Module: $module"
            if ! docker_pull_image "$tag" "$module"; then
                ((failed++))
            fi
        fi
    done

    if [[ $failed -gt 0 ]]; then
        print_error "Failed to pull $failed module(s)"
        return 1
    fi

    return 0
}

docker_image_exists() {
    local tag="${1:-latest}"
    local image="${FULL_IMAGE}:${tag}"

    docker image inspect "$image" &>/dev/null
}

get_image_digest() {
    local tag="${1:-latest}"
    local image="${FULL_IMAGE}:${tag}"

    docker image inspect "$image" --format='{{.Id}}' 2>/dev/null | cut -d: -f2 | head -c 12
}

get_latest_remote_tag() {
    # Note: This requires authentication with the registry
    # For now, we'll just return "latest"
    # In a full implementation, you'd query the registry API
    echo "latest"
}

list_local_images() {
    docker images --filter "reference=${FULL_IMAGE}*" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
}

# -----------------------------------------------------------------------------
# Docker Compose Operations
# -----------------------------------------------------------------------------

get_compose_file() {
    local infra_mode="${1:-full}"
    local deploy_root="${DEPLOY_ROOT:-$(get_deploy_root)}"
    local base_file

    if [[ "$infra_mode" == "full" ]]; then
        base_file="${deploy_root}/docker/docker-compose.full.yml"
    else
        base_file="${deploy_root}/docker/docker-compose.portal-only.yml"
    fi

    # Append limits overlay if high-performance mode is enabled
    if [[ "${PERF_MODE:-}" == "high" ]]; then
        echo "${base_file} -f ${deploy_root}/docker/docker-compose.limits.yml"
    else
        echo "$base_file"
    fi
}

# Get compose files for selected modules
# Returns space-separated list of -f flags for docker compose
# Modules must be in dependency order: items -> bp -> prospects
get_compose_files_for_modules() {
    local infra_mode="${1:-full}"
    local modules="${2:-portal}"
    local deploy_root="${DEPLOY_ROOT:-$(get_deploy_root)}"

    local compose_args=""
    local base_compose

    # Base compose file
    base_compose=$(get_compose_file "$infra_mode")
    compose_args="-f $base_compose"

    # Module order (dependencies first)
    local ordered_modules=("items" "bp" "prospects" "pricing-tax" "crm")

    # Add module-specific compose files in dependency order
    for module in "${ordered_modules[@]}"; do
        # Check if this module is in the requested modules
        if [[ ",$modules," == *",$module,"* ]]; then
            local module_compose="${deploy_root}/docker/docker-compose.module-${module}.yml"
            if [[ -f "$module_compose" ]]; then
                compose_args="$compose_args -f $module_compose"
            else
                print_warning "Module compose file not found: $module_compose"
            fi
        fi
    done

    echo "$compose_args"
}

# Generate environment variables for module images
generate_module_image_vars() {
    local tag="${1:-latest}"
    local modules="${2:-portal}"

    IFS=',' read -ra module_array <<< "$modules"

    for module in "${module_array[@]}"; do
        module=$(echo "$module" | xargs)  # trim whitespace
        if [[ -n "$module" ]]; then
            local var_name
            var_name="$(echo "${module}_IMAGE" | tr '[:lower:]-' '[:upper:]_')"
            local image
            image="$(get_module_image "$module")"
            export "$var_name=$image"
            export "${var_name}_TAG=$tag"
        fi
    done
}

docker_compose_up() {
    local compose_file="$1"
    local env_file="${2:-${DEPLOY_ROOT}/portal.env}"
    local services="${3:-}"
    local pull_policy="${4:-}"

    local cmd="docker compose -f $compose_file --env-file $env_file up -d"

    # Add --pull always if requested (use for 'latest' tags)
    if [[ "$pull_policy" == "always" ]]; then
        cmd="$cmd --pull always"
    fi

    if [[ -n "$services" ]]; then
        cmd="$cmd $services"
    fi

    print_info "Starting services..."
    log_info "Running: $cmd"

    if eval "$cmd"; then
        print_success "Services started"
        return 0
    else
        print_error "Failed to start services"
        return 1
    fi
}

docker_compose_down() {
    local compose_file="$1"
    local env_file="${2:-${DEPLOY_ROOT}/portal.env}"
    local remove_volumes="${3:-false}"

    local cmd="docker compose -f $compose_file --env-file $env_file down"

    if [[ "$remove_volumes" == "true" ]]; then
        cmd="$cmd -v"
        print_warning "Removing volumes as requested"
    fi

    print_info "Stopping services..."
    log_info "Running: $cmd"

    if eval "$cmd"; then
        print_success "Services stopped"
        return 0
    else
        print_error "Failed to stop services"
        return 1
    fi
}

docker_compose_restart() {
    local compose_file="$1"
    local env_file="${2:-${DEPLOY_ROOT}/portal.env}"
    local service="${3:-}"

    local cmd="docker compose -f $compose_file --env-file $env_file restart"

    if [[ -n "$service" ]]; then
        cmd="$cmd $service"
    fi

    print_info "Restarting ${service:-all services}..."

    if eval "$cmd"; then
        print_success "Restart complete"
        return 0
    else
        print_error "Restart failed"
        return 1
    fi
}

docker_compose_pull() {
    local compose_file="$1"
    local env_file="${2:-${DEPLOY_ROOT}/portal.env}"

    print_info "Pulling images defined in compose file..."

    if docker compose -f "$compose_file" --env-file "$env_file" pull; then
        print_success "Images pulled"
        return 0
    else
        print_error "Failed to pull images"
        return 1
    fi
}

docker_compose_logs() {
    local compose_file="$1"
    local service="${2:-}"
    local lines="${3:-100}"
    local follow="${4:-false}"

    local cmd="docker compose -f $compose_file logs --tail $lines"

    if [[ "$follow" == "true" ]]; then
        cmd="$cmd -f"
    fi

    if [[ -n "$service" ]]; then
        cmd="$cmd $service"
    fi

    eval "$cmd"
}

docker_compose_ps() {
    local compose_file="$1"
    local env_file="${2:-${DEPLOY_ROOT}/portal.env}"

    docker compose -f "$compose_file" --env-file "$env_file" ps
}

# -----------------------------------------------------------------------------
# Health Checks
# -----------------------------------------------------------------------------

wait_for_healthy() {
    local container="$1"
    local timeout="${2:-120}"
    local interval="${3:-5}"
    local elapsed=0

    print_info "Waiting for $container to be healthy (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not_found")

        case "$status" in
            healthy)
                print_success "$container is healthy"
                return 0
                ;;
            unhealthy)
                print_error "$container is unhealthy"
                return 1
                ;;
            not_found)
                print_error "Container $container not found"
                return 1
                ;;
            *)
                # starting or no health check
                printf "."
                ;;
        esac

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
    print_error "Timeout waiting for $container to be healthy"
    return 1
}

check_container_health() {
    local container="$1"

    local status
    status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null)

    case "$status" in
        healthy) return 0 ;;
        *) return 1 ;;
    esac
}

get_container_status() {
    local container="$1"

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "not_found"
        return
    fi

    local state
    state=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)

    if [[ "$state" == "running" ]]; then
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null)

        if [[ -n "$health" ]] && [[ "$health" != "none" ]]; then
            echo "$health"
        else
            echo "running"
        fi
    else
        echo "$state"
    fi
}

run_health_checks() {
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local failed=0

    print_subsection "Running health checks"

    # Check portal container
    local portal_status
    portal_status=$(get_container_status "$project_name")

    if [[ "$portal_status" == "healthy" ]]; then
        print_success "Portal: healthy"
    elif [[ "$portal_status" == "running" ]]; then
        print_warning "Portal: running (no health check)"
    else
        print_error "Portal: $portal_status"
        ((failed++))
    fi

    # Check infrastructure if full mode
    local infra_mode
    infra_mode=$(detect_infrastructure_type 2>/dev/null || echo "full")

    if [[ "$infra_mode" == "full" ]]; then
        for service in postgres redis rabbitmq nginx; do
            local container="${project_name}-${service}"
            local status
            status=$(get_container_status "$container")

            if [[ "$status" == "healthy" ]] || [[ "$status" == "running" ]]; then
                print_success "${service}: ${status}"
            elif [[ "$status" == "not_found" ]]; then
                # Some services might not exist in all configurations
                :
            else
                print_error "${service}: ${status}"
                ((failed++))
            fi
        done
    fi

    # HTTP health check
    local app_url="${APPLICATION_URL:-https://localhost}"
    local health_endpoint="${app_url}/health"

    print_info "Checking HTTP health endpoint..."

    if curl -sf -k "$health_endpoint" &>/dev/null; then
        print_success "HTTP health check passed"
    else
        print_warning "HTTP health check failed (may still be starting)"
    fi

    return "$failed"
}

# -----------------------------------------------------------------------------
# Container Operations
# -----------------------------------------------------------------------------

get_container_logs() {
    local container="$1"
    local lines="${2:-50}"

    docker logs --tail "$lines" "$container" 2>&1
}

exec_in_container() {
    local container="$1"
    shift
    local cmd="$*"

    docker exec -it "$container" $cmd
}

# -----------------------------------------------------------------------------
# Cleanup Operations
# -----------------------------------------------------------------------------

docker_cleanup_old_images() {
    local keep="${1:-2}"

    print_info "Cleaning up old images (keeping last $keep)..."

    # Get list of image tags sorted by creation date
    local images
    images=$(docker images "${FULL_IMAGE}" --format '{{.Tag}} {{.CreatedAt}}' | sort -k2 -r | tail -n +$((keep + 1)) | awk '{print $1}')

    if [[ -z "$images" ]]; then
        print_info "No old images to clean up"
        return 0
    fi

    for tag in $images; do
        if [[ "$tag" != "latest" ]]; then
            print_info "Removing: ${FULL_IMAGE}:${tag}"
            docker rmi "${FULL_IMAGE}:${tag}" 2>/dev/null || true
        fi
    done

    # Clean up dangling images
    docker image prune -f &>/dev/null || true

    print_success "Cleanup complete"
}

docker_cleanup_all() {
    print_warning "This will remove all portal images and volumes"

    if ! confirm "Are you sure?" "n"; then
        print_info "Cancelled"
        return 0
    fi

    # Remove containers
    docker rm -f $(docker ps -aq --filter "name=${PROJECT_NAME:-ezy-portal}") 2>/dev/null || true

    # Remove images
    docker rmi $(docker images "${FULL_IMAGE}" -q) 2>/dev/null || true

    # Remove volumes
    docker volume rm $(docker volume ls -q --filter "name=${PROJECT_NAME:-ezy-portal}") 2>/dev/null || true

    print_success "Cleanup complete"
}

# -----------------------------------------------------------------------------
# Database Migration
# -----------------------------------------------------------------------------

run_database_migration() {
    local container="${PROJECT_NAME:-ezy-portal}"

    print_info "Database migrations are applied automatically on startup"

    # Check if portal is running and healthy
    if ! check_container_health "$container"; then
        print_warning "Portal container is not healthy, migrations may not have completed"
        return 1
    fi

    print_success "Migrations should be complete (check logs if issues persist)"
    return 0
}
