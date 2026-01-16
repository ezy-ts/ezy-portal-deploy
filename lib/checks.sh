#!/bin/bash
# =============================================================================
# EZY Portal - Prerequisite Checks
# =============================================================================
# Validates system requirements before installation/upgrade
# =============================================================================

# Source common utilities if not already loaded
if [[ -z "${NC:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# -----------------------------------------------------------------------------
# Docker Checks
# -----------------------------------------------------------------------------

check_docker_installed() {
    if ! check_command_exists docker; then
        print_error "Docker is not installed"
        print_info "Install Docker: https://docs.docker.com/engine/install/"
        return 1
    fi
    print_success "Docker is installed"
    return 0
}

check_docker_running() {
    if ! docker info &>/dev/null; then
        print_error "Docker daemon is not running"
        print_info "Start Docker with: sudo systemctl start docker"
        return 1
    fi
    print_success "Docker daemon is running"
    return 0
}

check_docker_compose_v2() {
    # Check for Docker Compose v2 (docker compose, not docker-compose)
    if ! docker compose version &>/dev/null; then
        print_error "Docker Compose v2 is not available"
        print_info "Docker Compose v2 comes with Docker Desktop or can be installed as a plugin"
        print_info "See: https://docs.docker.com/compose/install/"
        return 1
    fi

    local compose_version
    compose_version=$(docker compose version --short 2>/dev/null)
    print_success "Docker Compose v2 is available (version: $compose_version)"
    return 0
}

check_docker_permissions() {
    if ! docker ps &>/dev/null; then
        if is_root; then
            print_error "Cannot connect to Docker even as root"
            return 1
        fi
        print_warning "Current user cannot access Docker"
        print_info "Add user to docker group: sudo usermod -aG docker \$USER"
        print_info "Then log out and back in, or run: newgrp docker"
        return 1
    fi
    print_success "User has Docker permissions"
    return 0
}

# -----------------------------------------------------------------------------
# Customer Module Prerequisites
# -----------------------------------------------------------------------------

check_yq_installed() {
    if ! check_command_exists yq; then
        print_error "yq is not installed (required for YAML parsing)"
        print_info "Install yq:"
        print_info "  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        print_info "  sudo chmod +x /usr/local/bin/yq"
        return 1
    fi
    print_success "yq is installed"
    return 0
}

check_gh_cli_installed() {
    if ! check_command_exists gh; then
        print_warning "gh CLI is not installed (required for private repos)"
        print_info "Install gh CLI: https://cli.github.com/manual/installation"
        return 1
    fi

    # Check if authenticated
    if ! gh auth status &>/dev/null; then
        print_warning "gh CLI is not authenticated"
        print_info "Run: gh auth login"
        return 1
    fi

    print_success "gh CLI is installed and authenticated"
    return 0
}

check_jq_installed() {
    if ! check_command_exists jq; then
        print_warning "jq is not installed (recommended for module registry)"
        print_info "Install jq: sudo apt install jq"
        return 1
    fi
    print_success "jq is installed"
    return 0
}

# -----------------------------------------------------------------------------
# GitHub Container Registry Checks
# -----------------------------------------------------------------------------

check_github_pat() {
    # Skip GITHUB_PAT check if using local images
    if [[ "${USE_LOCAL_IMAGES:-false}" == "true" ]]; then
        print_info "Using local images - GITHUB_PAT not required"
        return 0
    fi

    if [[ -z "${GITHUB_PAT:-}" ]]; then
        print_error "GITHUB_PAT environment variable is not set"
        echo ""
        print_info "To pull images from GitHub Container Registry, you need a Personal Access Token"
        print_info "1. Go to: https://github.com/settings/tokens"
        print_info "2. Generate a new token with 'read:packages' scope"
        print_info "3. Set the environment variable:"
        echo ""
        echo "   export GITHUB_PAT=ghp_your_token_here"
        echo ""
        return 1
    fi
    print_success "GITHUB_PAT is set"
    return 0
}

check_ghcr_login() {
    local username="${GITHUB_USERNAME:-ezy-ts}"

    print_info "Attempting to login to GitHub Container Registry..."

    if echo "$GITHUB_PAT" | docker login ghcr.io -u "$username" --password-stdin &>/dev/null; then
        print_success "Successfully authenticated with GitHub Container Registry"
        return 0
    else
        print_error "Failed to authenticate with GitHub Container Registry"
        print_info "Check that your GITHUB_PAT has 'read:packages' scope"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Port Checks
# -----------------------------------------------------------------------------

check_port_available() {
    local port="$1"
    local service="${2:-unknown}"

    if command -v ss &>/dev/null; then
        if ss -tuln | grep -q ":${port} "; then
            print_error "Port $port is in use (needed for $service)"
            return 1
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tuln | grep -q ":${port} "; then
            print_error "Port $port is in use (needed for $service)"
            return 1
        fi
    else
        # Fallback: try to bind to the port
        if ! (echo >/dev/tcp/localhost/"$port") 2>/dev/null; then
            print_success "Port $port is available ($service)"
            return 0
        fi
        print_error "Port $port is in use (needed for $service)"
        return 1
    fi

    print_success "Port $port is available ($service)"
    return 0
}

check_required_ports() {
    local http_port="${HTTP_PORT:-80}"
    local https_port="${HTTPS_PORT:-443}"
    local failed=0

    print_subsection "Checking port availability"

    check_port_available "$https_port" "HTTPS/nginx" || ((failed++))
    check_port_available "$http_port" "HTTP redirect" || ((failed++))

    return "$failed"
}

# -----------------------------------------------------------------------------
# System Resource Checks
# -----------------------------------------------------------------------------

check_disk_space() {
    local required_gb="${1:-5}"
    local path="${2:-/}"

    local available_kb
    available_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
    local available_gb=$((available_kb / 1024 / 1024))

    if [[ $available_gb -lt $required_gb ]]; then
        print_warning "Low disk space: ${available_gb}GB available, ${required_gb}GB recommended"
        return 1
    fi

    print_success "Disk space: ${available_gb}GB available"
    return 0
}

check_memory() {
    local required_mb="${1:-2048}"

    local available_mb
    if [[ -f /proc/meminfo ]]; then
        available_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    else
        # macOS fallback
        available_mb=$(vm_stat | awk '/Pages free/ {print int($3*4096/1024/1024)}')
    fi

    if [[ $available_mb -lt $required_mb ]]; then
        print_warning "Low memory: ${available_mb}MB available, ${required_mb}MB recommended"
        return 1
    fi

    print_success "Memory: ${available_mb}MB available"
    return 0
}

# -----------------------------------------------------------------------------
# Installation State Checks
# -----------------------------------------------------------------------------

check_existing_installation() {
    local deploy_root="${DEPLOY_ROOT:-$(get_deploy_root)}"

    # Check for existing configuration
    if [[ -f "$deploy_root/portal.env" ]]; then
        return 0
    fi

    return 1
}

check_portal_running() {
    local container_name="${PROJECT_NAME:-ezy-portal}"

    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        return 0
    fi

    return 1
}

get_current_portal_version() {
    local container_name="${PROJECT_NAME:-ezy-portal}"

    if check_portal_running; then
        # Get version from running container's image
        local image
        image=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null)
        if [[ "$image" =~ :([^:]+)$ ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    fi

    # Try to get from config
    if [[ -f "${DEPLOY_ROOT:-}/portal.env" ]]; then
        local version
        version=$(grep "^VERSION=" "${DEPLOY_ROOT:-}/portal.env" 2>/dev/null | cut -d= -f2)
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi

    echo "unknown"
    return 1
}

get_portal_status() {
    local container_name="${PROJECT_NAME:-ezy-portal}"

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "not_installed"
        return
    fi

    local status
    status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)

    case "$status" in
        running)
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null)
            if [[ "$health" == "healthy" ]]; then
                echo "healthy"
            elif [[ "$health" == "unhealthy" ]]; then
                echo "unhealthy"
            else
                echo "running"
            fi
            ;;
        exited|stopped)
            echo "stopped"
            ;;
        *)
            echo "$status"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Network Checks
