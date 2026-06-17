#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

read_required_value() {
  local prompt_text="$1"
  local validation_message="$2"
  local provided_value=""

  while true; do
    read -r -p "$prompt_text: " provided_value
    provided_value="$(printf '%s' "$provided_value" | xargs)"
    if [[ -n "$provided_value" ]]; then
      printf '%s\n' "$provided_value"
      return 0
    fi

    printf '%s\n' "$validation_message" >&2
  done
}

read_yes_no_value() {
  local prompt_text="$1"
  local default_value="$2"
  local default_token="y/N"
  local raw_response=""
  local normalized_response=""

  if [[ "$default_value" == "yes" ]]; then
    default_token="Y/n"
  fi

  while true; do
    read -r -p "$prompt_text [$default_token]: " raw_response
    normalized_response="$(printf '%s' "$raw_response" | tr '[:upper:]' '[:lower:]' | xargs)"

    if [[ -z "$normalized_response" ]]; then
      printf '%s\n' "$default_value"
      return 0
    fi

    if [[ "$normalized_response" == "y" || "$normalized_response" == "yes" ]]; then
      printf 'yes\n'
      return 0
    fi

    if [[ "$normalized_response" == "n" || "$normalized_response" == "no" ]]; then
      printf 'no\n'
      return 0
    fi

    printf 'Please answer yes or no.\n' >&2
  done
}

read_choice_value() {
  local prompt_text="$1"
  local allowed_values_csv="$2"
  local default_value="$3"
  local raw_response=""
  local normalized_response=""

  while true; do
    read -r -p "$prompt_text [$allowed_values_csv] (default: $default_value): " raw_response
    normalized_response="$(printf '%s' "$raw_response" | tr '[:upper:]' '[:lower:]' | xargs)"

    if [[ -z "$normalized_response" ]]; then
      printf '%s\n' "$default_value"
      return 0
    fi

    IFS='/' read -r -a allowed_values <<< "$allowed_values_csv"
    for allowed_value in "${allowed_values[@]}"; do
      if [[ "$normalized_response" == "$allowed_value" ]]; then
        printf '%s\n' "$normalized_response"
        return 0
      fi
    done

    printf 'Choose one of: %s\n' "$allowed_values_csv" >&2
  done
}

ensure_command_exists() {
  local command_name="$1"
  local install_hint="$2"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf "Required command '%s' was not found. %s\n" "$command_name" "$install_hint" >&2
    exit 1
  fi
}

build_domain_array() {
  local primary_domain="$1"
  local include_www_alias="$2"
  DOMAIN_VALUES=("$primary_domain")

  if [[ "$include_www_alias" == "yes" && "$primary_domain" != www.* ]]; then
    DOMAIN_VALUES+=("www.$primary_domain")
  fi
}

build_http_config() {
  local server_name_value="$1"
  local web_root_path="$2"
  cat <<EOF
server {
    listen 80;
    server_name $server_name_value;

    root $web_root_path;
    index index.html;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|svg|webp|ico)$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
        try_files \$uri =404;
    }
}
EOF
}

build_https_config() {
  local server_name_value="$1"
  local web_root_path="$2"
  local certificate_domain="$3"
  cat <<EOF
server {
    listen 80;
    server_name $server_name_value;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $server_name_value;

    ssl_certificate /etc/letsencrypt/live/$certificate_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$certificate_domain/privkey.pem;

    root $web_root_path;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|svg|webp|ico)$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
        try_files \$uri =404;
    }
}
EOF
}

copy_site_files() {
  local target_web_root="$1"

  mkdir -p "$target_web_root"
  rsync -av --delete \
    --exclude '.git' \
    --exclude '.gitignore' \
    --exclude '.dockerignore' \
    --exclude 'Dockerfile' \
    --exclude 'docker-compose.yml' \
    --exclude 'docker-compose.direct.yml' \
    --exclude 'deploy-direct.sh' \
    --exclude 'deploy-direct.ps1' \
    --exclude 'deploy-simple.sh' \
    --exclude 'nginx.conf' \
    --exclude 'nginx.generated.conf' \
    --exclude 'certbot' \
    "$SCRIPT_DIR/" "$target_web_root/"
}

ensure_command_exists sudo "Install sudo or run this script as a user with sudo access."
ensure_command_exists nginx "Install nginx first."
ensure_command_exists rsync "Install rsync first."

