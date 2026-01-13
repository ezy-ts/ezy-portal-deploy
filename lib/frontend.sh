#!/bin/bash
# =============================================================================
# EZY Portal - Frontend Management
# =============================================================================
# Download, install, and update frontend artifacts from GitHub releases
# =============================================================================

# Source common utilities if not already loaded
if [[ -z "${NC:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# Configuration
FRONTEND_REPO="ezy-ts/ezy-portal-frontend"
FRONTEND_DIST_DIR="${DEPLOY_ROOT:-$(get_deploy_root)}/dist/frontend"
MFF_DIST_DIR="${DEPLOY_ROOT:-$(get_deploy_root)}/dist/mff"

# -----------------------------------------------------------------------------
# Frontend Version Management
# -----------------------------------------------------------------------------

# Get the latest frontend version from GitHub releases
get_latest_frontend_version() {
    local repo="${1:-$FRONTEND_REPO}"

    if [[ -z "${GITHUB_PAT:-}" ]]; then
        print_error "GITHUB_PAT is required to fetch release information"
        return 1
    fi

    local latest
    latest=$(curl -sH "Authorization: token $GITHUB_PAT" \
        "https://api.github.com/repos/${repo}/releases/latest" | \
        grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    if [[ -z "$latest" ]]; then
        print_error "Could not determine latest version from ${repo}"
        return 1
    fi

    # Remove 'v' prefix if present for consistency
    latest="${latest#v}"
    echo "$latest"
}

# Get the currently installed frontend version
get_installed_frontend_version() {
    local version_file="${FRONTEND_DIST_DIR}/.version"

    if [[ -f "$version_file" ]]; then
        cat "$version_file"
    else
        echo "none"
    fi
}

# -----------------------------------------------------------------------------
# Frontend Download and Installation
# -----------------------------------------------------------------------------

# Download and install frontend from GitHub releases
# Usage: download_frontend [version]
# If version is "latest" or omitted, fetches the latest release
download_frontend() {
    local version="${1:-latest}"
    local repo="${FRONTEND_REPO}"
    local temp_dir
    local deploy_root="${DEPLOY_ROOT:-$(get_deploy_root)}"

    # Resolve 'latest' to actual version
    if [[ "$version" == "latest" ]]; then
        print_info "Fetching latest frontend version..."
        version=$(get_latest_frontend_version "$repo")
        if [[ $? -ne 0 ]] || [[ -z "$version" ]]; then
            return 1
        fi
    fi

    # Remove 'v' prefix if present
    version="${version#v}"

    print_info "Downloading frontend version: $version"

    # Create temp directory
    temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT

    # Artifact name pattern
    local artifact_name="ezy-portal-frontend-v${version}.zip"
    local zip_file="${temp_dir}/${artifact_name}"

    # Try gh CLI first (works for private repos)
    if check_command_exists gh && gh auth status &>/dev/null; then
        print_info "Downloading release asset using gh CLI..."

        # Build gh release download args
        local gh_args=("release" "download" "v${version}")
        gh_args+=("--repo" "$repo" "--pattern" "$artifact_name" "--dir" "$temp_dir")

        if gh "${gh_args[@]}" 2>/dev/null; then
            if [[ -f "$zip_file" ]]; then
                print_success "Downloaded: $artifact_name"
            else
                # Try to find any downloaded zip file
                local downloaded
                downloaded=$(find "$temp_dir" -name "*.zip" -type f | head -n1)
                if [[ -n "$downloaded" ]]; then
                    zip_file="$downloaded"
                    print_success "Downloaded: $(basename "$downloaded")"
                fi
            fi
        else
            print_warning "gh CLI download failed, trying GitHub API..."
            zip_file=""
        fi
    fi

    # Fallback to GitHub API if gh CLI didn't work
    if [[ ! -f "$zip_file" ]] || [[ ! -s "$zip_file" ]]; then
        print_info "Downloading release asset using GitHub API..."

        # Get release info from API
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
        zip_file="${temp_dir}/${artifact_name}"

        # Download using the asset API with octet-stream Accept header
        if ! curl -sL \
            -H "Authorization: token $GITHUB_PAT" \
            -H "Accept: application/octet-stream" \
            -o "$zip_file" \
            "$asset_api_url"; then
            print_error "Failed to download frontend artifact"
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
    if ! unzip -q "$zip_file" -d "$extract_dir"; then
        print_error "Failed to extract frontend archive"
        return 1
    fi

    # Backup existing frontend if present
    if [[ -d "$FRONTEND_DIST_DIR" ]] && [[ "$(ls -A $FRONTEND_DIST_DIR 2>/dev/null)" ]]; then
        local backup_dir="${deploy_root}/dist/frontend.backup.$(date +%Y%m%d_%H%M%S)"
        print_info "Backing up existing frontend to: $backup_dir"
        mv "$FRONTEND_DIST_DIR" "$backup_dir"
    fi

    # Create frontend directory
    mkdir -p "$FRONTEND_DIST_DIR"

    # Move extracted files
    # Handle both flat structure and nested structure
    if [[ -d "${extract_dir}/dist" ]]; then
        mv "${extract_dir}/dist/"* "$FRONTEND_DIST_DIR/"
    elif [[ -f "${extract_dir}/index.html" ]]; then
        mv "${extract_dir}/"* "$FRONTEND_DIST_DIR/"
    else
        # Find the directory containing index.html
        local index_dir
        index_dir=$(find "$extract_dir" -name "index.html" -type f -exec dirname {} \; | head -1)
        if [[ -n "$index_dir" ]]; then
            mv "${index_dir}/"* "$FRONTEND_DIST_DIR/"
        else
            print_error "Could not find index.html in extracted archive"
            return 1
        fi
    fi

    # Write version file
    echo "$version" > "${FRONTEND_DIST_DIR}/.version"

    print_success "Frontend version $version installed to $FRONTEND_DIST_DIR"
    return 0
}

# -----------------------------------------------------------------------------
# MFF Module Management (Future-Proofing)
# -----------------------------------------------------------------------------

# Download and install a micro-frontend module
# Usage: download_mff_module <module_name> [version] [repo]
download_mff_module() {
    local module_name="$1"
    local version="${2:-latest}"
    local repo="${3:-ezy-ts/ezy-portal-${module_name}}"
    local deploy_root="${DEPLOY_ROOT:-$(get_deploy_root)}"

    if [[ -z "$module_name" ]]; then
        print_error "Module name is required"
        return 1
    fi

    local module_dir="${MFF_DIST_DIR}/${module_name}"
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT

    # Resolve 'latest' to actual version
    if [[ "$version" == "latest" ]]; then
        print_info "Fetching latest frontend version for ${module_name}..."
        version=$(get_latest_frontend_version "$repo")
        if [[ $? -ne 0 ]] || [[ -z "$version" ]]; then
            return 1
        fi
    fi
    version="${version#v}"

    print_info "Downloading ${module_name} frontend version: $version"

    # Artifact name pattern (matches CI/CD output)
    local artifact_name="${module_name}-frontend-${version}.zip"
    local zip_file="${temp_dir}/${artifact_name}"

    # Download using gh CLI or GitHub API (same logic as main frontend)
    if check_command_exists gh && gh auth status &>/dev/null; then
        print_info "Downloading release asset using gh CLI..."
        if ! gh release download "v${version}" --repo "$repo" --pattern "$artifact_name" --dir "$temp_dir" 2>/dev/null; then
            # Try without 'v' prefix
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
    if ! unzip -q "$zip_file" -d "$extract_dir"; then
        print_error "Failed to extract ${module_name} frontend archive"
        return 1
    fi

    # Backup existing module if present
    if [[ -d "$module_dir" ]] && [[ "$(ls -A $module_dir 2>/dev/null)" ]]; then
        local backup_dir="${MFF_DIST_DIR}/${module_name}.backup.$(date +%Y%m%d_%H%M%S)"
        print_info "Backing up existing module to: $backup_dir"
        mv "$module_dir" "$backup_dir"
    fi

    # Ensure MFF directory exists
    mkdir -p "$MFF_DIST_DIR"

    # Create module directory
    mkdir -p "$module_dir"

    # Find remoteEntry.js to locate the right directory
    local entry_dir
    entry_dir=$(find "$extract_dir" -name "remoteEntry.js" -type f -exec dirname {} \; | head -1)

    if [[ -n "$entry_dir" ]]; then
        mv "${entry_dir}/"* "$module_dir/"
    elif [[ -d "${extract_dir}/dist" ]]; then
        mv "${extract_dir}/dist/"* "$module_dir/"
    elif [[ -f "${extract_dir}/index.html" ]]; then
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

# Get installed MFF module version
get_installed_mff_version() {
    local module_name="$1"
    local version_file="${MFF_DIST_DIR}/${module_name}/.version"

    if [[ -f "$version_file" ]]; then
        cat "$version_file"
    else
        echo "none"
    fi
}

# List all installed MFF modules
list_installed_mff_modules() {
    if [[ ! -d "$MFF_DIST_DIR" ]]; then
        echo "none"
        return
    fi

    local modules=()
    for dir in "$MFF_DIST_DIR"/*/; do
        if [[ -d "$dir" ]]; then
            local name
            name=$(basename "$dir")
            if [[ "$name" != "*" ]]; then
                modules+=("$name")
            fi
        fi
    done

    if [[ ${#modules[@]} -eq 0 ]]; then
        echo "none"
    else
        printf '%s\n' "${modules[@]}"
    fi
}

# -----------------------------------------------------------------------------
# Nginx Reload
# -----------------------------------------------------------------------------

# Reload nginx configuration to pick up new static files
reload_nginx() {
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local nginx_container="${project_name}-nginx"

    if docker ps --format '{{.Names}}' | grep -q "^${nginx_container}$"; then
        print_info "Reloading nginx configuration..."
        if docker exec "$nginx_container" nginx -s reload; then
            print_success "Nginx reloaded"
            return 0
        else
            print_error "Failed to reload nginx"
            return 1
        fi
    else
        print_warning "Nginx container not running, skipping reload"
        return 0
    fi
}

# -----------------------------------------------------------------------------
# Directory Setup
# -----------------------------------------------------------------------------

# Create the dist directory structure
create_dist_directories() {
    local deploy_root="${DEPLOY_ROOT:-$(get_deploy_root)}"

    mkdir -p "${deploy_root}/dist/frontend"
    mkdir -p "${deploy_root}/dist/mff"

    # Create .gitkeep files to preserve empty directories
    touch "${deploy_root}/dist/.gitkeep"
    touch "${deploy_root}/dist/mff/.gitkeep"

    print_success "Created dist directory structure"
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------

# Clean up old frontend backups
cleanup_frontend_backups() {
    local keep="${1:-3}"
    local deploy_root="${DEPLOY_ROOT:-$(get_deploy_root)}"
    local backup_dir="${deploy_root}/dist"

    print_info "Cleaning up old frontend backups (keeping last $keep)..."

    # Find and remove old backups
    local backups
    backups=$(ls -dt "${backup_dir}"/frontend.backup.* 2>/dev/null | tail -n +$((keep + 1)))

    if [[ -z "$backups" ]]; then
        print_info "No old frontend backups to clean up"
        return 0
    fi

    echo "$backups" | while read -r backup; do
        print_info "Removing: $backup"
        rm -rf "$backup"
    done

    print_success "Frontend backup cleanup complete"
}
