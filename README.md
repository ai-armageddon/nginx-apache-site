# create-web-site
`create-web-site` is a merged replacement for `create-apache-site` and
`create-nginx-site`.

It creates:
- Website directory and starter static files in `/var/www/<domain>/public_html`
- Apache or Nginx virtual host config
- Optional Certbot SSL certificate

The package also ships compatibility wrappers:
- `create-apache-site`
- `create-nginx-site`

## Install
```bash
npm install -g create-web-site
```

## Usage
Unified command:
```bash
create-web-site --domain example.com --server nginx
create-web-site --domain example.com --server apache
```

Compatibility wrappers:
```bash
create-apache-site --domain example.com
create-nginx-site --domain example.com
```

### SSL options
- `--ssl` always run Certbot
- `--no-ssl` skip Certbot
- no SSL flag: interactive prompt when running in a terminal

Extra Certbot controls:
- `--certbot-email admin@example.com`
- `--certbot-staging`
- `--yes` auto-confirm SSL prompt

## Common examples
```bash
# Nginx with SSL and Certbot email
create-web-site -d example.com -s nginx --ssl --certbot-email admin@example.com

# Apache without SSL
create-web-site -d example.com -s apache --no-ssl

# Preview actions only
create-web-site -d example.com -s nginx --ssl --dry-run
```

## Requirements
- Ubuntu/Debian-style Apache or Nginx layout
- Root privileges (`sudo`) for non-dry-run mode
- Certbot plugin for your server type if using SSL

## Development tests
```bash
npm test
```

`npm test` runs local shell tests with mocked system commands, so it does not
modify your host web server setup.
