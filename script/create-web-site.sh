#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly STATIC_DIR="${PROJECT_DIR}/assets/static"
readonly SERVER_TEMPLATE_DIR="${PROJECT_DIR}/assets/server"

WEB_ROOT="${WEB_SITE_ROOT:-/var/www}"
APACHE_AVAILABLE_DIR="${WEB_SITE_APACHE_AVAILABLE_DIR:-/etc/apache2/sites-available}"
NGINX_AVAILABLE_DIR="${WEB_SITE_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
NGINX_ENABLED_DIR="${WEB_SITE_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
SYSTEMCTL_BIN="${WEB_SITE_SYSTEMCTL_BIN:-systemctl}"
A2ENSITE_BIN="${WEB_SITE_A2ENSITE_BIN:-a2ensite}"
CERTBOT_BIN="${WEB_SITE_CERTBOT_BIN:-certbot}"

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

print_usage() {
    cat <<'EOF'
Usage:
  nginx-apache-site -d|--domain <domain> [-s|--server <apache|nginx|auto>] [options]

Server shortcuts:
  create-apache-site -d|--domain <domain> [options]
  create-nginx-site -d|--domain <domain> [options]

Options:
  -d, --domain <domain>       Domain name to configure.
  -s, --server <type>         Web server: apache, nginx, or auto.
      --auto                  Shortcut for --server auto.
      --apache                Shortcut for --server apache.
      --nginx                 Shortcut for --server nginx.
      --ssl                   Always request a Certbot certificate.
      --no-ssl                Skip Certbot certificate request.
      --certbot-email <email> Email address for Certbot.
      --certbot-staging       Use Certbot staging endpoint.
      --yes                   Auto-confirm SSL prompt when applicable.
      --dry-run               Print planned actions without making changes.
  -h, --help                  Show this message.
EOF
}

is_command_available() {
    command -v "$1" >/dev/null 2>&1
}

escape_for_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\/&#\\]/\\&/g'
}

run_cmd() {
    if [[ "${dry_run}" == "true" ]]; then
        printf '[dry-run] %q' "$1"
        shift
        for arg in "$@"; do
            printf ' %q' "${arg}"
        done
        printf '\n'
        return 0
    fi

    "$@"
}

replace_placeholders_in_file() {
    local file_path="$1"
    local escaped_domain
    local escaped_web_root

    escaped_domain="$(escape_for_sed_replacement "${domain_name}")"
    escaped_web_root="$(escape_for_sed_replacement "${WEB_ROOT}")"

    if [[ "${dry_run}" == "true" ]]; then
        printf '[dry-run] render template %s\n' "${file_path}"
        return 0
    fi

    sed -i.bak \
        -e "s/{{DOMAIN_NAME}}/${escaped_domain}/g" \
        -e "s/{{WEB_ROOT}}/${escaped_web_root}/g" \
        "${file_path}"
    rm -f "${file_path}.bak"
}

validate_domain() {
    [[ "${domain_name}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] \
        || fail "Invalid domain '${domain_name}'."

    [[ "${domain_name}" == *.* ]] \
        || fail "Domain '${domain_name}' must include at least one dot."
}

validate_requested_server_type() {
    case "${server_type}" in
        ""|auto|apache|nginx) ;;
        *)
            fail "Unsupported server '${server_type}'. Use apache, nginx, or auto."
            ;;
    esac
}

validate_server_type() {
    case "${server_type}" in
        apache|nginx) ;;
        *)
            fail "Unsupported server '${server_type}'. Use apache or nginx."
            ;;
    esac
}

prompt_for_server_type_if_needed() {
    local selection

    if [[ -n "${server_type}" ]]; then
        return
    fi

    if [[ -t 0 ]]; then
        read -r -p "Web server [auto/apache/nginx] (default: auto): " selection || true
        selection="${selection,,}"
        server_type="${selection:-auto}"
    else
        server_type="auto"
    fi

    validate_requested_server_type
}

