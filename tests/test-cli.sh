#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${ROOT_DIR}/script/create-web-site.sh"
APACHE_WRAPPER="${ROOT_DIR}/script/create-apache-site.sh"
NGINX_WRAPPER="${ROOT_DIR}/script/create-nginx-site.sh"
SANDBOX=""

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_exists() {
    [[ -f "$1" ]] || fail "Expected file to exist: $1"
}

assert_symlink_exists() {
    [[ -L "$1" ]] || fail "Expected symlink to exist: $1"
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    grep -F "$pattern" "$file" >/dev/null || fail "Expected '$pattern' in $file"
}

create_mock_bin() {
    local dir="$1"

    cat >"${dir}/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${MOCK_LOG}"
EOF

    cat >"${dir}/a2ensite" <<'EOF'
#!/usr/bin/env bash
echo "a2ensite $*" >> "${MOCK_LOG}"
EOF

    cat >"${dir}/certbot" <<'EOF'
#!/usr/bin/env bash
echo "certbot $*" >> "${MOCK_LOG}"
EOF

    chmod +x "${dir}/systemctl" "${dir}/a2ensite" "${dir}/certbot"
}

setup_env() {
    local sandbox="$1"

    export WEB_SITE_ROOT="${sandbox}/www"
    export WEB_SITE_APACHE_AVAILABLE_DIR="${sandbox}/apache/sites-available"
    export WEB_SITE_NGINX_AVAILABLE_DIR="${sandbox}/nginx/sites-available"
    export WEB_SITE_NGINX_ENABLED_DIR="${sandbox}/nginx/sites-enabled"
    export WEB_SITE_SYSTEMCTL_BIN="systemctl"
    export WEB_SITE_A2ENSITE_BIN="a2ensite"
    export WEB_SITE_CERTBOT_BIN="certbot"
}

test_apache_no_ssl() {
    local sandbox="$1"
    : > "${MOCK_LOG}"
    setup_env "${sandbox}"

    bash "${CLI}" --server apache --domain example.com --no-ssl

    assert_file_exists "${WEB_SITE_ROOT}/example.com/public_html/index.html"
    assert_contains "${WEB_SITE_ROOT}/example.com/public_html/index.html" "example.com"
    assert_file_exists "${WEB_SITE_APACHE_AVAILABLE_DIR}/example.com.conf"
    assert_contains "${WEB_SITE_APACHE_AVAILABLE_DIR}/example.com.conf" "ServerName example.com"
    assert_contains "${MOCK_LOG}" "a2ensite example.com.conf"
    assert_contains "${MOCK_LOG}" "systemctl reload apache2"
    assert_contains "${MOCK_LOG}" "systemctl restart apache2"
}

test_nginx_with_ssl() {
    local sandbox="$1"
    : > "${MOCK_LOG}"
    setup_env "${sandbox}"

    bash "${CLI}" --server nginx --domain example.net --ssl --certbot-email admin@example.net

    assert_file_exists "${WEB_SITE_NGINX_AVAILABLE_DIR}/example.net.conf"
    assert_contains "${WEB_SITE_NGINX_AVAILABLE_DIR}/example.net.conf" "server_name example.net www.example.net;"
    assert_symlink_exists "${WEB_SITE_NGINX_ENABLED_DIR}/example.net.conf"
    assert_contains "${MOCK_LOG}" "systemctl reload nginx"
    assert_contains "${MOCK_LOG}" "systemctl restart nginx"
    assert_contains "${MOCK_LOG}" "certbot --nginx -d example.net -d www.example.net --redirect --non-interactive --agree-tos --email admin@example.net"
}

test_wrappers() {
    local sandbox="$1"
    : > "${MOCK_LOG}"
    setup_env "${sandbox}"

    bash "${APACHE_WRAPPER}" --domain wrapped-apache.com --no-ssl
    bash "${NGINX_WRAPPER}" --domain wrapped-nginx.com --no-ssl

    assert_file_exists "${WEB_SITE_APACHE_AVAILABLE_DIR}/wrapped-apache.com.conf"
    assert_file_exists "${WEB_SITE_NGINX_AVAILABLE_DIR}/wrapped-nginx.com.conf"
}

test_auto_server_mode() {
    local sandbox="$1"
    : > "${MOCK_LOG}"
    setup_env "${sandbox}"

    mkdir -p "${WEB_SITE_NGINX_AVAILABLE_DIR}" "${WEB_SITE_NGINX_ENABLED_DIR}"
    export WEB_SITE_A2ENSITE_BIN="missing-a2ensite"

    bash "${CLI}" --server auto --domain auto-mode.com --no-ssl
    bash "${CLI}" --domain auto-default.com --no-ssl

    assert_file_exists "${WEB_SITE_NGINX_AVAILABLE_DIR}/auto-mode.com.conf"
    assert_file_exists "${WEB_SITE_NGINX_AVAILABLE_DIR}/auto-default.com.conf"
    assert_contains "${MOCK_LOG}" "systemctl reload nginx"
}

main() {
    chmod +x "${CLI}" "${APACHE_WRAPPER}" "${NGINX_WRAPPER}"

    SANDBOX="$(mktemp -d)"
    trap 'rm -rf "${SANDBOX}"' EXIT

    local mock_bin="${SANDBOX}/mock-bin"
    mkdir -p "${mock_bin}"
    create_mock_bin "${mock_bin}"
    export MOCK_LOG="${SANDBOX}/mock.log"
    touch "${MOCK_LOG}"
    export PATH="${mock_bin}:${PATH}"

    test_apache_no_ssl "${SANDBOX}"
    test_nginx_with_ssl "${SANDBOX}"
    test_wrappers "${SANDBOX}"
    test_auto_server_mode "${SANDBOX}"

    echo "All tests passed."
}

main "$@"
