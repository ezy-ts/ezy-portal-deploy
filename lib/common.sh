#!/bin/bash
# =============================================================================
# EZY Portal - Common Utilities
# =============================================================================
# Shared functions used across all deployment scripts
# =============================================================================

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color
export BOLD='\033[1m'
export DIM='\033[2m'

# Debug mode (set DEBUG=true or use --debug flag)
DEBUG="${DEBUG:-false}"

# Get the root directory of the deployment package
get_deploy_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    # If we're in lib/, go up one level
    if [[ "$script_dir" == */lib ]]; then
        echo "$(dirname "$script_dir")"
    else
        echo "$script_dir"
    fi
}

DEPLOY_ROOT="$(get_deploy_root)"
LOG_FILE="${DEPLOY_ROOT}/install.log"

# -----------------------------------------------------------------------------
# Output Functions
# -----------------------------------------------------------------------------

print_message() {
    local message="$1"
    local color="${2:-$NC}"
    echo -e "${color}${message}${NC}"
}

print_section() {
    local title="$1"
    echo ""
    echo -e "${BLUE}=============================================================================${NC}"
    echo -e "${BOLD}${CYAN}  $title${NC}"
    echo -e "${BLUE}=============================================================================${NC}"
}

print_subsection() {
    local title="$1"
    echo ""
    echo -e "${CYAN}--- $title ---${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_step() {
    local step="$1"
    local total="$2"
    local message="$3"
    echo -e "${CYAN}[${step}/${total}]${NC} ${message}"
}

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------

log_to_file() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
}

log_info() {
    log_to_file "INFO: $1"
}

log_warning() {
    log_to_file "WARNING: $1"
}

log_error() {
    log_to_file "ERROR: $1"
}

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        log_to_file "DEBUG: $1"
    fi
}

# Print debug message to console and log file
# Usage: debug "message"
debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${DIM}[DEBUG] $1${NC}" >&2
        log_to_file "DEBUG: $1"
    fi
}

# -----------------------------------------------------------------------------
# User Interaction
# -----------------------------------------------------------------------------

confirm() {
    local prompt="${1:-Are you sure?}"
    local default="${2:-n}"
    local response

    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -r -p "$prompt" response
    response=${response:-$default}

    [[ "$response" =~ ^[Yy]$ ]]
}

prompt_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local response

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " response
        response=${response:-$default}
    else
        read -r -p "$prompt: " response
    fi

    if [[ -n "$var_name" ]]; then
        eval "$var_name='$response'"
    else
        echo "$response"
    fi
}

prompt_password() {
    local prompt="$1"
    local var_name="$2"
    local password

    read -r -s -p "$prompt: " password
    echo ""

    if [[ -n "$var_name" ]]; then
        eval "$var_name='$password'"
    else
        echo "$password"
    fi
}

prompt_select() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice

    echo "$prompt"
    for i in "${!options[@]}"; do
        echo "  $((i+1)). ${options[$i]}"
    done

    while true; do
        read -r -p "Enter choice [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            echo "${options[$((choice-1))]}"
            return 0
        fi
        print_error "Invalid choice. Please enter a number between 1 and ${#options[@]}"
    done
}

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

check_command_exists() {
    local cmd="$1"
    command -v "$cmd" &> /dev/null
}

generate_password() {
    local length="${1:-32}"
    # Generate secure random password (alphanumeric + special chars)
    tr -dc 'A-Za-z0-9!@#$%^&*()_+=' < /dev/urandom | head -c "$length"
}

generate_password_alphanum() {
    local length="${1:-32}"
    # Generate secure random password (alphanumeric only - safer for env vars)
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

is_valid_email() {
    local email="$1"
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

is_valid_url() {
    local url="$1"
    [[ "$url" =~ ^https?:// ]]
}

is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9]$ ]]
}

# Get the current timestamp for backups/logs
get_timestamp() {
    date '+%Y%m%d_%H%M%S'
}

# Check if running as root or with sudo
is_root() {
    [[ $EUID -eq 0 ]]
}

# Wait with spinner
wait_with_spinner() {
    local pid=$1
    local message="${2:-Please wait...}"
    local delay=0.1
    local spinstr='|/-\'

    printf "%s " "$message"
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf "[%c]" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b"
    done
    printf "   \b\b\b"
    echo ""
}

# -----------------------------------------------------------------------------
# Error Handling
# -----------------------------------------------------------------------------

setup_error_handling() {
    set -e
    trap 'handle_error $LINENO $?' ERR
}

handle_error() {
    local line=$1
    local exit_code=$2

    print_error "Script failed at line $line (exit code: $exit_code)"
    log_error "Script failed at line $line with exit code $exit_code"

    if [[ -n "${CLEANUP_ON_ERROR:-}" ]] && [[ "$CLEANUP_ON_ERROR" == "true" ]]; then
        print_info "Running cleanup..."
        cleanup_on_error
    fi

    echo ""
    print_info "Check the log file for details: $LOG_FILE"

    exit "$exit_code"
}

cleanup_on_error() {
    # Override this function in main scripts if needed
    :
}

# -----------------------------------------------------------------------------
# Version Comparison
# -----------------------------------------------------------------------------

version_compare() {
    # Returns: 0 if equal, 1 if $1 > $2, 2 if $1 < $2
    if [[ "$1" == "$2" ]]; then
        return 0
    fi

    local IFS=.
    local i ver1=($1) ver2=($2)

    # Fill empty fields with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    for ((i=${#ver2[@]}; i<${#ver1[@]}; i++)); do
        ver2[i]=0
    done

    for ((i=0; i<${#ver1[@]}; i++)); do
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done

    return 0
}

is_newer_version() {
    version_compare "$1" "$2"
    [[ $? -eq 1 ]]
}

# -----------------------------------------------------------------------------
# Initialization
# -----------------------------------------------------------------------------

init_logging() {
    # Create log file if it doesn't exist
    touch "$LOG_FILE"
    log_info "=== Script started: $0 ==="
}