resolve_auto_server_type() {
    local apache_score=0
    local nginx_score=0

    if [[ "${server_type}" != "auto" ]]; then
        return
    fi

    if [[ -d "${APACHE_AVAILABLE_DIR}" ]]; then
        apache_score=$((apache_score + 2))
    fi
    if is_command_available "${A2ENSITE_BIN}"; then
        apache_score=$((apache_score + 2))
    fi
    if [[ -d "/etc/apache2" ]]; then
        apache_score=$((apache_score + 1))
    fi

    if [[ -d "${NGINX_AVAILABLE_DIR}" ]]; then
        nginx_score=$((nginx_score + 2))
    fi
    if [[ -d "${NGINX_ENABLED_DIR}" ]]; then
        nginx_score=$((nginx_score + 1))
    fi
    if is_command_available nginx; then
        nginx_score=$((nginx_score + 1))
    fi
    if [[ -d "/etc/nginx" ]]; then
        nginx_score=$((nginx_score + 1))
    fi

    if [[ "${nginx_score}" -eq 0 ]] && [[ "${apache_score}" -eq 0 ]]; then
        fail "Auto-detection could not find Apache or Nginx. Use --server apache or --server nginx."
    fi

    if [[ "${nginx_score}" -ge "${apache_score}" ]]; then
        server_type="nginx"
    else
        server_type="apache"
    fi

    printf 'Auto-selected server: %s\n' "${server_type}"
}

warn_if_not_root() {
    if [[ "${dry_run}" == "false" ]] && [[ "${EUID}" -ne 0 ]]; then
        printf 'Warning: running without root; writes may fail for system paths.\n' >&2
    fi
}

ask_yes_no() {
    local question="$1"
    local response
    read -r -p "${question} [y/N]: " response || true
    [[ "${response}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

decide_ssl_mode() {
    case "${ssl_mode}" in
        yes)
            should_run_ssl="true"
            ;;
        no)
            should_run_ssl="false"
            ;;
        ask)
            if [[ "${assume_yes}" == "true" ]]; then
                should_run_ssl="true"
            elif [[ -t 0 ]]; then
                if ask_yes_no "Request SSL certificate from Certbot now?"; then
                    should_run_ssl="true"
                else
                    should_run_ssl="false"
                fi
            else
                should_run_ssl="false"
            fi
            ;;
        *)
            fail "Unexpected SSL mode '${ssl_mode}'."
            ;;
    esac
}

resolve_certbot_identity() {
    if [[ "${should_run_ssl}" != "true" ]]; then
        return
    fi

    if [[ -z "${certbot_email}" ]] && [[ -t 0 ]] && [[ "${assume_yes}" != "true" ]]; then
        read -r -p "Certbot email (leave blank to skip): " certbot_email || true
    fi
}

check_required_commands() {
    local needed=("cp" "mkdir" "sed")
    if [[ "${server_type}" == "apache" ]]; then
        needed+=("${A2ENSITE_BIN}" "${SYSTEMCTL_BIN}")
    else
        needed+=("ln" "${SYSTEMCTL_BIN}")
    fi

    if [[ "${should_run_ssl}" == "true" ]]; then
        needed+=("${CERTBOT_BIN}")
    fi

    local cmd
    for cmd in "${needed[@]}"; do
        if ! is_command_available "${cmd}"; then
            fail "Missing required command: ${cmd}"
        fi
    done
}

create_site_directory() {
    local site_path="${WEB_ROOT}/${domain_name}/public_html"
    run_cmd mkdir -p "${site_path}"
    run_cmd cp -R "${STATIC_DIR}/." "${site_path}/"
    replace_placeholders_in_file "${site_path}/index.html"
    printf 'Created site files in %s\n' "${site_path}"
}

create_server_config() {
    local template_path
    local config_path

    if [[ "${server_type}" == "apache" ]]; then
        template_path="${SERVER_TEMPLATE_DIR}/apache.template.conf"
        config_path="${APACHE_AVAILABLE_DIR}/${domain_name}.conf"
        run_cmd mkdir -p "${APACHE_AVAILABLE_DIR}"
    else
        template_path="${SERVER_TEMPLATE_DIR}/nginx.template.conf"
        config_path="${NGINX_AVAILABLE_DIR}/${domain_name}.conf"
        run_cmd mkdir -p "${NGINX_AVAILABLE_DIR}"
    fi

    [[ -f "${template_path}" ]] || fail "Missing template file: ${template_path}"

    run_cmd cp "${template_path}" "${config_path}"
    replace_placeholders_in_file "${config_path}"
    printf 'Created %s config: %s\n' "${server_type}" "${config_path}"
}

