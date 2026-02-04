#!/bin/bash
# =============================================================================
# EZY Portal - Module Installation Helpers
# =============================================================================
# Shared functions for installing/uninstalling portal modules
# =============================================================================

# Source dependencies if not already loaded
if [[ -z "${NC:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi
if ! declare -f check_docker_installed &>/dev/null; then
    source "$(dirname "${BASH_SOURCE[0]}")/checks.sh"
fi
if ! declare -f get_compose_file &>/dev/null; then
    source "$(dirname "${BASH_SOURCE[0]}")/docker.sh"
fi

# -----------------------------------------------------------------------------
# Portal State Checks
# -----------------------------------------------------------------------------

# Check if the main portal is running and healthy
# Usage: check_portal_running [require_healthy]
# Args: require_healthy - if "true", fail if not healthy (default: prompt)
check_portal_running() {
    local require_healthy="${1:-false}"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="$project_name"

    debug "Checking portal container: $container"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_error "Portal is not running"
        print_info "Start the portal first with: ./install.sh"
        return 1
    fi

    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
    debug "Portal health status: $health"

    if [[ "$health" != "healthy" ]]; then
        if [[ "$require_healthy" == "true" ]]; then
            print_error "Portal is running but not healthy (status: $health)"
            return 1
        fi
        print_warning "Portal is running but not healthy (status: $health)"
        if ! confirm "Continue anyway?" "n"; then
            return 1
        fi
    else
        print_success "Portal is running and healthy"
    fi

    return 0
}

# Check if required module dependencies are running
# Usage: check_module_dependencies <dependencies> [project_name]
# Args: dependencies - comma-separated list of required modules
check_module_dependencies() {
    local deps="$1"
    local project_name="${2:-${PROJECT_NAME:-ezy-portal}}"

    if [[ -z "$deps" ]]; then
        return 0
    fi

    print_info "Checking dependencies..."
    debug "Required dependencies: $deps"

    IFS=',' read -ra dep_array <<< "$deps"
    for dep in "${dep_array[@]}"; do
        dep=$(echo "$dep" | xargs)  # trim whitespace
        [[ -z "$dep" ]] && continue

        local container="${project_name}-${dep}"
        debug "Checking dependency container: $container"

        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            print_error "Required module '$dep' is not running"
            print_info "Add it first with: ./add-module.sh $dep"
            return 1
        fi

        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")

        if [[ "$health" == "healthy" ]]; then
            print_success "Dependency '$dep' is running and healthy"
        else
            print_warning "Dependency '$dep' is running but not healthy (status: $health)"
        fi
    done

    return 0
}

# Check if a module/service is already running
# Usage: check_not_running <container_name> [auto_recreate]
# Args: auto_recreate - if "true", stop without prompting
# Returns: 0 to continue (not running or user confirmed recreate), exits with 0 if user declined
check_not_running() {
    local container="$1"
    local auto_recreate="${2:-false}"

    debug "Checking if container already running: $container"

    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_warning "Container '$container' is already running"

        if [[ "$auto_recreate" == "true" ]]; then
            print_info "Stopping existing container..."
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
            return 0
        fi

        if confirm "Recreate the container?" "n"; then
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
            return 0
        fi
        exit 0
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Container Operations
# -----------------------------------------------------------------------------

# Stop and remove a container
# Usage: stop_container <container_name>
stop_container() {
    local container="$1"

    debug "Stopping container: $container"

    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        print_info "Stopping container: $container"
        docker stop "$container" 2>/dev/null || true
        docker rm "$container" 2>/dev/null || true
        print_success "Container '$container' stopped"
    else
        debug "Container '$container' not found"
    fi

    return 0
}

# Wait for a container to become healthy
# Usage: wait_for_container_healthy <container_name> [timeout_seconds]
wait_for_container_healthy() {
    local container="$1"
    local timeout="${2:-120}"

    print_info "Waiting for $container to be healthy (timeout: ${timeout}s)..."
    debug "Starting health check wait for: $container"

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")

        debug "Health check at ${elapsed}s: $health"

        if [[ "$health" == "healthy" ]]; then
            print_success "$container is healthy"
            return 0
        fi

        # Check if container is starting (has health check) or running (no health check)
        local state
        state=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "")

        if [[ "$state" != "running" ]]; then
            print_warning "Container is not running (state: $state)"
            break
        fi

        # If there's no health check defined, consider running as success
        if [[ "$health" == "none" ]]; then
            print_info "Container has no health check defined, assuming healthy"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    print_warning "$container did not become healthy within ${timeout}s"
    print_info "Check logs: docker logs $container"
    return 1
}

# -----------------------------------------------------------------------------
# Standard Module Operations
# -----------------------------------------------------------------------------

# Start a standard built-in module (items, bp, prospects)
# Usage: start_standard_module <module_name> [version]
start_standard_module() {
    local module="$1"
    local version="${2:-latest}"
    local project_name="${PROJECT_NAME:-ezy-portal}"

    debug "Starting standard module: $module (version: $version)"

    # Load config to get infrastructure mode
    local infra_mode="${INFRASTRUCTURE_MODE:-full}"

    # Build compose file arguments
    local base_compose
    base_compose=$(get_compose_file "$infra_mode")

    local module_compose="${DEPLOY_ROOT}/docker/docker-compose.module-${module}.yml"

    if [[ ! -f "$module_compose" ]]; then
        print_error "Module compose file not found: $module_compose"
        return 1
    fi

    # Include dependency compose files in order
    local compose_args="-f $base_compose"
    local ordered_modules=("items" "bp" "prospects" "pricing-tax" "crm" "sbo-insights")

    for m in "${ordered_modules[@]}"; do
        local m_compose="${DEPLOY_ROOT}/docker/docker-compose.module-${m}.yml"
        if [[ -f "$m_compose" ]]; then
            local container="${project_name}-${m}"
            if [[ "$m" == "$module" ]] || docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                compose_args="$compose_args -f $m_compose"
            fi
        fi
        [[ "$m" == "$module" ]] && break
    done

    # Set image environment variable
    local image
    image=$(get_module_image "$module")
    local var_name
    var_name="$(echo "${module}_IMAGE" | tr '[:lower:]' '[:upper:]')"
    export "$var_name=$image"

    print_info "Starting module: $module"
    print_info "Image: $image:$version"

    local env_args="--env-file ${DEPLOY_ROOT}/portal.env"
    if [[ -f "${DEPLOY_ROOT}/portal.secrets.env" ]]; then
        env_args="$env_args --env-file ${DEPLOY_ROOT}/portal.secrets.env"
    fi
    local cmd="docker compose $compose_args $env_args up -d --no-recreate $module"
    debug "Running: $cmd"
    log_info "Running: $cmd"

    if eval "$cmd"; then
        print_success "Module '$module' started"
        return 0
    else
        print_error "Failed to start module '$module'"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Installation Summary
# -----------------------------------------------------------------------------

# Print module installation success summary
# Usage: print_install_success <module_name> <container_name> [extra_info]
print_install_success() {
    local module="$1"
    local container="$2"
    local extra_info="${3:-}"
    local app_url="${APPLICATION_URL:-https://localhost}"

    echo ""
    print_success "Module '$module' installed successfully!"
    echo ""
    echo "  Container:  $container"
    echo "  Logs:       docker logs $container"
    if [[ -n "$extra_info" ]]; then
        echo "$extra_info"
    fi
    echo ""

    log_info "Module installed: $module (container: $container)"
}