# -----------------------------------------------------------------------------

check_external_postgres() {
    local host="$1"
    local port="${2:-5432}"

    if check_command_exists pg_isready; then
        if pg_isready -h "$host" -p "$port" &>/dev/null; then
            print_success "PostgreSQL is reachable at $host:$port"
            return 0
        fi
    else
        # Fallback: simple TCP check
        if timeout 5 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
            print_success "PostgreSQL port is open at $host:$port"
            return 0
        fi
    fi

    print_error "Cannot connect to PostgreSQL at $host:$port"
    return 1
}

check_external_redis() {
    local host="$1"
    local port="${2:-6379}"

    if timeout 5 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        print_success "Redis is reachable at $host:$port"
        return 0
    fi

    print_error "Cannot connect to Redis at $host:$port"
    return 1
}

check_external_rabbitmq() {
    local host="$1"
    local port="${2:-5672}"

    if timeout 5 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        print_success "RabbitMQ is reachable at $host:$port"
        return 0
    fi

    print_error "Cannot connect to RabbitMQ at $host:$port"
    return 1
}

# -----------------------------------------------------------------------------
# Directory Permission Checks
# -----------------------------------------------------------------------------

# Check if uploads directory has correct permissions for Docker containers
# The portal backend needs to create subdirectories like data-protection-keys
check_uploads_permissions() {
    local deploy_root="${DEPLOY_ROOT:-$(get_deploy_root)}"
    local uploads_dir="$deploy_root/uploads"

    # Create uploads directory if it doesn't exist
    if [[ ! -d "$uploads_dir" ]]; then
        mkdir -p "$uploads_dir" 2>/dev/null || true
    fi

    # Check if we can write to uploads directory
    if [[ ! -w "$uploads_dir" ]]; then
        return 1
    fi

    # Check if we can create subdirectories (simulating what Docker container does)
    local test_dir="$uploads_dir/.permission-test-$$"
    if mkdir -p "$test_dir" 2>/dev/null; then
        rmdir "$test_dir" 2>/dev/null
        return 0
    fi

    return 1
}

