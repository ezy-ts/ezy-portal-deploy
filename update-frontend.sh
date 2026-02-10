#!/bin/bash
# =============================================================================
# EZY Portal - Frontend Update Script
# =============================================================================
# Update the frontend to a specific version or latest
#
# Usage:
#   ./update-frontend.sh                    # Update to latest
#   ./update-frontend.sh --version 1.2.0    # Update to specific version
#   ./update-frontend.sh --check            # Check for updates
#
# Environment Variables:
#   GITHUB_PAT          - GitHub Personal Access Token (required)
#   FRONTEND_VERSION    - Target version (overridden by --version flag)
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_ROOT="$SCRIPT_DIR"

# Source library scripts
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/checks.sh"
source "$SCRIPT_DIR/lib/frontend.sh"

# Default values
VERSION="latest"
CHECK_ONLY=false

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------

parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --version)
                VERSION="$2"
                shift 2
                ;;
            --check)
                CHECK_ONLY=true
                shift
                ;;
            --help|-h)
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

show_help() {
    echo "EZY Portal Frontend Update Script"
    echo ""
    echo "Usage: ./update-frontend.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --version VERSION    Update to specific version (default: latest)"
    echo "  --check              Check for updates without installing"
    echo "  --help, -h           Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Update to latest"
    echo "  ./update-frontend.sh"
    echo ""
    echo "  # Update to specific version"
    echo "  ./update-frontend.sh --version 1.2.0"
    echo ""
    echo "  # Check for available updates"
    echo "  ./update-frontend.sh --check"
    echo ""
    echo "Environment Variables:"
    echo "  GITHUB_PAT            GitHub Personal Access Token (required)"
    echo "  FRONTEND_VERSION      Default target version (overridden by --version)"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    init_logging

    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  +---------------------------------------------------------------+"
    echo "  |                  EZY Portal Frontend Update                   |"
    echo "  +---------------------------------------------------------------+"
    echo -e "${NC}"

    parse_arguments "$@"

    # Check prerequisites
    print_section "Checking Prerequisites"

    if ! check_github_pat; then
        exit 1
    fi

    # Get current and latest versions
    print_section "Version Information"

    local current_version latest_version
    current_version=$(get_installed_frontend_version)
    latest_version=$(get_latest_frontend_version)

    if [[ $? -ne 0 ]]; then
        print_error "Failed to fetch latest version"
        exit 1
    fi

    print_info "Current frontend version: $current_version"
    print_info "Latest available version: $latest_version"

    if [[ "$CHECK_ONLY" == true ]]; then
        echo ""
        if [[ "$current_version" == "$latest_version" ]]; then
            print_success "Frontend is up to date"
        else
            print_info "Update available: $current_version -> $latest_version"
        fi
        exit 0
    fi

    # Determine target version
    local target_version="$VERSION"
    if [[ "$target_version" == "latest" ]]; then
        target_version="$latest_version"
    fi

    # Remove 'v' prefix if present
    target_version="${target_version#v}"

    print_info "Target version: $target_version"

    if [[ "$current_version" == "$target_version" ]]; then
        print_info "Already running version $target_version"
        if ! confirm "Reinstall anyway?" "n"; then
            exit 0
        fi
    fi

    # Download and install
    print_section "Installing Frontend"

    if download_frontend "$target_version"; then
        print_success "Frontend updated to version $target_version"

        # Save version to config if portal.env exists
        if [[ -f "$DEPLOY_ROOT/portal.env" ]]; then
            # Check if config.sh is available for save_config_value
            if type save_config_value &>/dev/null; then
                save_config_value "FRONTEND_VERSION" "$target_version" "$DEPLOY_ROOT/portal.env"
            fi
        fi

        # Reload nginx if running
        reload_nginx

        # Cleanup old backups
        cleanup_frontend_backups 3

        echo ""
        print_success "Frontend update complete!"
        echo ""
        echo "  Version: $target_version"
        echo "  Location: $FRONTEND_DIST_DIR"
        echo ""
    else
        print_error "Frontend update failed"
        exit 1
    fi
}

main "$@"
