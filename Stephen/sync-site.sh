#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGET_WEB_ROOT="${1:-/var/www/andylanding}"

if ! command -v rsync >/dev/null 2>&1; then
  printf "Required command 'rsync' was not found. Install rsync first.\n" >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  printf "Required command 'sudo' was not found. Run this as a user with sudo access.\n" >&2
  exit 1
fi

printf 'Syncing site files from %s to %s\n' "$SCRIPT_DIR" "$TARGET_WEB_ROOT"

sudo mkdir -p "$TARGET_WEB_ROOT"

sudo rsync -av --delete \
  --exclude '.git' \
  --exclude '.gitignore' \
  --exclude '.dockerignore' \
  --exclude 'Dockerfile' \
  --exclude 'docker-compose.yml' \
  --exclude 'docker-compose.direct.yml' \
  --exclude 'deploy-direct.sh' \
  --exclude 'deploy-direct.ps1' \
  --exclude 'deploy-simple.sh' \
  --exclude 'sync-site.sh' \
  --exclude 'nginx.conf' \
  --exclude 'nginx.generated.conf' \
  --exclude 'certbot' \
  "$SCRIPT_DIR/" "$TARGET_WEB_ROOT/"

printf 'Sync complete. Live site root updated: %s\n' "$TARGET_WEB_ROOT"
