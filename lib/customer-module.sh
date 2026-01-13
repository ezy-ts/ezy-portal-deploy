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
# Supports both unified (v1.0) and separated (v1.1) architecture manifests
# Usage: parse_manifest /path/to/module-manifest.yaml
parse_manifest() {
    local manifest_file="$1"

    if [[ ! -f "$manifest_file" ]]; then
        print_error "Manifest file not found: $manifest_file"
        return 1
    fi

    # Check manifest version
    local manifest_version
    manifest_version=$(yq '.version' "$manifest_file" 2>/dev/null | tr -d '"')

    # Validate manifest version
    if [[ "$manifest_version" != "1.0" && "$manifest_version" != "1.1" ]]; then
        print_error "Unsupported manifest version: $manifest_version (expected 1.0 or 1.1)"
        return 1
    fi

    # Extract module info (common to both versions)
    MODULE_NAME=$(yq '.module.name' "$manifest_file" | tr -d '"')
    MODULE_DISPLAY_NAME=$(yq '.module.displayName' "$manifest_file" | tr -d '"')
    MODULE_VENDOR=$(yq '.module.vendor // ""' "$manifest_file" | tr -d '"')
    MODULE_VERSION=$(yq '.module.moduleVersion' "$manifest_file" | tr -d '"')

    # Check architecture type (separated or unified)
    MODULE_ARCHITECTURE=$(yq '.module.architecture // "unified"' "$manifest_file" | tr -d '"')

    if [[ "$MODULE_ARCHITECTURE" == "separated" ]]; then
        # Separated architecture (v1.1): backend in container, frontend as static files
        MODULE_IMAGE_REPO=$(yq '.module.backend.image.repository' "$manifest_file" | tr -d '"')
        MODULE_IMAGE_TAG=$(yq '.module.backend.image.tag' "$manifest_file" | tr -d '"')
        MODULE_PORT=$(yq '.module.backend.port' "$manifest_file")
        MODULE_HEALTH_ENDPOINT=$(yq '.module.backend.healthEndpoint // "/health"' "$manifest_file" | tr -d '"')

        # Frontend info
        MODULE_HAS_FRONTEND="true"
        MODULE_FRONTEND_ARTIFACT=$(yq '.module.frontend.artifactPattern // ""' "$manifest_file" | tr -d '"')
        MODULE_FRONTEND_REPO=$(yq '.module.frontend.repository // ""' "$manifest_file" | tr -d '"')
        MODULE_FRONTEND_MFF_DIR=$(yq '.module.frontend.mffDir // ""' "$manifest_file" | tr -d '"')

        # Default frontend values if not specified
        if [[ -z "$MODULE_FRONTEND_MFF_DIR" || "$MODULE_FRONTEND_MFF_DIR" == "null" ]]; then
            MODULE_FRONTEND_MFF_DIR="$MODULE_NAME"
        fi
    else
        # Unified architecture (v1.0): single container serves both API and MFE
        MODULE_IMAGE_REPO=$(yq '.module.image.repository' "$manifest_file" | tr -d '"')
        MODULE_IMAGE_TAG=$(yq '.module.image.tag' "$manifest_file" | tr -d '"')
        MODULE_PORT=$(yq '.module.port' "$manifest_file")
        MODULE_HEALTH_ENDPOINT=$(yq '.module.healthEndpoint // "/health"' "$manifest_file" | tr -d '"')

        # No separate frontend for unified
        MODULE_HAS_FRONTEND="false"
        MODULE_FRONTEND_ARTIFACT=""
        MODULE_FRONTEND_REPO=""
        MODULE_FRONTEND_MFF_DIR=""
    fi

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

    # Custom nginx configs (only for unified architecture or explicit overrides)
    MODULE_HAS_CUSTOM_NGINX=$(yq '.nginx.customConfigs | length > 0' "$manifest_file")

    # Validate required fields
    if [[ -z "$MODULE_NAME" || "$MODULE_NAME" == "null" ]]; then
        print_error "Manifest missing required field: module.name"
        return 1
    fi

    if [[ -z "$MODULE_IMAGE_REPO" || "$MODULE_IMAGE_REPO" == "null" ]]; then
        print_error "Manifest missing required field: module.backend.image.repository (or module.image.repository for v1.0)"
        return 1
    fi

    if [[ -z "$MODULE_PORT" || "$MODULE_PORT" == "null" ]]; then
        print_error "Manifest missing required field: module.backend.port (or module.port for v1.0)"
        return 1
    fi

    if [[ -z "$MODULE_API_PREFIX" || "$MODULE_API_PREFIX" == "null" ]]; then
        print_error "Manifest missing required field: module.routing.apiPrefix"
        return 1
    fi

    # Check for required environment variables in manifest
    MODULE_HAS_REQUIRED_ENV=$(yq '.module.environment.required | length > 0' "$manifest_file")

    # Export for use by calling script
    export MODULE_NAME MODULE_DISPLAY_NAME MODULE_VENDOR MODULE_VERSION MODULE_ARCHITECTURE
    export MODULE_IMAGE_REPO MODULE_IMAGE_TAG MODULE_PORT MODULE_HEALTH_ENDPOINT
    export MODULE_DB_SCHEMA MODULE_DEPENDENCIES MODULE_SERVICE_DEPENDENCIES MODULE_API_KEY_ENV_VAR
    export MODULE_API_PREFIX MODULE_MFE_PREFIX MODULE_HAS_CUSTOM_NGINX
    export MODULE_HAS_FRONTEND MODULE_FRONTEND_ARTIFACT MODULE_FRONTEND_REPO MODULE_FRONTEND_MFF_DIR
    export MODULE_HAS_REQUIRED_ENV

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
# Supports both unified (proxy MFE to container) and separated (static files) architectures
# Usage: generate_customer_nginx_config <module_name> <port> <api_prefix> <mfe_prefix> <output_file> [architecture] [mff_dir]
generate_customer_nginx_config() {
    local module_name="$1"
    local port="$2"
    local api_prefix="$3"
    local mfe_prefix="$4"
    local output_file="$5"
    local architecture="${6:-unified}"
    local mff_dir="${7:-$module_name}"

    # Convert module name to valid nginx variable name (replace - with _)
    local var_name="${module_name//-/_}_backend"

    if [[ "$architecture" == "separated" ]]; then
        # Separated architecture: API proxied, MFE served from static files
        cat > "$output_file" << EOF
# =============================================================================
# Customer Module: ${module_name} (Separated Architecture)
# =============================================================================
# Auto-generated by add-customer-module.sh
# Do not edit manually - changes will be overwritten on module upgrade
#
# Architecture: separated
# - Backend API: Proxied to container http://${module_name}:${port}
# - Frontend MFE: Served from static files /usr/share/nginx/html/mff/${mff_dir}/
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

# MFE remoteEntry.js (no cache for Module Federation - served from static files)
location = ${mfe_prefix}/remoteEntry.js {
    alias /usr/share/nginx/html/mff/${mff_dir}/remoteEntry.js;
    expires -1;
    add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
}

# MFE static assets (served from static files)
location ~ ^${mfe_prefix}/(.*)\$ {
    alias /usr/share/nginx/html/mff/${mff_dir}/\$1;
    expires 1y;
    add_header Cache-Control "public, immutable" always;
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
}
EOF
    else
        # Unified architecture: both API and MFE proxied to container
        cat > "$output_file" << EOF
# =============================================================================
# Customer Module: ${module_name} (Unified Architecture)
# =============================================================================
# Auto-generated by add-customer-module.sh
# Do not edit manually - changes will be overwritten on module upgrade
#
# Architecture: unified
# - Both API and MFE proxied to container http://${module_name}:${port}
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
    fi

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

    # Fallback to curl with GitHub API
    print_info "Downloading release asset using GitHub API..." >&2

    if [[ -z "${GITHUB_PAT:-}" ]]; then
        print_error "GITHUB_PAT is required to download from private repositories" >&2
        return 1
    fi

    local api_url
    if [[ "$version" == "latest" ]]; then
        api_url="https://api.github.com/repos/${repo}/releases/latest"
    else
        api_url="https://api.github.com/repos/${repo}/releases/tags/${version}"
    fi

    # Get release info including assets
    local release_info
    release_info=$(curl -sH "Authorization: token $GITHUB_PAT" "$api_url")

    # Find asset ID for .tar.gz, .tgz, or .zip (try in that order)
    local asset_id=""
    local asset_name=""
    for ext_pattern in '\.tar\.gz"' '\.tgz"' '\.zip"'; do
        asset_name=$(echo "$release_info" | grep -oE '"name": *"[^"]*'"${ext_pattern}" | head -n1 | sed 's/"name": *"//' | sed 's/"$//')
        if [[ -n "$asset_name" ]]; then
            asset_id=$(echo "$release_info" | grep -B5 "\"name\": *\"${asset_name}\"" | \
                grep '"id":' | head -1 | sed -E 's/.*"id": *([0-9]+).*/\1/')
            break
        fi
    done

    if [[ -z "$asset_id" ]]; then
        print_error "Could not find release asset for $repo version $version" >&2
        print_info "Ensure the release has a .tar.gz, .tgz, or .zip asset attached" >&2
        return 1
    fi

    # Determine file extension from asset name
    local extension
    if [[ "$asset_name" == *.zip ]]; then
        extension="zip"
    elif [[ "$asset_name" == *.tgz ]]; then
        extension="tgz"
    else
        extension="tar.gz"
    fi

    # Download using the asset API with octet-stream Accept header
    local asset_api_url="https://api.github.com/repos/${repo}/releases/assets/${asset_id}"
    local output_file="${output_dir}/${repo_name}-${version}.${extension}"
    if curl -sL \
        -H "Authorization: token $GITHUB_PAT" \
        -H "Accept: application/octet-stream" \
        -o "$output_file" \
        "$asset_api_url"; then
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

# -----------------------------------------------------------------------------
# Required Environment Variables Management
# -----------------------------------------------------------------------------

# Process required environment variables from manifest
# Adds placeholders to portal.env for any missing variables
# Usage: process_required_env_vars <manifest_file> [config_file]
# Returns: Number of variables that need to be configured (have CHANGE_ME placeholders)
process_required_env_vars() {
    local manifest_file="$1"
    local config_file="${2:-${DEPLOY_ROOT}/portal.env}"
    local needs_config=0
    local added_vars=()

    # Check if manifest has required env vars
    local has_required
    has_required=$(yq '.module.environment.required | length > 0' "$manifest_file")

    if [[ "$has_required" != "true" ]]; then
        return 0
    fi

    local module_name
    module_name=$(yq '.module.name' "$manifest_file" | tr -d '"')

    print_info "Processing required environment variables..."

    # Get the count of required variables
    local var_count
    var_count=$(yq '.module.environment.required | length' "$manifest_file")

    for ((i=0; i<var_count; i++)); do
        local var_name
        local var_desc
        local var_placeholder
        local var_sensitive

        var_name=$(yq ".module.environment.required[$i].name" "$manifest_file" | tr -d '"')
        var_desc=$(yq ".module.environment.required[$i].description // \"\"" "$manifest_file" | tr -d '"')
        var_placeholder=$(yq ".module.environment.required[$i].placeholder // \"CHANGE_ME\"" "$manifest_file" | tr -d '"')
        var_sensitive=$(yq ".module.environment.required[$i].sensitive // false" "$manifest_file")

        # Check if variable already exists in config
        if grep -q "^${var_name}=" "$config_file" 2>/dev/null; then
            local existing_value
            existing_value=$(grep "^${var_name}=" "$config_file" | cut -d= -f2-)

            # Check if it still has a placeholder value
            if [[ "$existing_value" == "CHANGE_ME" ]] || [[ "$existing_value" == *"CHANGE_ME"* ]]; then
                ((needs_config++))
                debug "Variable $var_name exists but needs configuration"
            else
                debug "Variable $var_name already configured"
            fi
        else
            # Add variable with placeholder
            echo "" >> "$config_file"
            echo "# $var_desc" >> "$config_file"
            echo "${var_name}=${var_placeholder}" >> "$config_file"
            added_vars+=("$var_name")

            if [[ "$var_placeholder" == "CHANGE_ME" ]] || [[ "$var_placeholder" == *"CHANGE_ME"* ]]; then
                ((needs_config++))
            fi
        fi
    done

    if [[ ${#added_vars[@]} -gt 0 ]]; then
        print_success "Added ${#added_vars[@]} environment variables to $(basename "$config_file")"
    fi

    return $needs_config
}

# Display required environment variables that need configuration
# Usage: show_required_env_vars <manifest_file> [config_file]
show_required_env_vars() {
    local manifest_file="$1"
    local config_file="${2:-${DEPLOY_ROOT}/portal.env}"

    # Check if manifest has required env vars
    local has_required
    has_required=$(yq '.module.environment.required | length > 0' "$manifest_file")

    if [[ "$has_required" != "true" ]]; then
        return 0
    fi

    local var_count
    var_count=$(yq '.module.environment.required | length' "$manifest_file")
    local unconfigured=()

    for ((i=0; i<var_count; i++)); do
        local var_name
        local var_desc
        local var_sensitive

        var_name=$(yq ".module.environment.required[$i].name" "$manifest_file" | tr -d '"')
        var_desc=$(yq ".module.environment.required[$i].description // \"\"" "$manifest_file" | tr -d '"')
        var_sensitive=$(yq ".module.environment.required[$i].sensitive // false" "$manifest_file")

        # Check if variable needs configuration
        if grep -q "^${var_name}=" "$config_file" 2>/dev/null; then
            local existing_value
            existing_value=$(grep "^${var_name}=" "$config_file" | cut -d= -f2-)

            if [[ "$existing_value" == "CHANGE_ME" ]] || [[ "$existing_value" == *"CHANGE_ME"* ]]; then
                if [[ "$var_sensitive" == "true" ]]; then
                    unconfigured+=("  - ${var_name} (sensitive): $var_desc")
                else
                    unconfigured+=("  - ${var_name}: $var_desc")
                fi
            fi
        fi
    done

    if [[ ${#unconfigured[@]} -gt 0 ]]; then
        echo ""
        print_warning "The following environment variables need to be configured in portal.env:"
        for var in "${unconfigured[@]}"; do
            echo "$var"
        done
        echo ""
        print_info "After configuring, restart the module with:"
        echo "  docker restart \$(docker ps -q -f name=<module-name>)"
    fi
}

# -----------------------------------------------------------------------------
# Customer Module Frontend Management (Separated Architecture)
# -----------------------------------------------------------------------------

CUSTOMER_MFF_DIR="${DEPLOY_ROOT}/dist/mff"

# Download and install frontend artifact for a customer module with separated architecture
# Usage: download_customer_frontend <module_name> <version> <artifact_pattern> <repo> <mff_dir>
download_customer_frontend() {
    local module_name="$1"
    local version="$2"
    local artifact_pattern="$3"
    local repo="$4"
    local mff_dir="${5:-$module_name}"

    local deploy_root="${DEPLOY_ROOT:-$(get_deploy_root)}"
    local module_dir="${CUSTOMER_MFF_DIR}/${mff_dir}"
    local temp_dir

    temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" RETURN

    # Remove 'v' prefix from version if present
    version="${version#v}"

    # Build artifact name from pattern (replace {version} placeholder)
    local artifact_name="${artifact_pattern//\{version\}/$version}"

    print_info "Downloading ${module_name} frontend version: $version"
    print_info "Artifact: $artifact_name"

    local zip_file="${temp_dir}/${artifact_name}"

    # Try gh CLI first (works for private repos)
    if check_command_exists gh && gh auth status &>/dev/null; then
        print_info "Downloading release asset using gh CLI..."

        # Try with 'v' prefix first, then without
        if ! gh release download "v${version}" --repo "$repo" --pattern "$artifact_name" --dir "$temp_dir" 2>/dev/null; then
            gh release download "${version}" --repo "$repo" --pattern "$artifact_name" --dir "$temp_dir" 2>/dev/null || true
        fi
    fi

    # Fallback to GitHub API if gh CLI didn't work
    if [[ ! -f "$zip_file" ]] || [[ ! -s "$zip_file" ]]; then
        print_info "Downloading release asset using GitHub API..."

        local api_url="https://api.github.com/repos/${repo}/releases/tags/v${version}"

        if [[ -z "${GITHUB_PAT:-}" ]]; then
            print_error "GITHUB_PAT is required to download from private repositories"
            return 1
        fi

        # Get release info including assets
        local release_info
        release_info=$(curl -sH "Authorization: token $GITHUB_PAT" "$api_url")

        # Find the asset ID for our artifact (needed for private repo downloads)
        local asset_id
        asset_id=$(echo "$release_info" | grep -B5 "\"name\": *\"${artifact_name}\"" | \
            grep '"id":' | head -1 | sed -E 's/.*"id": *([0-9]+).*/\1/')

        if [[ -z "$asset_id" ]]; then
            print_error "Could not find release asset: $artifact_name"
            print_info "Ensure the release v${version} exists and has the artifact attached"
            return 1
        fi

        # For private repos, use the asset API endpoint with Accept header
        local asset_api_url="https://api.github.com/repos/${repo}/releases/assets/${asset_id}"
        print_info "Asset API URL: $asset_api_url"

        # Download using the asset API with octet-stream Accept header
        if ! curl -sL \
            -H "Authorization: token $GITHUB_PAT" \
            -H "Accept: application/octet-stream" \
            -o "$zip_file" \
            "$asset_api_url"; then
            print_error "Failed to download ${module_name} frontend artifact"
            return 1
        fi
    fi

    # Verify download
    if [[ ! -s "$zip_file" ]]; then
        print_error "Downloaded file is empty or not found"
        return 1
    fi

    print_success "Downloaded: $(basename "$zip_file")"

    # Extract to temp location
    local extract_dir="${temp_dir}/extracted"
    mkdir -p "$extract_dir"

    print_info "Extracting archive..."

    if ! check_command_exists unzip; then
        print_error "unzip is not installed (required for frontend artifacts)"
        print_info "Install with: sudo apt install unzip  # or: sudo dnf install unzip"
        return 1
    fi

    if ! unzip -q "$zip_file" -d "$extract_dir"; then
        print_error "Failed to extract ${module_name} frontend archive"
        return 1
    fi

    # Backup existing module if present
    if [[ -d "$module_dir" ]] && [[ "$(ls -A $module_dir 2>/dev/null)" ]]; then
        local backup_dir="${CUSTOMER_MFF_DIR}/${mff_dir}.backup.$(date +%Y%m%d_%H%M%S)"
        print_info "Backing up existing frontend to: $backup_dir"
        mv "$module_dir" "$backup_dir"
    fi

    # Ensure MFF directory exists
    mkdir -p "$CUSTOMER_MFF_DIR"

    # Create module directory
    mkdir -p "$module_dir"

    # Find remoteEntry.js to locate the right directory
    local entry_dir
    entry_dir=$(find "$extract_dir" -name "remoteEntry.js" -type f -exec dirname {} \; | head -1)

    if [[ -n "$entry_dir" ]]; then
        mv "${entry_dir}/"* "$module_dir/"
    elif [[ -d "${extract_dir}/dist" ]]; then
        mv "${extract_dir}/dist/"* "$module_dir/"
    elif [[ -f "${extract_dir}/remoteEntry.js" ]]; then
        mv "${extract_dir}/"* "$module_dir/"
    else
        # Find any directory with content
        local content_dir
        content_dir=$(find "$extract_dir" -mindepth 1 -maxdepth 2 -type d | head -1)
        if [[ -n "$content_dir" ]] && [[ -d "$content_dir" ]]; then
            mv "${content_dir}/"* "$module_dir/" 2>/dev/null || mv "${extract_dir}/"* "$module_dir/"
        else
            mv "${extract_dir}/"* "$module_dir/" 2>/dev/null || true
        fi
    fi

    # Verify remoteEntry.js exists (critical for Module Federation)
    if [[ ! -f "${module_dir}/remoteEntry.js" ]]; then
        print_error "remoteEntry.js not found in extracted archive"
        print_info "The frontend artifact may not be a Module Federation bundle"
        return 1
    fi

    # Write version file
    echo "$version" > "${module_dir}/.version"

    print_success "${module_name} frontend version $version installed to $module_dir"
    return 0
}

# Get installed customer module frontend version
get_customer_frontend_version() {
    local mff_dir="$1"
    local version_file="${CUSTOMER_MFF_DIR}/${mff_dir}/.version"

    if [[ -f "$version_file" ]]; then
        cat "$version_file"
    else
        echo "none"
    fi
}

# Remove customer module frontend files
remove_customer_frontend() {
    local mff_dir="$1"
    local module_dir="${CUSTOMER_MFF_DIR}/${mff_dir}"

    if [[ -d "$module_dir" ]]; then
        print_info "Removing frontend files: $module_dir"
        rm -rf "$module_dir"
        print_success "Frontend files removed"
    else
        print_info "No frontend files found for: $mff_dir"
    fi

    # Also clean up any backups
    local backups
    backups=$(ls -d "${CUSTOMER_MFF_DIR}/${mff_dir}.backup."* 2>/dev/null || true)
    if [[ -n "$backups" ]]; then
        print_info "Removing frontend backups..."
        rm -rf "${CUSTOMER_MFF_DIR}/${mff_dir}.backup."*
    fi

    return 0
}
