#!/bin/bash
# =============================================================================
# EZY Portal - Configuration Management
# =============================================================================
# Configuration file management and interactive setup wizard
# =============================================================================

# Source common utilities if not already loaded
if [[ -z "${NC:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# -----------------------------------------------------------------------------
# Configuration File Operations
# -----------------------------------------------------------------------------

load_config() {
    local config_file="${1:-${DEPLOY_ROOT}/portal.env}"

    if [[ ! -f "$config_file" ]]; then
        return 1
    fi

    # Export all variables from the config file
    set -a
    source "$config_file"
    set +a

    return 0
}

save_config_value() {
    local key="$1"
    local value="$2"
    local config_file="${3:-${DEPLOY_ROOT}/portal.env}"

    # Escape special characters in value for sed
    local escaped_value
    escaped_value=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')

    if grep -q "^${key}=" "$config_file" 2>/dev/null; then
        # Update existing value
        sed -i "s/^${key}=.*/${key}=${escaped_value}/" "$config_file"
    else
        # Add new value
        echo "${key}=${value}" >> "$config_file"
    fi
}

get_config_value() {
    local key="$1"
    local default="$2"
    local config_file="${3:-${DEPLOY_ROOT}/portal.env}"

    local value
    value=$(grep "^${key}=" "$config_file" 2>/dev/null | cut -d= -f2-)

    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

validate_config() {
    local config_file="${1:-${DEPLOY_ROOT}/portal.env}"
    local errors=0

    if [[ ! -f "$config_file" ]]; then
        print_error "Configuration file not found: $config_file"
        return 1
    fi

    load_config "$config_file"

    print_subsection "Validating configuration"

    # Required: Database
    if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
        print_error "POSTGRES_PASSWORD is not set"
        ((errors++))
    else
        print_success "Database password is set"
    fi

    # Required: Admin email
    if [[ -z "${ADMIN_EMAIL:-}" ]]; then
        print_error "ADMIN_EMAIL is not set"
        ((errors++))
    elif ! is_valid_email "$ADMIN_EMAIL"; then
        print_error "ADMIN_EMAIL is not a valid email address"
        ((errors++))
    else
        print_success "Admin email: $ADMIN_EMAIL"
    fi

    # Required: Application URL
    if [[ -z "${APPLICATION_URL:-}" ]]; then
        print_warning "APPLICATION_URL is not set (will use localhost)"
    elif ! is_valid_url "$APPLICATION_URL"; then
        print_error "APPLICATION_URL is not a valid URL"
        ((errors++))
    else
        print_success "Application URL: $APPLICATION_URL"
    fi

    # Optional but recommended: Authentication
    local has_auth=false
    if [[ -n "${AZURE_AD_CLIENT_ID:-}" ]] && [[ -n "${AZURE_AD_CLIENT_SECRET:-}" ]]; then
        print_success "Azure AD authentication configured"
        has_auth=true
    fi
    if [[ -n "${GOOGLE_CLIENT_ID:-}" ]] && [[ -n "${GOOGLE_CLIENT_SECRET:-}" ]]; then
        print_success "Google authentication configured"
        has_auth=true
    fi
    if [[ "${ALLOW_LOCAL_LOGIN:-}" == "true" ]]; then
        print_success "Local login (email/password) enabled"
        has_auth=true
    fi
    if [[ "$has_auth" == "false" ]]; then
        print_warning "No authentication method configured (Azure AD, Google, or local login required)"
    fi

    if [[ $errors -gt 0 ]]; then
        print_error "$errors configuration errors found"
        return 1
    fi

    print_success "Configuration is valid"
    return 0
}

# -----------------------------------------------------------------------------
# Configuration Wizard
# -----------------------------------------------------------------------------

run_config_wizard() {
    local config_file="${DEPLOY_ROOT}/portal.env"
    local template_file="${DEPLOY_ROOT}/config/portal.env.template"

    print_section "Configuration Wizard"
    print_info "This wizard will help you configure EZY Portal"
    echo ""

    # Determine infrastructure mode
    local infra_mode
    infra_mode=$(prompt_infrastructure_type)

    # Start with appropriate template
    if [[ "$infra_mode" == "full" ]]; then
        cp "${DEPLOY_ROOT}/config/portal.env.full-infra" "$config_file"
    else
        cp "${DEPLOY_ROOT}/config/portal.env.external-infra" "$config_file"
    fi

    save_config_value "INFRASTRUCTURE_MODE" "$infra_mode" "$config_file"

    # Determine tenant mode
    local tenant_mode
    tenant_mode=$(prompt_tenant_mode)

    if [[ "$tenant_mode" == "single" ]]; then
        save_config_value "SINGLE_TENANT_MODE" "true" "$config_file"
        prompt_single_tenant_config "$config_file"
    else
        save_config_value "SINGLE_TENANT_MODE" "false" "$config_file"
    fi

    # Database configuration
    prompt_database_config "$config_file" "$infra_mode"

    # Redis configuration
    prompt_redis_config "$config_file" "$infra_mode"

    # RabbitMQ configuration
    prompt_rabbitmq_config "$config_file" "$infra_mode"

    # Application settings
    prompt_application_config "$config_file"

    # Authentication
    prompt_auth_config "$config_file"

    # Email configuration
    prompt_email_config "$config_file"

    # Admin user
    prompt_admin_config "$config_file"

    # Feature flags
    prompt_features_config "$config_file"

    echo ""
    print_success "Configuration saved to: $config_file"

    return 0
}

prompt_infrastructure_type() {
    echo "" >&2
    print_info "Choose your infrastructure deployment mode:" >&2
    echo "" >&2
    echo "  1. Full Infrastructure (Recommended for new deployments)" >&2
    echo "     - Deploy PostgreSQL, Redis, RabbitMQ as containers" >&2
    echo "     - Everything managed together with portal" >&2
    echo "" >&2
    echo "  2. External Infrastructure" >&2
    echo "     - Use your existing PostgreSQL, Redis, RabbitMQ" >&2
    echo "     - Portal connects to external services" >&2
    echo "" >&2

    while true; do
        read -r -p "Enter choice [1-2]: " choice
        case $choice in
            1) echo "full"; return 0 ;;
            2) echo "external"; return 0 ;;
            *) print_error "Invalid choice" >&2 ;;
        esac
    done
}

