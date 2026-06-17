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
      if [[ "$default_value" == "yes" ]]; then
        printf 'yes\n'
      else
        printf 'no\n'
      fi
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
  local allowed_display="$allowed_values_csv"

  while true; do
    read -r -p "$prompt_text [$allowed_display] (default: $default_value): " raw_response
    normalized_response="$(printf '%s' "$raw_response" | tr '[:upper:]' '[:lower:]' | xargs)"

    if [[ -z "$normalized_response" ]]; then
      printf '%s\n' "$default_value"
      return 0
    fi

    IFS='/' read -r -a allowed_values <<< "$allowed_values_csv"
    for single_allowed_value in "${allowed_values[@]}"; do
      if [[ "$normalized_response" == "$single_allowed_value" ]]; then
        printf '%s\n' "$normalized_response"
        return 0
      fi
    done

    printf 'Choose one of: %s\n' "$allowed_display" >&2
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

build_http_only_config() {
  local server_name_value="$1"
  cat <<EOF
server {
    listen 80;
    server_name $server_name_value;

    root /usr/share/nginx/html;
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

build_https_config() {
  local server_name_value="$1"
  local certificate_domain="$2"
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

    root /usr/share/nginx/html;
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

build_compose_file() {
  local project_name="$1"
  local http_port="$2"
  local enable_ssl="$3"
  local expose_https_port="$4"

  cat <<EOF
services:
  $project_name:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: $project_name
    ports:
      - "$http_port:80"
EOF

  if [[ "$enable_ssl" == "yes" && "$expose_https_port" == "yes" ]]; then
    cat <<EOF
      - "443:443"
    volumes:
      - ./nginx.generated.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certbot/www:/var/www/certbot
      - ./certbot/conf:/etc/letsencrypt
EOF
  elif [[ "$enable_ssl" == "yes" ]]; then
    cat <<EOF
    volumes:
      - ./nginx.generated.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certbot/www:/var/www/certbot
      - ./certbot/conf:/etc/letsencrypt
EOF
  else
    cat <<EOF
    volumes:
      - ./nginx.generated.conf:/etc/nginx/conf.d/default.conf:ro
EOF
  fi

  cat <<EOF
    restart: unless-stopped
EOF
}

ensure_command_exists docker "Install Docker Engine and the Docker Compose plugin first."

project_name_input="$(read_required_value 'Container/project name' 'A project name is required.')"
project_name="$(printf '%s' "$project_name_input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9_-]/-/g')"
primary_domain="$(read_required_value 'Primary domain (example: example.com)' 'A domain is required.')"
include_www_alias="$(read_yes_no_value 'Also configure the www alias?' 'yes')"
enable_ssl="$(read_yes_no_value "Enable SSL with Let's Encrypt?" 'yes')"
http_port="$(read_required_value 'Host HTTP port to expose' 'A host port is required.')"

ssl_mode='none'
email_address=''
staging_certificates='no'
expose_https_port='no'

if [[ "$enable_ssl" == "yes" ]]; then
  ssl_mode="$(read_choice_value 'SSL mode' 'staging/production' 'staging')"
  email_address="$(read_required_value "Email for Let's Encrypt notices" 'An email address is required for SSL setup.')"
  expose_https_port="$(read_yes_no_value 'Bind host port 443 directly in Docker?' 'no')"
  if [[ "$ssl_mode" == 'staging' ]]; then
    staging_certificates='yes'
  fi
fi

build_domain_array "$primary_domain" "$include_www_alias"
server_name_value="${DOMAIN_VALUES[*]}"
certificate_domain="${DOMAIN_VALUES[0]}"
generated_nginx_path="$SCRIPT_DIR/nginx.generated.conf"
generated_compose_path="$SCRIPT_DIR/docker-compose.direct.yml"

if [[ "$enable_ssl" == "yes" ]]; then
  mkdir -p "$SCRIPT_DIR/certbot/www" "$SCRIPT_DIR/certbot/conf"
  build_https_config "$server_name_value" "$certificate_domain" > "$generated_nginx_path"
else
  build_http_only_config "$server_name_value" > "$generated_nginx_path"
fi

build_compose_file "$project_name" "$http_port" "$enable_ssl" "$expose_https_port" > "$generated_compose_path"

printf '\nDeployment summary\n'
printf -- '- Project name: %s\n' "$project_name"
printf -- '- Domains: %s\n' "${DOMAIN_VALUES[*]}"
printf -- '- HTTP port: %s\n' "$http_port"
printf -- '- SSL enabled: %s\n' "$enable_ssl"
if [[ "$enable_ssl" == "yes" ]]; then
  printf -- '- SSL mode: %s\n' "$ssl_mode"
  printf -- '- SSL email: %s\n' "$email_address"
  printf -- '- Bind host 443: %s\n' "$expose_https_port"
fi

printf '\nDNS requirements\n'
printf -- "%s\n" '- Point your domain(s) to this server before requesting SSL certificates.'
printf -- '- Use A records for the apex domain and www if enabled.\n\n'

start_now="$(read_yes_no_value 'Generate files and start deployment now?' 'yes')"
if [[ "$start_now" != "yes" ]]; then
  printf 'Generated files are ready. Start deployment later with docker compose -f docker-compose.direct.yml up -d --build\n'
  exit 0
fi

docker compose -f "$generated_compose_path" up -d --build

if [[ "$enable_ssl" == "yes" ]]; then
  certbot_command=(
    docker run --rm
    -v "$SCRIPT_DIR/certbot/conf:/etc/letsencrypt"
    -v "$SCRIPT_DIR/certbot/www:/var/www/certbot"
    certbot/certbot certonly --webroot -w /var/www/certbot
  )

  if [[ "$staging_certificates" == "yes" ]]; then
    certbot_command+=(--staging)
  fi

  certbot_command+=(--email "$email_address" --agree-tos --no-eff-email)

  for single_domain in "${DOMAIN_VALUES[@]}"; do
    certbot_command+=(-d "$single_domain")
  done

  printf 'Requesting SSL certificates...\n'
  "${certbot_command[@]}"

  printf 'Restarting nginx with SSL config...\n'
  docker compose -f "$generated_compose_path" restart
fi

printf '\nDirect deployment completed.\n'
if [[ "$enable_ssl" == "yes" && "$expose_https_port" != "yes" ]]; then
  printf 'HTTPS was not bound on host port 443. Use your existing reverse proxy to terminate SSL and forward traffic to port %s.\n' "$http_port"
fi
printf 'Use this compose file for future updates: %s\n' "$generated_compose_path"
