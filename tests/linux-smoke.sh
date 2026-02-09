#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Skipping Linux smoke tests on non-Linux host."
    exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${ROOT_DIR}/script/create-web-site.sh"

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

main() {
    chmod +x "${CLI}"

    local sandbox
    sandbox="$(mktemp -d)"
    trap 'rm -rf "${sandbox}"' EXIT

    local mock_bin="${sandbox}/mock-bin"
    mkdir -p "${mock_bin}"
    create_mock_bin "${mock_bin}"

    export PATH="${mock_bin}:${PATH}"
    export MOCK_LOG="${sandbox}/mock.log"
    : > "${MOCK_LOG}"

    export WEB_SITE_ROOT="${sandbox}/www"
    export WEB_SITE_APACHE_AVAILABLE_DIR="${sandbox}/apache/sites-available"
    export WEB_SITE_NGINX_AVAILABLE_DIR="${sandbox}/nginx/sites-available"
    export WEB_SITE_NGINX_ENABLED_DIR="${sandbox}/nginx/sites-enabled"
    export WEB_SITE_SYSTEMCTL_BIN="systemctl"
    export WEB_SITE_A2ENSITE_BIN="a2ensite"
    export WEB_SITE_CERTBOT_BIN="certbot"

    bash "${CLI}" --server apache --domain linux-apache.test --ssl --certbot-email ops@linux-apache.test
    bash "${CLI}" --server nginx --domain linux-nginx.test --no-ssl

    assert_file_exists "${WEB_SITE_APACHE_AVAILABLE_DIR}/linux-apache.test.conf"
    assert_file_exists "${WEB_SITE_NGINX_AVAILABLE_DIR}/linux-nginx.test.conf"
    assert_symlink_exists "${WEB_SITE_NGINX_ENABLED_DIR}/linux-nginx.test.conf"
    assert_contains "${MOCK_LOG}" "certbot --apache -d linux-apache.test -d www.linux-apache.test --redirect --non-interactive --agree-tos --email ops@linux-apache.test"
    assert_contains "${MOCK_LOG}" "systemctl restart apache2"
    assert_contains "${MOCK_LOG}" "systemctl restart nginx"

    echo "Linux smoke tests passed."
}

main "$@"