prompt_tenant_mode() {
    echo "" >&2
    print_info "Choose your deployment mode:" >&2
    echo "" >&2
    echo "  1. Single-Tenant Mode (Recommended)" >&2
    echo "     - One organization using the portal" >&2
    echo "     - Simplified setup, no tenant management UI" >&2
    echo "" >&2
    echo "  2. Multi-Tenant Mode" >&2
    echo "     - Multiple organizations with separate subdomains" >&2
    echo "     - Full tenant management features" >&2
    echo "" >&2

    while true; do
        read -r -p "Enter choice [1-2]: " choice
        case $choice in
            1) echo "single"; return 0 ;;
            2) echo "multi"; return 0 ;;
            *) print_error "Invalid choice" >&2 ;;
        esac
    done
}

prompt_single_tenant_config() {
    local config_file="$1"

    print_subsection "Single-Tenant Configuration"

    local tenant_name tenant_subdomain

    prompt_input "Organization name" "My Organization" tenant_name
    save_config_value "DEFAULT_TENANT_NAME" "\"$tenant_name\"" "$config_file"

    prompt_input "Tenant subdomain (used in URLs)" "app" tenant_subdomain
    save_config_value "DEFAULT_TENANT_SUBDOMAIN" "$tenant_subdomain" "$config_file"

    # External Accounts (B2B Portal)
    echo ""
    if confirm "Enable External Accounts (B2B Portal)?" "n"; then
        save_config_value "SINGLE_TENANT_EXTERNAL_ACCOUNTS_ENABLED" "true" "$config_file"

        echo ""
        print_info "Choose account linking mode:" >&2
        echo "  1. Standalone - Accounts managed independently with local data" >&2
        echo "  2. BPLinked - Accounts linked to Business Partner microservice" >&2
        echo ""

        while true; do
            read -r -p "Enter choice [1-2]: " linking_choice
            case $linking_choice in
                1)
                    save_config_value "ACCOUNT_LINKING_MODE" "Standalone" "$config_file"
                    break
                    ;;
                2)
                    save_config_value "ACCOUNT_LINKING_MODE" "BPLinked" "$config_file"
                    break
                    ;;
                *)
                    print_error "Invalid choice"
                    ;;
            esac
        done
    else
        save_config_value "SINGLE_TENANT_EXTERNAL_ACCOUNTS_ENABLED" "false" "$config_file"
        save_config_value "ACCOUNT_LINKING_MODE" "Standalone" "$config_file"
    fi

    print_success "Single-tenant configuration complete"
}

