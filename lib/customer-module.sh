#!/bin/bash
# =============================================================================
# EZY Portal - Customer Module Functions
# =============================================================================
# Shared functions for customer-specific micro-service modules
# =============================================================================

# Source common utilities if not already loaded
if [[ -z "${NC:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# Source api-keys.sh if not already loaded
if ! declare -f get_or_provision_api_key &>/dev/null; then
    source "$(dirname "${BASH_SOURCE[0]}")/api-keys.sh"
fi

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
CUSTOMER_MODULES_DIR="${DEPLOY_ROOT}/customer-modules"
CUSTOMER_NGINX_DIR="${DEPLOY_ROOT}/nginx/conf.d/customer"
CUSTOMER_REGISTRY_FILE="${CUSTOMER_MODULES_DIR}/installed.json"

# -----------------------------------------------------------------------------
# Prerequisite Checks
# -----------------------------------------------------------------------------

check_yq_installed() {
    if ! check_command_exists yq; then
        print_error "yq is not installed (required for YAML parsing)"
        print_info "Install yq:"
        print_info "  wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        print_info "  chmod +x /usr/local/bin/yq"
        return 1
    fi
    return 0
}

check_gh_installed() {
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

    return 0
}

# -----------------------------------------------------------------------------
# Manifest Parsing
# -----------------------------------------------------------------------------

# Parse a module manifest file and export values as variables
# Usage: parse_manifest /path/to/module-manifest.yaml
parse_manifest() {
    local manifest_file="$1"

    if [[ ! -f "$manifest_file" ]]; then
        print_error "Manifest file not found: $manifest_file"
        return 1
    fi

    # Validate manifest version
    local manifest_version
    manifest_version=$(yq '.version' "$manifest_file" 2>/dev/null)
    if [[ "$manifest_version" != "1.0" && "$manifest_version" != '"1.0"' ]]; then
        print_error "Unsupported manifest version: $manifest_version (expected 1.0)"
        return 1
    fi

    # Extract module info
    MODULE_NAME=$(yq '.module.name' "$manifest_file" | tr -d '"')
    MODULE_DISPLAY_NAME=$(yq '.module.displayName' "$manifest_file" | tr -d '"')
    MODULE_VENDOR=$(yq '.module.vendor // ""' "$manifest_file" | tr -d '"')
    MODULE_VERSION=$(yq '.module.moduleVersion' "$manifest_file" | tr -d '"')

    # Image info
    MODULE_IMAGE_REPO=$(yq '.module.image.repository' "$manifest_file" | tr -d '"')
    MODULE_IMAGE_TAG=$(yq '.module.image.tag' "$manifest_file" | tr -d '"')

    # Network info
    MODULE_PORT=$(yq '.module.port' "$manifest_file")
    MODULE_HEALTH_ENDPOINT=$(yq '.module.healthEndpoint // "/health"' "$manifest_file" | tr -d '"')

    # Database info
    MODULE_DB_SCHEMA=$(yq '.module.database.schema // ""' "$manifest_file" | tr -d '"')

    # Dependencies (as comma-separated strings)
    MODULE_DEPENDENCIES=$(yq '.module.dependencies.modules // [] | join(",")' "$manifest_file" | tr -d '"')
    MODULE_SERVICE_DEPENDENCIES=$(yq '.module.dependencies.services // [] | join(",")' "$manifest_file" | tr -d '"')

    # Environment
    MODULE_API_KEY_ENV_VAR=$(yq '.module.environment.apiKeyEnvVar // ""' "$manifest_file" | tr -d '"')

    # Routing
    MODULE_API_PREFIX=$(yq '.module.routing.apiPrefix' "$manifest_file" | tr -d '"')
    MODULE_MFE_PREFIX=$(yq '.module.routing.mfePrefix' "$manifest_file" | tr -d '"')

    # Custom nginx configs
    MODULE_HAS_CUSTOM_NGINX=$(yq '.nginx.customConfigs | length > 0' "$manifest_file")

    # Validate required fields
    if [[ -z "$MODULE_NAME" || "$MODULE_NAME" == "null" ]]; then
        print_error "Manifest missing required field: module.name"
        return 1
    fi

    if [[ -z "$MODULE_IMAGE_REPO" || "$MODULE_IMAGE_REPO" == "null" ]]; then
        print_error "Manifest missing required field: module.image.repository"
        return 1
    fi

    if [[ -z "$MODULE_PORT" || "$MODULE_PORT" == "null" ]]; then
        print_error "Manifest missing required field: module.port"
        return 1
    fi

    if [[ -z "$MODULE_API_PREFIX" || "$MODULE_API_PREFIX" == "null" ]]; then
        print_error "Manifest missing required field: module.routing.apiPrefix"
        return 1
    fi

    # Export for use by calling script
    export MODULE_NAME MODULE_DISPLAY_NAME MODULE_VENDOR MODULE_VERSION
    export MODULE_IMAGE_REPO MODULE_IMAGE_TAG MODULE_PORT MODULE_HEALTH_ENDPOINT
    export MODULE_DB_SCHEMA MODULE_DEPENDENCIES MODULE_SERVICE_DEPENDENCIES MODULE_API_KEY_ENV_VAR
    export MODULE_API_PREFIX MODULE_MFE_PREFIX MODULE_HAS_CUSTOM_NGINX

    return 0
}

# -----------------------------------------------------------------------------
# Dependency Checking
# -----------------------------------------------------------------------------

# Check if required module dependencies are running and healthy
check_customer_module_dependencies() {
    local deps="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"

    if [[ -z "$deps" ]]; then
        return 0
    fi

    print_info "Checking dependencies..."

    IFS=',' read -ra dep_array <<< "$deps"
    for dep in "${dep_array[@]}"; do
        dep=$(echo "$dep" | xargs)  # trim whitespace
        [[ -z "$dep" ]] && continue

        local container="${project_name}-${dep}"

        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            print_error "Required dependency '$dep' is not running"
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

# Check if required service dependencies are running and healthy
# Services are standalone containers like report-generator-api
check_service_dependencies() {
    local deps="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"

    if [[ -z "$deps" ]]; then
        return 0
    fi

    print_info "Checking service dependencies..."

    IFS=',' read -ra dep_array <<< "$deps"
    for dep in "${dep_array[@]}"; do
        dep=$(echo "$dep" | xargs)  # trim whitespace
        [[ -z "$dep" ]] && continue

        local container="${project_name}-${dep}"

        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            print_error "Required service '$dep' is not running"
            print_info "Install it first with: ./add-report-generator.sh api"
            return 1
        fi

        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")

        if [[ "$health" == "healthy" ]]; then
            print_success "Service '$dep' is running and healthy"
        else
            print_warning "Service '$dep' is running but not healthy (status: $health)"
        fi
    done

    return 0
}

# -----------------------------------------------------------------------------
# Nginx Configuration Generation
# -----------------------------------------------------------------------------

# Generate nginx configuration for a customer module
generate_customer_nginx_config() {
    local module_name="$1"
    local port="$2"
    local api_prefix="$3"
    local mfe_prefix="$4"
    local output_file="$5"

    # Convert module name to valid nginx variable name (replace - with _)
    local var_name="${module_name//-/_}_backend"

    cat > "$output_file" << EOF
# =============================================================================
# Customer Module: ${module_name}
# =============================================================================
# Auto-generated by add-customer-module.sh
# Do not edit manually - changes will be overwritten on module upgrade
# =============================================================================

# Health endpoint
location = ${api_prefix}/health {
    set \$${var_name} "http://${module_name}:${port}";
    rewrite ^${api_prefix}/health\$ /health break;
    proxy_pass \$${var_name};
    include snippets/proxy-headers-common.conf;
}

# Swagger documentation
location ${api_prefix}/swagger {
    set \$${var_name} "http://${module_name}:${port}";
    rewrite ^${api_prefix}/swagger(.*)\$ /swagger\$1 break;
    proxy_pass \$${var_name};
    include snippets/proxy-headers-common.conf;
}

# API routes
location ${api_prefix}/ {
    set \$${var_name} "http://${module_name}:${port}";
    rewrite ^${api_prefix}/(.*)\$ /api/\$1 break;
    proxy_pass \$${var_name};
    include snippets/proxy-headers-common.conf;

    # CORS headers
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Origin, Content-Type, Accept, Authorization" always;

    # Timeouts
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
}

# MFE remoteEntry.js (no cache for Module Federation)
location = ${mfe_prefix}/remoteEntry.js {
    set \$${var_name} "http://${module_name}:${port}";
    proxy_pass \$${var_name}${mfe_prefix}/remoteEntry.js;
    include snippets/proxy-headers-common.conf;

    # Disable caching
    expires -1;
    add_header Cache-Control "no-store, no-cache, must-revalidate";
    add_header Access-Control-Allow-Origin "*" always;
}

# MFE static assets
location ${mfe_prefix}/ {
    set \$${var_name} "http://${module_name}:${port}";
    proxy_pass \$${var_name};
    include snippets/proxy-headers-common.conf;

    # Cache static assets
    expires 1h;
    add_header Cache-Control "public";
    add_header Access-Control-Allow-Origin "*" always;
}
EOF

    return 0
}

# Copy custom nginx configs from package
copy_custom_nginx_configs() {
    local package_dir="$1"
    local manifest_file="$2"

    local config_count
    config_count=$(yq '.nginx.customConfigs | length' "$manifest_file")

    if [[ "$config_count" == "0" || "$config_count" == "null" ]]; then
        return 0
    fi

    print_info "Copying custom nginx configurations..."

    for ((i=0; i<config_count; i++)); do
        local source target
        source=$(yq ".nginx.customConfigs[$i].source" "$manifest_file" | tr -d '"')
        target=$(yq ".nginx.customConfigs[$i].target" "$manifest_file" | tr -d '"')

        local source_path="${package_dir}/${source}"
        local target_path="${DEPLOY_ROOT}/nginx/${target}"

        if [[ ! -f "$source_path" ]]; then
            print_warning "Custom nginx config not found: $source"
            continue
        fi

        # Create target directory if needed
        mkdir -p "$(dirname "$target_path")"

        cp "$source_path" "$target_path"
        print_success "Copied nginx config: $source -> $target"
    done

    return 0
}

# Reload nginx configuration
reload_nginx() {
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local nginx_container="${project_name}-nginx"

    # Check if nginx container exists and is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${nginx_container}$"; then
        # Try alternate naming (some setups use just "nginx")
        nginx_container="${project_name}"
        if ! docker ps --format '{{.Names}}' | grep -q "^${nginx_container}$"; then
            print_warning "Nginx container not found - skipping reload"
            print_info "Manually reload nginx after starting the portal"
            return 0
        fi
    fi

    # Test configuration first
    print_info "Testing nginx configuration..."
    if ! docker exec "$nginx_container" nginx -t 2>&1; then
        print_error "Nginx configuration test failed"
        return 1
    fi

    # Reload nginx
    print_info "Reloading nginx..."
    if docker exec "$nginx_container" nginx -s reload 2>&1; then
        print_success "Nginx reloaded successfully"
        return 0
    else
        print_error "Failed to reload nginx"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Module Registry
# -----------------------------------------------------------------------------

# Initialize the customer modules registry file
init_module_registry() {
    if [[ ! -f "$CUSTOMER_REGISTRY_FILE" ]]; then
        mkdir -p "$CUSTOMER_MODULES_DIR"
        echo '{"modules":{}}' > "$CUSTOMER_REGISTRY_FILE"
    fi
}

# Register a customer module in the registry
register_customer_module() {
    local module_name="$1"
    local version="$2"
    local repo="$3"

    init_module_registry

    local timestamp
    timestamp=$(date -Iseconds)

    # Use jq if available, otherwise use a simple approach
    if check_command_exists jq; then
        local temp_file
        temp_file=$(mktemp)
        jq --arg name "$module_name" \
           --arg version "$version" \
           --arg repo "$repo" \
           --arg timestamp "$timestamp" \
           '.modules[$name] = {"version": $version, "repo": $repo, "installedAt": $timestamp}' \
           "$CUSTOMER_REGISTRY_FILE" > "$temp_file" && mv "$temp_file" "$CUSTOMER_REGISTRY_FILE"
    else
        # Simple fallback - just log it
        print_warning "jq not installed - module registry may not be updated correctly"
    fi

    log_info "Registered customer module: $module_name v$version from $repo"
}

# Check if a customer module is already installed
is_customer_module_installed() {
    local module_name="$1"

    if [[ ! -f "$CUSTOMER_REGISTRY_FILE" ]]; then
        return 1
    fi

    if check_command_exists jq; then
        local installed
        installed=$(jq -r --arg name "$module_name" '.modules[$name] // empty' "$CUSTOMER_REGISTRY_FILE")
        [[ -n "$installed" ]]
    else
        grep -q "\"$module_name\"" "$CUSTOMER_REGISTRY_FILE"
    fi
}

# Get installed customer module version
get_customer_module_version() {
    local module_name="$1"

    if [[ ! -f "$CUSTOMER_REGISTRY_FILE" ]]; then
        echo ""
        return 1
    fi

    if check_command_exists jq; then
        jq -r --arg name "$module_name" '.modules[$name].version // ""' "$CUSTOMER_REGISTRY_FILE"
    else
        echo ""
    fi
}

# Unregister a customer module from the registry
unregister_customer_module() {
    local module_name="$1"

    if [[ ! -f "$CUSTOMER_REGISTRY_FILE" ]]; then
        return 0
    fi

    if check_command_exists jq; then
        local temp_file
        temp_file=$(mktemp)
        jq --arg name "$module_name" 'del(.modules[$name])' \
           "$CUSTOMER_REGISTRY_FILE" > "$temp_file" && mv "$temp_file" "$CUSTOMER_REGISTRY_FILE"
    fi

    log_info "Unregistered customer module: $module_name"
}

# List all installed customer modules
list_customer_modules() {
    if [[ ! -f "$CUSTOMER_REGISTRY_FILE" ]]; then
        echo "No customer modules installed"
        return 0
    fi

    if check_command_exists jq; then
        jq -r '.modules | to_entries[] | "\(.key)\t\(.value.version)\t\(.value.repo)"' "$CUSTOMER_REGISTRY_FILE"
    else
        cat "$CUSTOMER_REGISTRY_FILE"
    fi
}

# -----------------------------------------------------------------------------
# GitHub Release Download
# -----------------------------------------------------------------------------

# Download a release asset from GitHub (supports .tar.gz, .tgz, .zip)
# Usage: download_release_asset "org/repo" "version" "/path/to/output"
download_release_asset() {
    local repo="$1"
    local version="$2"
    local output_dir="$3"

    mkdir -p "$output_dir"

    # Extract repo name for asset pattern
    local repo_name="${repo##*/}"

    # Try gh CLI first (works for private repos)
    # Note: print_info/print_warning go to stderr to avoid polluting stdout (return value)
    if check_command_exists gh && gh auth status &>/dev/null; then
        print_info "Downloading release asset using gh CLI..." >&2

        # Try .tar.gz first, then .zip
        local patterns=("*.tar.gz" "*.tgz" "*.zip")
        for pattern in "${patterns[@]}"; do
            # Build args: gh release download [tag] --repo ... --pattern ... --dir ...
            local gh_args=("release" "download")
            if [[ "$version" != "latest" ]]; then
                gh_args+=("$version")
            fi
            gh_args+=("--repo" "$repo" "--pattern" "$pattern" "--dir" "$output_dir")

            if gh "${gh_args[@]}" 2>/dev/null; then
                # Find the downloaded file
                local downloaded_file
                downloaded_file=$(find "$output_dir" \( -name "*.tar.gz" -o -name "*.tgz" -o -name "*.zip" \) -type f | head -n1)
                if [[ -n "$downloaded_file" ]]; then
                    echo "$downloaded_file"
                    return 0
                fi
            fi
        done

        print_warning "gh CLI download failed, trying curl..." >&2
    fi

    # Fallback to curl (public repos only)
    print_info "Downloading release asset using curl..." >&2

    local api_url
    if [[ "$version" == "latest" ]]; then
        api_url="https://api.github.com/repos/${repo}/releases/latest"
    else
        api_url="https://api.github.com/repos/${repo}/releases/tags/${version}"
    fi

    # Get asset download URL (try .tar.gz first, then .zip)
    local asset_url
    asset_url=$(curl -s "$api_url" | grep -oE '"browser_download_url": *"[^"]*\.(tar\.gz|tgz|zip)"' | head -n1 | sed 's/"browser_download_url": *"//' | sed 's/"$//')

    if [[ -z "$asset_url" ]]; then
        print_error "Could not find release asset for $repo version $version" >&2
        print_info "Ensure the release has a .tar.gz, .tgz, or .zip asset attached" >&2
        return 1
    fi

    # Determine file extension from URL
    local extension
    if [[ "$asset_url" == *.zip ]]; then
        extension="zip"
    elif [[ "$asset_url" == *.tgz ]]; then
        extension="tgz"
    else
        extension="tar.gz"
    fi

    # Download the asset
    local output_file="${output_dir}/${repo_name}-${version}.${extension}"
    if curl -sL -o "$output_file" "$asset_url"; then
        echo "$output_file"
        return 0
    else
        print_error "Failed to download release asset" >&2
        return 1
    fi
}

# Extract a package (supports .tar.gz, .tgz, and .zip)
extract_package() {
    local package_file="$1"
    local output_dir="$2"

    mkdir -p "$output_dir"

    # Determine file type and extract accordingly
    case "$package_file" in
        *.tar.gz|*.tgz)
            if ! tar -xzf "$package_file" -C "$output_dir"; then
                print_error "Failed to extract tarball: $package_file"
                return 1
            fi
            ;;
        *.zip)
            if ! check_command_exists unzip; then
                print_error "unzip is not installed (required for .zip files)"
                print_info "Install with: sudo apt install unzip  # or: sudo dnf install unzip"
                return 1
            fi
            if ! unzip -q "$package_file" -d "$output_dir"; then
                print_error "Failed to extract zip: $package_file"
                return 1
            fi
            ;;
        *)
            print_error "Unsupported package format: $package_file"
            print_info "Supported formats: .tar.gz, .tgz, .zip"
            return 1
            ;;
    esac

    # Handle packages with a single root directory (common pattern)
    # If extracted content has single directory, move its contents up
    local items=("$output_dir"/*)
    if [[ ${#items[@]} -eq 1 && -d "${items[0]}" ]]; then
        local root_dir="${items[0]}"
        # Move contents up and remove the empty root directory
        mv "$root_dir"/* "$output_dir/" 2>/dev/null || true
        mv "$root_dir"/.* "$output_dir/" 2>/dev/null || true
        rmdir "$root_dir" 2>/dev/null || true
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Docker Compose Operations
# -----------------------------------------------------------------------------

# Generate compose file path for customer module
get_customer_compose_file() {
    local module_name="$1"
    echo "${DEPLOY_ROOT}/docker/docker-compose.module-customer-${module_name}.yml"
}

# Copy and process docker-compose file from package
# Substitutes actual image:tag and fixes container name
install_customer_compose_file() {
    local package_dir="$1"
    local module_name="$2"

    local source_file="${package_dir}/docker-compose.module.yml"
    local target_file
    target_file=$(get_customer_compose_file "$module_name")

    if [[ ! -f "$source_file" ]]; then
        print_error "docker-compose.module.yml not found in package"
        return 1
    fi

    # Copy the file first
    cp "$source_file" "$target_file"

    # Substitute the image line with actual image:tag from manifest
    # This prevents docker showing SHA hashes instead of proper tags
    if [[ -n "$MODULE_IMAGE_REPO" && -n "$MODULE_IMAGE_TAG" ]]; then
        # Replace image line (handles various formats)
        sed -i "s|image:.*${module_name}.*|image: ${MODULE_IMAGE_REPO}:${MODULE_IMAGE_TAG}|" "$target_file"
        print_info "Image set to: ${MODULE_IMAGE_REPO}:${MODULE_IMAGE_TAG}"
    fi

    # Simplify container name to just the module name (no PROJECT_NAME prefix)
    # This makes container names cleaner and consistent
    sed -i "s|container_name:.*${module_name}.*|container_name: ${module_name}|" "$target_file"
    print_info "Container name set to: ${module_name}"

    print_success "Installed compose file: $target_file"

    return 0
}

# Start a customer module using docker compose
start_customer_module() {
    local module_name="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"

    # Load config to get infrastructure mode
    source "${DEPLOY_ROOT}/lib/config.sh"
    load_config "${DEPLOY_ROOT}/portal.env"

    local infra_mode="${INFRASTRUCTURE_MODE:-full}"

    # Build compose file arguments
    local base_compose
    base_compose=$(get_compose_file "$infra_mode")

    local customer_compose
    customer_compose=$(get_customer_compose_file "$module_name")

    if [[ ! -f "$customer_compose" ]]; then
        print_error "Customer compose file not found: $customer_compose"
        return 1
    fi

    # Build compose args - include base + all standard modules + this customer module
    local compose_args="-f $base_compose"

    # Add standard module compose files if they exist and are running
    local standard_modules=("items" "bp" "prospects")
    for m in "${standard_modules[@]}"; do
        local m_compose="${DEPLOY_ROOT}/docker/docker-compose.module-${m}.yml"
        local container="${project_name}-${m}"
        if [[ -f "$m_compose" ]] && docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            compose_args="$compose_args -f $m_compose"
        fi
    done

    # Add customer module compose file
    compose_args="$compose_args -f $customer_compose"

    print_info "Starting customer module: $module_name"

    # Use --no-recreate to avoid touching existing containers
    local cmd="docker compose $compose_args --env-file ${DEPLOY_ROOT}/portal.env up -d --no-recreate $module_name"
    log_info "Running: $cmd"

    if eval "$cmd"; then
        print_success "Customer module '$module_name' started"
        return 0
    else
        print_error "Failed to start customer module '$module_name'"
        return 1
    fi
}

# Stop a customer module
stop_customer_module() {
    local module_name="$1"
    # Customer modules use simple container names (no PROJECT_NAME prefix)
    local container="$module_name"

    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        print_info "Stopping customer module: $module_name"
        docker stop "$container" 2>/dev/null || true
        docker rm "$container" 2>/dev/null || true
        print_success "Customer module '$module_name' stopped"
    else
        print_info "Customer module '$module_name' is not running"
    fi

    return 0
}

# Wait for customer module to become healthy
wait_for_customer_module_healthy() {
    local module_name="$1"
    # Customer modules use simple container names (no PROJECT_NAME prefix)
    local container="$module_name"
    local timeout="${2:-120}"

    print_info "Waiting for $module_name to be healthy (timeout: ${timeout}s)..."

    # Import wait_for_healthy from docker.sh if not available
    if ! declare -f wait_for_healthy &>/dev/null; then
        source "${DEPLOY_ROOT}/lib/docker.sh"
    fi

    if wait_for_healthy "$container" "$timeout"; then
        print_success "Customer module '$module_name' is healthy"
        return 0
    else
        print_warning "Customer module did not become healthy within ${timeout}s"
        print_info "Check logs: docker logs $container"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# API Key Management (uses lib/api-keys.sh)
# -----------------------------------------------------------------------------

# Save API key for customer module
# Uses the consolidated api-keys.sh library
save_customer_module_api_key() {
    local module_name="$1"
    local api_key="$2"
    local env_var_name="$3"

    # Default env var name if not specified
    if [[ -z "$env_var_name" ]]; then
        # Convert module-name to MODULE_NAME_API_KEY
        env_var_name=$(echo "${module_name}_API_KEY" | tr '[:lower:]-' '[:upper:]_')
    fi

    # Use the consolidated function from lib/api-keys.sh
    get_or_provision_api_key "$module_name" "$env_var_name" "$api_key"
}