primary_domain="$(read_required_value 'Primary domain (example: example.com)' 'A domain is required.')"
include_www_alias="$(read_yes_no_value 'Also configure the www alias?' 'yes')"
enable_ssl="$(read_yes_no_value "Enable SSL with Let's Encrypt?" 'yes')"
site_name_input="$(read_required_value 'Site config name' 'A site config name is required.')"
site_name="$(printf '%s' "$site_name_input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9_-]/-/g')"
default_web_root="/var/www/$site_name"
web_root="$(read_required_value "Web root path (default example: $default_web_root)" 'A web root path is required.')"

ssl_mode='none'
email_address=''
certificate_domain=''

build_domain_array "$primary_domain" "$include_www_alias"
server_name_value="${DOMAIN_VALUES[*]}"
certificate_domain="${DOMAIN_VALUES[0]}"

if [[ "$enable_ssl" == "yes" ]]; then
  ssl_mode="$(read_choice_value 'SSL mode' 'staging/production' 'staging')"
  email_address="$(read_required_value "Email for Let's Encrypt notices" 'An email address is required for SSL setup.')"
fi

site_config_path="/etc/nginx/sites-available/$site_name.conf"
site_symlink_path="/etc/nginx/sites-enabled/$site_name.conf"
certbot_web_root="/var/www/certbot"
temporary_config_path="$(mktemp)"
temporary_http_config_path="$(mktemp)"

if [[ "$enable_ssl" == "yes" ]]; then
  build_https_config "$server_name_value" "$web_root" "$certificate_domain" > "$temporary_config_path"
  build_http_config "$server_name_value" "$web_root" > "$temporary_http_config_path"
else
  build_http_config "$server_name_value" "$web_root" > "$temporary_config_path"
fi

printf '\nDeployment summary\n'
printf -- '- Site name: %s\n' "$site_name"
printf -- '- Domains: %s\n' "${DOMAIN_VALUES[*]}"
printf -- '- Web root: %s\n' "$web_root"
printf -- '- Nginx config: %s\n' "$site_config_path"
printf -- '- SSL enabled: %s\n' "$enable_ssl"
if [[ "$enable_ssl" == "yes" ]]; then
  printf -- '- SSL mode: %s\n' "$ssl_mode"
  printf -- '- SSL email: %s\n' "$email_address"
fi

printf '\nDNS requirements\n'
printf -- "%s\n" '- Point your domain(s) to this server before enabling the site.'
printf -- '- Use A records for the apex domain and www if enabled.\n\n'

start_now="$(read_yes_no_value 'Copy files and configure nginx now?' 'yes')"
if [[ "$start_now" != "yes" ]]; then
  printf 'Deployment cancelled before changes were applied.\n'
  rm -f "$temporary_config_path"
  rm -f "$temporary_http_config_path"
  exit 0
fi

sudo mkdir -p "$web_root"
copy_site_files "$web_root"

if [[ "$enable_ssl" == "yes" ]]; then
  sudo mkdir -p "$certbot_web_root"
fi

if [[ "$enable_ssl" == "yes" ]]; then
  sudo cp "$temporary_http_config_path" "$site_config_path"
else
  sudo cp "$temporary_config_path" "$site_config_path"
fi
sudo ln -sfn "$site_config_path" "$site_symlink_path"
sudo nginx -t
sudo systemctl reload nginx

if [[ "$enable_ssl" == "yes" ]]; then
  ensure_command_exists certbot "Install certbot first, for example: sudo apt install certbot python3-certbot-nginx"

  certbot_arguments=(
    certonly
    --webroot
    -w "$certbot_web_root"
    --email "$email_address"
    --agree-tos
    --no-eff-email
  )

  if [[ "$ssl_mode" == 'staging' ]]; then
    certbot_arguments+=(--staging)
  fi

  for single_domain in "${DOMAIN_VALUES[@]}"; do
    certbot_arguments+=(-d "$single_domain")
  done

  printf 'Requesting SSL certificates...\n'
  sudo certbot "${certbot_arguments[@]}"

  sudo cp "$temporary_config_path" "$site_config_path"
  sudo nginx -t
  sudo systemctl reload nginx
fi

rm -f "$temporary_config_path"
rm -f "$temporary_http_config_path"

printf '\nSimple deployment completed.\n'
printf 'Your site files are now served from: %s\n' "$web_root"
printf 'Your nginx site config is: %s\n' "$site_config_path"