prompt_database_config() {
    local config_file="$1"
    local infra_mode="$2"

    print_subsection "Database Configuration"

    if [[ "$infra_mode" == "full" ]]; then
        local db_name db_user db_password

        prompt_input "Database name" "portal" db_name
        save_config_value "POSTGRES_DB" "$db_name" "$config_file"

        prompt_input "Database user" "postgres" db_user
        save_config_value "POSTGRES_USER" "$db_user" "$config_file"

        echo ""
        print_info "Generating secure database password..."
        db_password=$(generate_password_alphanum 24)
        save_config_value "POSTGRES_PASSWORD" "$db_password" "$config_file"
        print_success "Database password generated (saved to config file)"

        # Auto-generate connection string
        local conn_string="Host=postgres;Port=5432;Database=${db_name};Username=${db_user};Password=${db_password}"
        save_config_value "ConnectionStrings__DefaultConnection" "$conn_string" "$config_file"

    else
        local db_host db_port db_name db_user db_password

        prompt_input "PostgreSQL host" "localhost" db_host
        prompt_input "PostgreSQL port" "5432" db_port
        prompt_input "Database name" "portal" db_name
        prompt_input "Database user" "postgres" db_user
        prompt_password "Database password" db_password

        save_config_value "POSTGRES_HOST" "$db_host" "$config_file"
        save_config_value "POSTGRES_PORT" "$db_port" "$config_file"
        save_config_value "POSTGRES_DB" "$db_name" "$config_file"
        save_config_value "POSTGRES_USER" "$db_user" "$config_file"
        save_config_value "POSTGRES_PASSWORD" "$db_password" "$config_file"

        local conn_string="Host=${db_host};Port=${db_port};Database=${db_name};Username=${db_user};Password=${db_password}"
        save_config_value "ConnectionStrings__DefaultConnection" "$conn_string" "$config_file"
    fi
}

prompt_redis_config() {
    local config_file="$1"
    local infra_mode="$2"

    print_subsection "Redis Configuration"

    if [[ "$infra_mode" == "full" ]]; then
        print_info "Redis will be deployed as a container"
        save_config_value "REDIS_HOST" "redis" "$config_file"
        save_config_value "REDIS_PORT" "6379" "$config_file"
    else
        local redis_host redis_port

        prompt_input "Redis host" "localhost" redis_host
        prompt_input "Redis port" "6379" redis_port

        save_config_value "REDIS_HOST" "$redis_host" "$config_file"
        save_config_value "REDIS_PORT" "$redis_port" "$config_file"

        if confirm "Does Redis require authentication?" "n"; then
            local redis_password
            prompt_password "Redis password" redis_password
            save_config_value "REDIS_PASSWORD" "$redis_password" "$config_file"
        fi
    fi
}

prompt_rabbitmq_config() {
    local config_file="$1"
    local infra_mode="$2"

    print_subsection "RabbitMQ Configuration"

    if [[ "$infra_mode" == "full" ]]; then
        print_info "RabbitMQ will be deployed as a container"

        local rmq_user rmq_password
        prompt_input "RabbitMQ user" "portal" rmq_user
        rmq_password=$(generate_password_alphanum 24)

        # Docker container variables
        save_config_value "RABBITMQ_HOST" "rabbitmq" "$config_file"
        save_config_value "RABBITMQ_PORT" "5672" "$config_file"
        save_config_value "RABBITMQ_USER" "$rmq_user" "$config_file"
        save_config_value "RABBITMQ_PASSWORD" "$rmq_password" "$config_file"
        save_config_value "RABBITMQ_DEFAULT_USER" "$rmq_user" "$config_file"
        save_config_value "RABBITMQ_DEFAULT_PASS" "$rmq_password" "$config_file"

        # Application settings (for .NET apps)
        save_config_value "RabbitMq__Enabled" "true" "$config_file"
        save_config_value "RabbitMq__Host" "rabbitmq" "$config_file"
        save_config_value "RabbitMq__Port" "5672" "$config_file"
        save_config_value "RabbitMq__User" "$rmq_user" "$config_file"
        save_config_value "RabbitMq__Password" "$rmq_password" "$config_file"
        save_config_value "RabbitMq__VirtualHost" "/" "$config_file"

        print_success "RabbitMQ password generated"
    else
        local rmq_host rmq_port rmq_user rmq_password

        prompt_input "RabbitMQ host" "localhost" rmq_host
        prompt_input "RabbitMQ port" "5672" rmq_port
        prompt_input "RabbitMQ user" "guest" rmq_user
        prompt_password "RabbitMQ password" rmq_password

        # Docker/external variables
        save_config_value "RABBITMQ_HOST" "$rmq_host" "$config_file"
        save_config_value "RABBITMQ_PORT" "$rmq_port" "$config_file"
        save_config_value "RABBITMQ_USER" "$rmq_user" "$config_file"
        save_config_value "RABBITMQ_PASSWORD" "$rmq_password" "$config_file"

        # Application settings (for .NET apps)
        save_config_value "RabbitMq__Enabled" "true" "$config_file"
        save_config_value "RabbitMq__Host" "$rmq_host" "$config_file"
        save_config_value "RabbitMq__Port" "$rmq_port" "$config_file"
        save_config_value "RabbitMq__User" "$rmq_user" "$config_file"
        save_config_value "RabbitMq__Password" "$rmq_password" "$config_file"
        save_config_value "RabbitMq__VirtualHost" "/" "$config_file"
    fi
}