enable_apache_site() {
    run_cmd "${A2ENSITE_BIN}" "${domain_name}.conf"
    run_cmd "${SYSTEMCTL_BIN}" reload apache2
    run_cmd "${SYSTEMCTL_BIN}" restart apache2
    printf 'Enabled Apache site %s\n' "${domain_name}"
}

enable_nginx_site() {
    local config_path="${NGINX_AVAILABLE_DIR}/${domain_name}.conf"
    local symlink_path="${NGINX_ENABLED_DIR}/${domain_name}.conf"

    run_cmd mkdir -p "${NGINX_ENABLED_DIR}"

    if [[ -e "${symlink_path}" ]] || [[ -L "${symlink_path}" ]]; then
        printf 'Nginx symlink already exists: %s\n' "${symlink_path}"
    else
        run_cmd ln -s "${config_path}" "${symlink_path}"
        printf 'Created Nginx symlink: %s\n' "${symlink_path}"
    fi

    run_cmd "${SYSTEMCTL_BIN}" reload nginx
    run_cmd "${SYSTEMCTL_BIN}" restart nginx
    printf 'Enabled Nginx site %s\n' "${domain_name}"
}

run_certbot() {
    local certbot_args=(
        "--${server_type}"
        "-d" "${domain_name}"
        "-d" "www.${domain_name}"
        "--redirect"
        "--non-interactive"
        "--agree-tos"
    )

    if [[ -n "${certbot_email}" ]]; then
        certbot_args+=("--email" "${certbot_email}")
    else
        certbot_args+=("--register-unsafely-without-email")
    fi

    if [[ "${certbot_staging}" == "true" ]]; then
        certbot_args+=("--staging")
    fi

    run_cmd "${CERTBOT_BIN}" "${certbot_args[@]}"
    printf 'Requested SSL certificate via Certbot for %s\n' "${domain_name}"
}

domain_name=""
server_type=""
ssl_mode="ask"
should_run_ssl="false"
certbot_email=""
certbot_staging="false"
assume_yes="false"
dry_run="false"

case "$(basename "$0")" in
    create-apache-site|create-apache-site.sh)
        server_type="apache"
        ;;
    create-nginx-site|create-nginx-site.sh)
        server_type="nginx"
        ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)
            [[ $# -ge 2 ]] || fail "Missing value for $1"
            domain_name="$2"
            shift 2
            ;;
        -s|--server)
            [[ $# -ge 2 ]] || fail "Missing value for $1"
            server_type="$2"
            shift 2
            ;;
        --auto)
            server_type="auto"
            shift
            ;;
        --apache)
            server_type="apache"
            shift
            ;;
        --nginx)
            server_type="nginx"
            shift
            ;;
        --ssl)
            ssl_mode="yes"
            shift
            ;;
        --no-ssl)
            ssl_mode="no"
            shift
            ;;
        --certbot-email)
            [[ $# -ge 2 ]] || fail "Missing value for $1"
            certbot_email="$2"
            shift 2
            ;;
        --certbot-staging)
            certbot_staging="true"
            shift
            ;;
        --yes|-y)
            assume_yes="true"
            shift
            ;;
        --dry-run)
            dry_run="true"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            fail "Invalid option: $1"
            ;;
    esac
done

[[ -n "${domain_name}" ]] || fail "You must provide -d|--domain."

server_type="${server_type,,}"

validate_domain
validate_requested_server_type
prompt_for_server_type_if_needed
resolve_auto_server_type
validate_server_type
decide_ssl_mode
resolve_certbot_identity
check_required_commands
warn_if_not_root

printf 'Domain: %s\n' "${domain_name}"
printf 'Server: %s\n' "${server_type}"
printf 'SSL: %s\n' "${should_run_ssl}"
if [[ -n "${certbot_email}" ]]; then
    printf 'Certbot email: %s\n' "${certbot_email}"
fi
if [[ "${dry_run}" == "true" ]]; then
    printf 'Dry run mode enabled.\n'
fi

create_site_directory
create_server_config

if [[ "${server_type}" == "apache" ]]; then
    enable_apache_site
else
    enable_nginx_site
fi

if [[ "${should_run_ssl}" == "true" ]]; then
    run_certbot
fi

printf 'Setup complete for %s (%s)\n' "${domain_name}" "${server_type}"
