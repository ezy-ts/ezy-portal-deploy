#!/bin/bash
# =============================================================================
# EZY Portal - Add Customer Module Script
# =============================================================================
# Hot-add a customer-specific micro-frontend module from GitHub Release
#
# Usage:
#   ./add-customer-module.sh ezy-ts/red-cloud-quotation-tool
#   ./add-customer-module.sh ezy-ts/red-cloud-quotation-tool --version 1.0.0
#   ./add-customer-module.sh ezy-ts/red-cloud-quotation-tool --api-key <key>
#   ./add-customer-module.sh ezy-ts/red-cloud-quotation-tool --restart
#   ./add-customer-module.sh --from-file ./package.tar.gz
#
# The portal must be running before adding customer modules.
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
source "$SCRIPT_DIR/lib/api-keys.sh"
source "$SCRIPT_DIR/lib/module-installer.sh"
source "$SCRIPT_DIR/lib/customer-module.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
GITHUB_REPO=""
PACKAGE_VERSION="latest"
API_KEY=""
FROM_FILE=""
UPGRADE_MODE=false
RESTART_MODE=false
VERSION="${VERSION:-latest}"

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
parse_arguments() {
    if [[ $# -lt 1 ]]; then
        show_help
        exit 1
    fi

    # First argument could be repo or --from-file
    if [[ "$1" != "--"* ]]; then
        GITHUB_REPO="$1"
        shift
    fi

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --version)
                PACKAGE_VERSION="$2"
                VERSION="$2"
                shift 2
                ;;
            --api-key)
                API_KEY="$2"
                shift 2
                ;;
            --from-file)
                FROM_FILE="$2"
                shift 2
                ;;
            --upgrade|-u)
                UPGRADE_MODE=true
                shift
                ;;
            --restart|-r)
                RESTART_MODE=true
                shift
                ;;
            --debug)
                DEBUG=true
                export DEBUG
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Validate we have either repo or from-file (restart mode only needs repo)
    if [[ -z "$GITHUB_REPO" && -z "$FROM_FILE" ]]; then
        print_error "Must specify either a GitHub repo or --from-file"
        show_help
        exit 1
    fi

    # Restart mode only needs repo name
    if [[ "$RESTART_MODE" == "true" && -z "$GITHUB_REPO" ]]; then
        print_error "--restart requires a GitHub repo name (e.g., ezy-ts/module-name)"
        exit 1
    fi
}

show_help() {
    echo "EZY Portal - Add Customer Module"
    echo ""
    echo "Usage: ./add-customer-module.sh <org/repo> [OPTIONS]"
    echo "       ./add-customer-module.sh --from-file <package> [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  <org/repo>           GitHub repository (e.g., ezy-ts/red-cloud-quotation-tool)"
    echo ""
    echo "Options:"
    echo "  --version VERSION    Release version to install (default: latest)"
    echo "  --api-key KEY        API key for the module (optional - auto-provisioned if not provided)"
    echo "  --from-file FILE     Install from local package (.tar.gz, .tgz, or .zip)"
    echo "  --upgrade, -u        Upgrade module if already running (no confirmation)"
    echo "  --restart, -r        Restart module to reload portal.env configuration"
    echo "  --debug              Enable debug output"
    echo "  --help, -h           Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Install latest release from GitHub"
    echo "  ./add-customer-module.sh ezy-ts/red-cloud-quotation-tool"
    echo ""
    echo "  # Install specific version"
    echo "  ./add-customer-module.sh ezy-ts/red-cloud-quotation-tool --version v1.0.0"
    echo ""
    echo "  # Restart to reload configuration"
    echo "  ./add-customer-module.sh ezy-ts/red-cloud-quotation-tool --restart"
    echo ""
    echo "  # Install from local zip file"
    echo "  ./add-customer-module.sh --from-file ./quotation-tool-1.0.0.zip"
    echo ""
    echo "Prerequisites:"
    echo "  - Portal must be running"
    echo "  - yq installed (for YAML parsing)"
    echo "  - unzip installed (for .zip files)"
    echo "  - gh CLI installed and authenticated (for private repos)"
    echo "  - jq installed (for module registry)"
}