# Interactively fix uploads directory permissions
# Loops until permissions are correct or user cancels
fix_uploads_permissions_interactive() {
    local deploy_root="${DEPLOY_ROOT:-$(get_deploy_root)}"
    local uploads_dir="$deploy_root/uploads"

    # First check if permissions are already correct
    if check_uploads_permissions; then
        print_success "Uploads directory permissions are correct"
        return 0
    fi

    print_warning "Uploads directory needs write permissions for Docker containers"
    print_info "The portal backend creates subdirectories in: $uploads_dir"
    echo ""

    # Create the directory structure first
    mkdir -p "$uploads_dir/data-protection-keys" 2>/dev/null || true

    local sudo_cmd="sudo chmod -R 777 $uploads_dir && sudo chown -R \$(id -u):\$(id -g) $uploads_dir"

    while true; do
        print_info "Please run the following command in another terminal:"
        echo ""
        echo "  $sudo_cmd"
        echo ""

        if [[ "${INTERACTIVE:-true}" != "true" ]]; then
            print_error "Cannot fix permissions in non-interactive mode"
            print_info "Run manually: $sudo_cmd"
            return 1
        fi

        echo -n "Press Enter after running the command (or 'q' to quit): "
        read -r response

        if [[ "$response" == "q" ]] || [[ "$response" == "Q" ]]; then
            print_error "Permission fix cancelled"
            return 1
        fi

        # Re-check permissions
        if check_uploads_permissions; then
            print_success "Uploads directory permissions are now correct"
            return 0
        fi

        print_error "Permissions still incorrect. Please try again."
        echo ""
    done
}

# -----------------------------------------------------------------------------
# Main Prerequisite Check
# -----------------------------------------------------------------------------

run_all_prerequisite_checks() {
    local failed=0

    print_section "Checking Prerequisites"

    print_subsection "Docker"
    check_docker_installed || ((failed++))
    check_docker_running || ((failed++))
    check_docker_compose_v2 || ((failed++))
    check_docker_permissions || ((failed++))

    if [[ "${USE_LOCAL_IMAGES:-false}" == "true" ]]; then
        print_subsection "Image Source: Local"
    else
        print_subsection "Image Source: GitHub Container Registry"
        check_github_pat || ((failed++))
    fi

    print_subsection "System Resources"
    check_disk_space 5 || :  # Warning only
    check_memory 2048 || :   # Warning only

    if [[ $failed -gt 0 ]]; then
        echo ""
        print_error "Prerequisites check failed ($failed critical issues)"
        return 1
    fi

    echo ""
    print_success "All prerequisites met"
    return 0
}