prompt_application_config() {
    local config_file="$1"

    print_subsection "Application Settings"

    local app_url server_name

    prompt_input "Application URL (e.g., https://portal.company.com)" "https://localhost" app_url
    save_config_value "APPLICATION_URL" "$app_url" "$config_file"
    save_config_value "FRONTEND_URL" "$app_url" "$config_file"

    # Extract domain for nginx
    server_name=$(echo "$app_url" | sed -e 's|https\?://||' -e 's|/.*||')
    save_config_value "SERVER_NAME" "$server_name" "$config_file"

    # CORS
    save_config_value "CORS_ALLOWED_ORIGINS" "$app_url" "$config_file"
}

prompt_auth_config() {
    local config_file="$1"

    print_subsection "Authentication Configuration"

    echo ""
    print_info "Configure at least one authentication method for user login"
    echo ""

    local has_oauth=false

    if confirm "Configure Azure AD authentication?" "y"; then
        local tenant_id client_id client_secret

        prompt_input "Azure AD Tenant ID" "" tenant_id
        prompt_input "Azure AD Client ID" "" client_id
        prompt_password "Azure AD Client Secret" client_secret

        save_config_value "AZURE_AD_TENANT_ID" "$tenant_id" "$config_file"
        save_config_value "AZURE_AD_CLIENT_ID" "$client_id" "$config_file"
        save_config_value "AZURE_AD_CLIENT_SECRET" "$client_secret" "$config_file"

        print_success "Azure AD configured"
        has_oauth=true
    fi

    if confirm "Configure Google OAuth?" "n"; then
        local client_id client_secret

        prompt_input "Google Client ID" "" client_id
        prompt_password "Google Client Secret" client_secret

        save_config_value "GOOGLE_CLIENT_ID" "$client_id" "$config_file"
        save_config_value "GOOGLE_CLIENT_SECRET" "$client_secret" "$config_file"

        print_success "Google OAuth configured"
        has_oauth=true
    fi

    # If no OAuth configured, prompt for local login (otherwise ask as optional)
    echo ""
    if [[ "$has_oauth" == "false" ]]; then
        print_warning "No OAuth provider configured"
        print_info "Local login allows users to authenticate with email and password"
        if confirm "Enable local login (email/password)?" "y"; then
            save_config_value "ALLOW_LOCAL_LOGIN" "true" "$config_file"
            print_success "Local login enabled"
        else
            save_config_value "ALLOW_LOCAL_LOGIN" "false" "$config_file"
            print_warning "No authentication method configured - users will not be able to log in!"
        fi
    else
        print_info "Local login allows users to authenticate with email and password"
        print_info "(in addition to OAuth providers)"
        if confirm "Enable local login?" "n"; then
            save_config_value "ALLOW_LOCAL_LOGIN" "true" "$config_file"
            print_success "Local login enabled"
        else
            save_config_value "ALLOW_LOCAL_LOGIN" "false" "$config_file"
        fi
    fi
}

prompt_email_config() {
    local config_file="$1"

    print_subsection "Email Configuration (Optional)"

    if ! confirm "Configure email notifications?" "n"; then
        print_info "Skipping email configuration"
        return 0
    fi

    local smtp_host smtp_port smtp_user smtp_password from_email

    prompt_input "SMTP host" "smtp.gmail.com" smtp_host
    prompt_input "SMTP port" "587" smtp_port
    prompt_input "SMTP username" "" smtp_user
    prompt_password "SMTP password" smtp_password
    prompt_input "From email address" "$smtp_user" from_email

    save_config_value "Email__ServiceType" "SMTP" "$config_file"
    save_config_value "Email__SmtpHost" "$smtp_host" "$config_file"
    save_config_value "Email__SmtpPort" "$smtp_port" "$config_file"
    save_config_value "Email__Username" "$smtp_user" "$config_file"
    save_config_value "Email__Password" "$smtp_password" "$config_file"
    save_config_value "Email__UseSsl" "true" "$config_file"
    save_config_value "Email__FromName" "Portal" "$config_file"
    save_config_value "Email__FromAddress" "$from_email" "$config_file"

    print_success "Email configured"
}

