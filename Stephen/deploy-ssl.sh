#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DOMAIN="namecard.cyber-beast.tech"
TARGET_WEB_ROOT="/var/www/${SITE_DOMAIN}"
CERTBOT_WEBROOT="/var/www/certbot"
NGINX_AVAILABLE="/etc/nginx/sites-available/${SITE_DOMAIN}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/${SITE_DOMAIN}.conf"
SSL_MODE="production"
DRY_RUN="no"
CERTBOT_EMAIL="admin@cyber-beast.tech"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--staging] [--dry-run] [--email address]

Deploys the Stefano Qiu namecard, configures Nginx for ${SITE_DOMAIN},
and requests or renews a Let's Encrypt certificate.

Options:
  --email address   Email address for Let's Encrypt notices.
EOF
}

ensure_command_exists() {
  local command_name="$1"
  local install_hint="$2"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf "Required command '%s' was not found. %s\n" "$command_name" "$install_hint" >&2
    exit 1
  fi
}

reload_or_start_nginx() {
  if systemctl is-active --quiet nginx; then
    sudo systemctl reload nginx
    return
  fi

  printf 'Nginx is not running. Starting nginx...\n'
  sudo systemctl start nginx
  sudo systemctl enable nginx
}

write_nginx_http_config() {
  cat <<EOF
server {
    listen 80;
    server_name ${SITE_DOMAIN};

    root ${TARGET_WEB_ROOT};
    index index.html;

    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|svg|webp|ico|vcf)$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
        try_files \$uri =404;
    }
}
EOF
}

write_nginx_https_config() {
  cat <<EOF
server {
    listen 80;
    server_name ${SITE_DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${SITE_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SITE_DOMAIN}/privkey.pem;

    root ${TARGET_WEB_ROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|svg|webp|ico|vcf)$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
        try_files \$uri =404;
    }
}
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --staging)
        SSL_MODE="staging"
        shift
        ;;
      --dry-run)
        DRY_RUN="yes"
        shift
        ;;
      --email)
        shift
        if [[ $# -eq 0 || -z "${1:-}" ]]; then
          printf 'Missing value for --email.\n' >&2
          usage >&2
          exit 1
        fi
        CERTBOT_EMAIL="$1"
        shift
        ;;
      --email=*)
        CERTBOT_EMAIL="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown argument: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  ensure_command_exists rsync "Install rsync first."
  ensure_command_exists sudo "Run this on a system with sudo access."
  ensure_command_exists nginx "Install nginx first."
  ensure_command_exists certbot "Install certbot first."

  if [[ -z "$CERTBOT_EMAIL" ]]; then
    printf 'A non-empty email address is required.\n' >&2
    exit 1
  fi

  printf 'Deploying Stefano Qiu Namecard for %s\n' "$SITE_DOMAIN"

  "$SCRIPT_DIR/sync-site.sh" "$TARGET_WEB_ROOT"

  if [[ "$DRY_RUN" == "yes" ]]; then
    printf 'Dry run enabled. Skipping Nginx and Certbot changes.\n'
    exit 0
  fi

  sudo mkdir -p "$(dirname "$NGINX_AVAILABLE")" "$(dirname "$NGINX_ENABLED")" "$CERTBOT_WEBROOT"

  local temp_nginx_config
  temp_nginx_config="$(mktemp)"

  if [[ -f "/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem" && -f "/etc/letsencrypt/live/${SITE_DOMAIN}/privkey.pem" ]]; then
    write_nginx_https_config > "$temp_nginx_config"
  else
    printf 'No existing certificate found for %s. Installing HTTP bootstrap config first.\n' "$SITE_DOMAIN"
    write_nginx_http_config > "$temp_nginx_config"
  fi

  sudo install -m 0644 "$temp_nginx_config" "$NGINX_AVAILABLE"
  sudo ln -sf "$NGINX_AVAILABLE" "$NGINX_ENABLED"
  sudo nginx -t
  reload_or_start_nginx

  if [[ ! -f "/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem" || ! -f "/etc/letsencrypt/live/${SITE_DOMAIN}/privkey.pem" ]]; then
    certbot_args=(
      certonly
      --webroot
      -w "$CERTBOT_WEBROOT"
      --agree-tos
      --no-eff-email
      --email "$CERTBOT_EMAIL"
      -d "$SITE_DOMAIN"
    )

    if [[ "$SSL_MODE" == "staging" ]]; then
      certbot_args+=(--staging)
    fi

    printf "Requesting a Let's Encrypt certificate for %s...\n" "$SITE_DOMAIN"
    sudo certbot "${certbot_args[@]}"

    write_nginx_https_config > "$temp_nginx_config"
    sudo install -m 0644 "$temp_nginx_config" "$NGINX_AVAILABLE"
    sudo nginx -t
    reload_or_start_nginx
  fi

  rm -f "$temp_nginx_config"
  printf 'SSL deployment complete for https://%s\n' "$SITE_DOMAIN"
}

main "$@"
