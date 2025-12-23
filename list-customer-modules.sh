#!/bin/bash
# =============================================================================
# EZY Portal - List Customer Modules Script
# =============================================================================
# List all installed customer-specific micro-frontend modules with status
#
# Usage:
#   ./list-customer-modules.sh
#   ./list-customer-modules.sh --json
# =============================================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_ROOT="$SCRIPT_DIR"

# Source library scripts
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/customer-module.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
OUTPUT_FORMAT="table"

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --json)
                OUTPUT_FORMAT="json"
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
}

show_help() {
    echo "EZY Portal - List Customer Modules"
    echo ""
    echo "Usage: ./list-customer-modules.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --json      Output in JSON format"
    echo "  --help, -h  Show this help message"
}

# -----------------------------------------------------------------------------
# Get Module Status
# -----------------------------------------------------------------------------
get_module_status() {
    local module_name="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-${module_name}"

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "not_deployed"
        return
    fi

    local status
    status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")

    case "$status" in
        running)
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
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
# Main
# -----------------------------------------------------------------------------
main() {
    parse_arguments "$@"

    # Load config for PROJECT_NAME
    if [[ -f "$DEPLOY_ROOT/portal.env" ]]; then
        source "$DEPLOY_ROOT/portal.env" 2>/dev/null || true
    fi

    local registry_file="${CUSTOMER_MODULES_DIR}/installed.json"

    if [[ ! -f "$registry_file" ]]; then
        if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            echo '{"modules":[]}'
        else
            echo "No customer modules installed"
        fi
        exit 0
    fi

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        # JSON output with status
        if check_command_exists jq; then
            local result='{"modules":['
            local first=true

            while IFS= read -r module_name; do
                [[ -z "$module_name" ]] && continue

                local version repo installed_at status
                version=$(jq -r --arg name "$module_name" '.modules[$name].version // ""' "$registry_file")
                repo=$(jq -r --arg name "$module_name" '.modules[$name].repo // ""' "$registry_file")
                installed_at=$(jq -r --arg name "$module_name" '.modules[$name].installedAt // ""' "$registry_file")
                status=$(get_module_status "$module_name")

                if [[ "$first" == "true" ]]; then
                    first=false
                else
                    result+=","
                fi

                result+="{\"name\":\"$module_name\",\"version\":\"$version\",\"repo\":\"$repo\",\"installedAt\":\"$installed_at\",\"status\":\"$status\"}"
            done < <(jq -r '.modules | keys[]' "$registry_file" 2>/dev/null)

            result+=']}'
            echo "$result" | jq .
        else
            cat "$registry_file"
        fi
    else
        # Table output
        echo ""
        printf "%-30s %-15s %-12s %-40s\n" "MODULE" "VERSION" "STATUS" "REPOSITORY"
        printf "%-30s %-15s %-12s %-40s\n" "------" "-------" "------" "----------"

        if check_command_exists jq; then
            while IFS= read -r module_name; do
                [[ -z "$module_name" ]] && continue

                local version repo status
                version=$(jq -r --arg name "$module_name" '.modules[$name].version // "?"' "$registry_file")
                repo=$(jq -r --arg name "$module_name" '.modules[$name].repo // "?"' "$registry_file")
                status=$(get_module_status "$module_name")

                # Color status
                local status_colored="$status"
                case "$status" in
                    healthy)
                        status_colored="${GREEN}healthy${NC}"
                        ;;
                    unhealthy)
                        status_colored="${RED}unhealthy${NC}"
                        ;;
                    running)
                        status_colored="${YELLOW}running${NC}"
                        ;;
                    stopped)
                        status_colored="${RED}stopped${NC}"
                        ;;
                    not_deployed)
                        status_colored="${YELLOW}not_deployed${NC}"
                        ;;
                esac

                printf "%-30s %-15s %-12b %-40s\n" "$module_name" "$version" "$status_colored" "$repo"
            done < <(jq -r '.modules | keys[]' "$registry_file" 2>/dev/null)
        else
            print_warning "jq not installed - limited output"
            cat "$registry_file"
        fi

        echo ""
    fi
}

main "$@"