prompt_admin_config() {
    local config_file="$1"

    print_subsection "Admin User Configuration"

    local admin_email

    prompt_input "Admin email (will have full access)" "" admin_email

    while ! is_valid_email "$admin_email"; do
        print_error "Invalid email address"
        prompt_input "Admin email" "" admin_email
    done

    save_config_value "ADMIN_EMAIL" "$admin_email" "$config_file"

    # Domain restriction
    if confirm "Restrict login to a specific domain?" "n"; then
        local allowed_domain
        local domain_part="${admin_email##*@}"
        prompt_input "Allowed email domain" "$domain_part" allowed_domain
        save_config_value "ALLOWED_DOMAIN" "$allowed_domain" "$config_file"
    fi

    print_success "Admin configured: $admin_email"
}

prompt_features_config() {
    local config_file="$1"

    print_subsection "Feature Configuration"

    # Universal Search - enabled by default
    echo ""
    print_info "Universal Search provides a global search bar in the top navigation"
    print_info "that allows users to search across all entities (accounts, users, etc.)"
    echo ""

    if confirm "Enable Universal Search? (Recommended)" "y"; then
        save_config_value "ADVANCED_SEARCH_ENABLED" "true" "$config_file"
        print_success "Universal Search enabled"
    else
        save_config_value "ADVANCED_SEARCH_ENABLED" "false" "$config_file"
        print_info "Universal Search disabled"
    fi

    # Dark Mode - already in template, just confirm
    if confirm "Enable Dark Mode theme option?" "y"; then
        save_config_value "Frontend__Features__DarkModeEnabled" "true" "$config_file"
    else
        save_config_value "Frontend__Features__DarkModeEnabled" "false" "$config_file"
    fi

    print_success "Features configured"
}

# -----------------------------------------------------------------------------
# Quick Setup (Non-Interactive)
# -----------------------------------------------------------------------------

create_default_config() {
    local config_file="${DEPLOY_ROOT}/portal.env"
    local infra_mode="${1:-full}"

    if [[ "$infra_mode" == "full" ]]; then
        cp "${DEPLOY_ROOT}/config/portal.env.full-infra" "$config_file"
    else
        cp "${DEPLOY_ROOT}/config/portal.env.external-infra" "$config_file"
    fi

    # Generate secure passwords
    local db_password rmq_password
    db_password=$(generate_password_alphanum 24)
    rmq_password=$(generate_password_alphanum 24)

    save_config_value "POSTGRES_PASSWORD" "$db_password" "$config_file"
    save_config_value "RABBITMQ_PASSWORD" "$rmq_password" "$config_file"
    save_config_value "RABBITMQ_DEFAULT_PASS" "$rmq_password" "$config_file"

    # RabbitMQ application settings (for .NET apps)
    save_config_value "RabbitMq__Enabled" "true" "$config_file"
    save_config_value "RabbitMq__Host" "rabbitmq" "$config_file"
    save_config_value "RabbitMq__Port" "5672" "$config_file"
    save_config_value "RabbitMq__User" "portal" "$config_file"
    save_config_value "RabbitMq__Password" "$rmq_password" "$config_file"
    save_config_value "RabbitMq__VirtualHost" "/" "$config_file"

    # Update connection string
    local conn_string="Host=postgres;Port=5432;Database=portal;Username=postgres;Password=${db_password}"
    save_config_value "ConnectionStrings__DefaultConnection" "$conn_string" "$config_file"

    # Feature flags - enable by default
    save_config_value "ADVANCED_SEARCH_ENABLED" "true" "$config_file"
    save_config_value "Frontend__Features__DarkModeEnabled" "true" "$config_file"

    print_success "Default configuration created: $config_file"
    print_warning "Please edit the configuration file to set:"
    print_info "  - ADMIN_EMAIL"
    print_info "  - APPLICATION_URL"
    print_info "  - Authentication: OAuth credentials (Azure AD or Google) and/or ALLOW_LOCAL_LOGIN=true"

    return 0
}

detect_infrastructure_type() {
    local config_file="${1:-${DEPLOY_ROOT}/portal.env}"

    if [[ ! -f "$config_file" ]]; then
        echo "full"
        return
    fi

    local mode
    mode=$(get_config_value "INFRASTRUCTURE_MODE" "" "$config_file")

    if [[ -n "$mode" ]]; then
        echo "$mode"
    else
        # Try to detect from postgres host
        local postgres_host
        postgres_host=$(get_config_value "POSTGRES_HOST" "" "$config_file")

        if [[ "$postgres_host" == "postgres" ]] || [[ -z "$postgres_host" ]]; then
            echo "full"
        else
            echo "external"
        fi
    fi
}
