#!/bin/bash
# =============================================================================
# EZY Portal - Add Customer Module Script
# =============================================================================
# Hot-add a customer-specific micro-frontend module from GitHub Release
#
# Usage:
#   ./add-customer-module.sh ezy-prop/red-cloud-quotation-tool
#   ./add-customer-module.sh ezy-prop/red-cloud-quotation-tool --version 1.0.0
#   ./add-customer-module.sh ezy-prop/red-cloud-quotation-tool --api-key <key>
#   ./add-customer-module.sh --from-file ./package.tar.gz
#   ./add-customer-module.sh ezy-prop/red-cloud-quotation-tool --local
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
source "$SCRIPT_DIR/lib/customer-module.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
GITHUB_REPO=""
PACKAGE_VERSION="latest"
API_KEY=""
FROM_FILE=""
USE_LOCAL_IMAGES=false
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
            --local)
                USE_LOCAL_IMAGES=true
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

    # Validate we have either repo or from-file
    if [[ -z "$GITHUB_REPO" && -z "$FROM_FILE" ]]; then
        print_error "Must specify either a GitHub repo or --from-file"
        show_help
        exit 1
    fi

    export USE_LOCAL_IMAGES
}

show_help() {
    echo "EZY Portal - Add Customer Module"
    echo ""
    echo "Usage: ./add-customer-module.sh <org/repo> [OPTIONS]"
    echo "       ./add-customer-module.sh --from-file <package.tar.gz> [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  <org/repo>           GitHub repository (e.g., ezy-prop/red-cloud-quotation-tool)"
    echo ""
    echo "Options:"
    echo "  --version VERSION    Release version to install (default: latest)"
    echo "  --api-key KEY        API key for the module (optional - auto-provisioned if not provided)"
    echo "  --from-file FILE     Install from local tarball instead of GitHub"
    echo "  --local              Use local Docker image instead of GHCR"
    echo "  --help, -h           Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Install latest release from GitHub"
    echo "  ./add-customer-module.sh ezy-prop/red-cloud-quotation-tool"
    echo ""
    echo "  # Install specific version"
    echo "  ./add-customer-module.sh ezy-prop/red-cloud-quotation-tool --version v1.0.0"
    echo ""
    echo "  # Install with explicit API key"
    echo "  ./add-customer-module.sh ezy-prop/red-cloud-quotation-tool --api-key abc123"
    echo ""
    echo "  # Install from local package file"
    echo "  ./add-customer-module.sh --from-file ./quotation-tool-1.0.0.tar.gz"
    echo ""
    echo "Prerequisites:"
    echo "  - Portal must be running"
    echo "  - yq installed (for YAML parsing)"
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

check_portal_is_running() {
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="$project_name"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_error "Portal is not running"
        print_info "Start the portal first with: ./install.sh"
        return 1
    fi

    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")

    if [[ "$health" != "healthy" ]]; then
        print_warning "Portal is running but not healthy (status: $health)"
        if ! confirm "Continue anyway?" "n"; then
            exit 1
        fi
    else
        print_success "Portal is running and healthy"
    fi

    return 0
}

check_module_not_already_running() {
    local module_name="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-${module_name}"

    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_warning "Module '$module_name' is already running"

        local installed_version
        installed_version=$(get_customer_module_version "$module_name")
        if [[ -n "$installed_version" ]]; then
            print_info "Installed version: $installed_version"
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

    if [[ "$USE_LOCAL_IMAGES" == "true" ]]; then
        print_info "Using local image (--local specified)"

        # Check if local image exists
        if docker image inspect "$full_image" &>/dev/null; then
            print_success "Local image found: $full_image"
            return 0
        else
            print_error "Local image not found: $full_image"
            print_info "Build the image locally first or remove --local flag"
            return 1
        fi
    fi

    print_info "Pulling image: $full_image"

    if docker pull "$full_image"; then
        print_success "Image pulled successfully"
        return 0
    else
        print_error "Failed to pull image: $full_image"
        print_info "Check your GITHUB_PAT and network connection"
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
        print_info "Generating nginx configuration..."
        generate_customer_nginx_config \
            "$module_name" \
            "$MODULE_PORT" \
            "$MODULE_API_PREFIX" \
            "$MODULE_MFE_PREFIX" \
            "$nginx_config_file"
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

    # GHCR login if not using local images
    if [[ "$USE_LOCAL_IMAGES" != "true" ]]; then
        print_subsection "GitHub Container Registry"
        check_ghcr_login || exit 1
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
    print_info "Image: $MODULE_IMAGE_REPO:$MODULE_IMAGE_TAG"
    print_info "Port: $MODULE_PORT"
    print_info "API Prefix: $MODULE_API_PREFIX"
    print_info "MFE Prefix: $MODULE_MFE_PREFIX"
    if [[ -n "$MODULE_DEPENDENCIES" ]]; then
        print_info "Dependencies: $MODULE_DEPENDENCIES"
    fi

    # Check dependencies
    print_section "Step 4: Check Dependencies"
    if ! check_customer_module_dependencies "$MODULE_DEPENDENCIES"; then
        exit 1
    fi
    print_success "All dependencies satisfied"

    # Check if already running
    check_module_not_already_running "$MODULE_NAME"

    # Pull image
    print_section "Step 5: Pull Image"
    local image_tag="${MODULE_IMAGE_TAG}"
    if [[ "$PACKAGE_VERSION" != "latest" && "$PACKAGE_VERSION" != "$MODULE_IMAGE_TAG" ]]; then
        # Use version from command line if specified
        image_tag="$PACKAGE_VERSION"
    fi
    if ! pull_customer_image "$MODULE_IMAGE_REPO" "$image_tag"; then
        exit 1
    fi

    # Install nginx config
    print_section "Step 6: Configure Nginx"
    if ! install_nginx_config "$temp_dir" "$MODULE_NAME"; then
        exit 1
    fi

    # Install compose file
    print_section "Step 7: Install Compose File"
    if ! install_customer_compose_file "$temp_dir" "$MODULE_NAME"; then
        exit 1
    fi

    # Handle API key
    print_section "Step 8: API Key"
    if ! save_customer_module_api_key "$MODULE_NAME" "$API_KEY" "$MODULE_API_KEY_ENV_VAR"; then
        print_warning "API key not configured - module may not authenticate properly"
        if ! confirm "Continue anyway?" "n"; then
            exit 1
        fi
    fi

    # Start the module
    print_section "Step 9: Start Module"
    if ! start_customer_module "$MODULE_NAME"; then
        exit 1
    fi

    # Reload nginx
    print_section "Step 10: Reload Nginx"
    reload_nginx || true

    # Wait for healthy
    print_section "Step 11: Health Check"
    wait_for_customer_module_healthy "$MODULE_NAME" 120 || true

    # Register module
    register_customer_module "$MODULE_NAME" "$MODULE_VERSION" "${GITHUB_REPO:-local}"

    # Success output
    local app_url="${APPLICATION_URL:-https://localhost}"
    echo ""
    print_section "Installation Complete!"
    print_success "Customer module '$MODULE_NAME' installed successfully!"
    echo ""
    echo "  Module:      $MODULE_DISPLAY_NAME"
    echo "  Version:     $MODULE_VERSION"
    echo "  API URL:     $app_url$MODULE_API_PREFIX/"
    echo "  MFE URL:     $app_url$MODULE_MFE_PREFIX/"
    echo "  Container:   ${PROJECT_NAME:-ezy-portal}-$MODULE_NAME"
    echo "  Logs:        docker logs ${PROJECT_NAME:-ezy-portal}-$MODULE_NAME"
    echo ""

    log_info "Customer module added: $MODULE_NAME v$MODULE_VERSION"
}

main "$@"