# -----------------------------------------------------------------------------
# Pre-flight Checks
# -----------------------------------------------------------------------------
check_prerequisites() {
    print_subsection "Checking prerequisites"

    check_docker_installed || return 1
    check_docker_running || return 1
    check_yq_installed || return 1
    check_jq_installed || true  # Warning only
    check_gh_cli_installed || true  # Warning only (fallback to curl for public repos)

    return 0
}

# Use check_portal_running from lib/module-installer.sh
check_portal_is_running() {
    check_portal_running
}

check_module_not_already_running() {
    local module_name="$1"
    # Customer modules use simple container names (no PROJECT_NAME prefix)
    local container="$module_name"

    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_warning "Module '$module_name' is already running"

        local installed_version
        installed_version=$(get_customer_module_version "$module_name")
        if [[ -n "$installed_version" ]]; then
            print_info "Installed version: $installed_version"
        fi

        # In upgrade mode, automatically stop and recreate
        if [[ "$UPGRADE_MODE" == "true" ]]; then
            print_info "Upgrade mode: stopping existing container..."
            stop_customer_module "$module_name"
            return 0
        fi

        if confirm "Recreate the container?" "n"; then
            stop_customer_module "$module_name"
            return 0
        fi
        exit 0
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Main Flow
# -----------------------------------------------------------------------------
download_or_extract_package() {
    local temp_dir="$1"

    if [[ -n "$FROM_FILE" ]]; then
        # Install from local file
        if [[ ! -f "$FROM_FILE" ]]; then
            print_error "Package file not found: $FROM_FILE"
            return 1
        fi

        print_info "Installing from local package: $FROM_FILE"
        extract_package "$FROM_FILE" "$temp_dir"
    else
        # Download from GitHub
        print_info "Downloading release from: $GITHUB_REPO (version: $PACKAGE_VERSION)"

        local downloaded_file
        downloaded_file=$(download_release_asset "$GITHUB_REPO" "$PACKAGE_VERSION" "$temp_dir")

        if [[ -z "$downloaded_file" || ! -f "$downloaded_file" ]]; then
            print_error "Failed to download release asset"
            return 1
        fi

        print_success "Downloaded: $(basename "$downloaded_file")"

        # Extract the package
        local extract_dir="${temp_dir}/extracted"
        extract_package "$downloaded_file" "$extract_dir"

        # Move extracted files to temp_dir root
        mv "$extract_dir"/* "$temp_dir/" 2>/dev/null || true
        rmdir "$extract_dir" 2>/dev/null || true
    fi

    # Verify manifest exists
    if [[ ! -f "${temp_dir}/module-manifest.yaml" ]]; then
        print_error "module-manifest.yaml not found in package"
        return 1
    fi

    print_success "Package extracted successfully"
    return 0
}

pull_customer_image() {
    local image_repo="$1"
    local image_tag="$2"

    local full_image="${image_repo}:${image_tag}"

    # Check if image already exists locally
    if docker image inspect "$full_image" &>/dev/null; then
        print_success "Image found locally: $full_image"
        return 0
    fi

    # Pull from registry
    print_info "Pulling image: $full_image"

    if docker pull "$full_image"; then
        print_success "Image pulled successfully"
        return 0
    else
        print_error "Failed to pull image: $full_image"
        print_info "Check your GITHUB_PAT and network connection, or build/tag the image locally as: $full_image"
        return 1
    fi
}

install_nginx_config() {
    local package_dir="$1"
    local module_name="$2"
    local manifest_file="${package_dir}/module-manifest.yaml"

    local nginx_config_file="${CUSTOMER_NGINX_DIR}/${module_name}.conf"

    # Check if custom nginx configs are provided
    if [[ "$MODULE_HAS_CUSTOM_NGINX" == "true" ]]; then
        print_info "Installing custom nginx configurations..."
        copy_custom_nginx_configs "$package_dir" "$manifest_file"
    else
        # Auto-generate nginx config from manifest
        print_info "Generating nginx configuration (architecture: $MODULE_ARCHITECTURE)..."
        generate_customer_nginx_config \
            "$module_name" \
            "$MODULE_PORT" \
            "$MODULE_API_PREFIX" \
            "$MODULE_MFE_PREFIX" \
            "$nginx_config_file" \
            "$MODULE_ARCHITECTURE" \
            "$MODULE_FRONTEND_MFF_DIR"
    fi

    print_success "Nginx configuration installed"
    return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    init_logging
    parse_arguments "$@"

    echo ""
    print_section "Adding Customer Module"

    # Load existing config
    if [[ -f "$DEPLOY_ROOT/portal.env" ]]; then
        load_config "$DEPLOY_ROOT/portal.env"
    else
        print_error "portal.env not found. Run ./install.sh first."
        exit 1
    fi

    # Pre-flight checks
    print_section "Step 1: Prerequisites"
    check_prerequisites || exit 1
    check_portal_is_running || exit 1

    # GHCR login
    print_subsection "GitHub Container Registry"
    check_ghcr_login || exit 1

    # Restart mode: just restart the container to reload portal.env
    if [[ "$RESTART_MODE" == "true" ]]; then
        local module_name="${GITHUB_REPO##*/}"
        local compose_file
        compose_file=$(get_customer_compose_file "$module_name")

        if [[ ! -f "$compose_file" ]]; then
            print_error "Module '$module_name' is not installed (compose file not found)"
            exit 1
        fi

        print_section "Restarting Module: $module_name"
        print_info "Reloading configuration from portal.env..."

        # Stop and start the container
        stop_customer_module "$module_name"
        start_customer_module "$module_name"

        # Wait for healthy
        wait_for_customer_module_healthy "$module_name" 120 || true

        echo ""
        print_success "Restart complete! $module_name reloaded with new configuration"
        exit 0
    fi

    # Quick upgrade path: when --upgrade and compose file exists with local image available
    if [[ "$UPGRADE_MODE" == "true" && -n "$GITHUB_REPO" ]]; then
        # Extract module name from repo (e.g., red-cloud-quotation-tool from ezy-ts/red-cloud-quotation-tool)
        local module_name="${GITHUB_REPO##*/}"
        local compose_file
        compose_file=$(get_customer_compose_file "$module_name")
        local target_version="$PACKAGE_VERSION"

        if [[ -f "$compose_file" ]]; then
            # Extract image repo from existing compose file
            local image_repo
            image_repo=$(grep -oP 'image:\s*\K[^:]+' "$compose_file" | head -1)
            local full_image="${image_repo}:${target_version}"

            # Check if image exists locally - if so, use quick upgrade path
            if docker image inspect "$full_image" &>/dev/null; then
                print_section "Quick Upgrade Mode"
                print_info "Upgrading $module_name to version $target_version"

                # Stop existing container
                stop_customer_module "$module_name"

                # Update compose file with new version
                sed -i "s|${image_repo}:[^[:space:]]*|${full_image}|g" "$compose_file"
                print_success "Updated compose file to use: $full_image"

                # Start module
                start_customer_module "$module_name"

                # Reload nginx
                reload_nginx || true

                # Wait for healthy
                wait_for_customer_module_healthy "$module_name" 120 || true

                # Update registry
                register_customer_module "$module_name" "$target_version" "${GITHUB_REPO:-local}"

                echo ""
                print_success "Upgrade complete! $module_name is now running version $target_version"
                exit 0
            fi
        fi
    fi

    # Download/extract package
    print_section "Step 2: Download Package"
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT

    if ! download_or_extract_package "$temp_dir"; then
        exit 1
    fi

    # Parse manifest
    print_section "Step 3: Parse Manifest"
    if ! parse_manifest "${temp_dir}/module-manifest.yaml"; then
        exit 1
    fi

    echo ""
    print_info "Module: $MODULE_NAME"
    print_info "Display Name: $MODULE_DISPLAY_NAME"
    print_info "Version: $MODULE_VERSION"
    print_info "Architecture: $MODULE_ARCHITECTURE"
    print_info "Image: $MODULE_IMAGE_REPO:$MODULE_IMAGE_TAG"
    print_info "Port: $MODULE_PORT"
    print_info "API Prefix: $MODULE_API_PREFIX"
    print_info "MFE Prefix: $MODULE_MFE_PREFIX"
    if [[ "$MODULE_HAS_FRONTEND" == "true" ]]; then
        print_info "Frontend Artifact: $MODULE_FRONTEND_ARTIFACT"
        print_info "Frontend MFF Dir: $MODULE_FRONTEND_MFF_DIR"
    fi
    if [[ -n "$MODULE_DEPENDENCIES" ]]; then
        print_info "Module Dependencies: $MODULE_DEPENDENCIES"
    fi
    if [[ -n "$MODULE_SERVICE_DEPENDENCIES" ]]; then
        print_info "Service Dependencies: $MODULE_SERVICE_DEPENDENCIES"
    fi

    # Check dependencies
    print_section "Step 4: Check Dependencies"
    if ! check_customer_module_dependencies "$MODULE_DEPENDENCIES"; then
        exit 1
    fi
    if ! check_service_dependencies "$MODULE_SERVICE_DEPENDENCIES"; then
        exit 1
    fi
    print_success "All dependencies satisfied"

    # Check if already running
    check_module_not_already_running "$MODULE_NAME"

    # Pull image (always use the manifest's image tag - it knows the correct tag)
    print_section "Step 5: Pull Backend Image"
    if ! pull_customer_image "$MODULE_IMAGE_REPO" "$MODULE_IMAGE_TAG"; then
        exit 1
    fi

    # Download frontend artifact for separated architecture
    if [[ "$MODULE_HAS_FRONTEND" == "true" ]]; then
        print_section "Step 6: Install Frontend"

        # Use frontend repo from manifest, or derive from GITHUB_REPO
        local frontend_repo="${MODULE_FRONTEND_REPO:-$GITHUB_REPO}"
        if [[ -z "$frontend_repo" ]]; then
            print_error "Frontend repository not specified in manifest and no GITHUB_REPO provided"
            exit 1
        fi

        if ! download_customer_frontend \
            "$MODULE_NAME" \
            "$MODULE_VERSION" \
            "$MODULE_FRONTEND_ARTIFACT" \
            "$frontend_repo" \
            "$MODULE_FRONTEND_MFF_DIR"; then
            print_error "Failed to install frontend"
            exit 1
        fi
    fi

    # Install nginx config
    print_section "Step 7: Configure Nginx"
    if ! install_nginx_config "$temp_dir" "$MODULE_NAME"; then
        exit 1
    fi

    # Install compose file
    print_section "Step 8: Install Compose File"
    if ! install_customer_compose_file "$temp_dir" "$MODULE_NAME"; then
        exit 1
    fi

    # Handle API key
    print_section "Step 9: API Key"
    if ! save_customer_module_api_key "$MODULE_NAME" "$API_KEY" "$MODULE_API_KEY_ENV_VAR"; then
        print_warning "API key not configured - module may not authenticate properly"
        if ! confirm "Continue anyway?" "n"; then
            exit 1
        fi
    fi

    # Start the module
    print_section "Step 10: Start Module"
    if ! start_customer_module "$MODULE_NAME"; then
        exit 1
    fi

    # Reload nginx
    print_section "Step 11: Reload Nginx"
    reload_nginx || true

    # Wait for healthy
    print_section "Step 12: Health Check"
    wait_for_customer_module_healthy "$MODULE_NAME" 120 || true

    # Register module
    register_customer_module "$MODULE_NAME" "$MODULE_VERSION" "${GITHUB_REPO:-local}"

    # Success output
    local app_url="${APPLICATION_URL:-https://localhost}"
    echo ""
    print_section "Installation Complete!"
    print_success "Customer module '$MODULE_NAME' installed successfully!"
    echo ""
    echo "  Module:       $MODULE_DISPLAY_NAME"
    echo "  Version:      $MODULE_VERSION"
    echo "  Architecture: $MODULE_ARCHITECTURE"
    echo "  API URL:      $app_url$MODULE_API_PREFIX/"
    echo "  MFE URL:      $app_url$MODULE_MFE_PREFIX/"
    echo "  Container:    $MODULE_NAME"
    if [[ "$MODULE_HAS_FRONTEND" == "true" ]]; then
        echo "  Frontend:     ${DEPLOY_ROOT}/dist/mff/${MODULE_FRONTEND_MFF_DIR}/"
    fi
    echo "  Logs:         docker logs $MODULE_NAME"
    echo ""

    log_info "Customer module added: $MODULE_NAME v$MODULE_VERSION (architecture: $MODULE_ARCHITECTURE)"
}

main "$@"
