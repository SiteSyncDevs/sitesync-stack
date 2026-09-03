#!/usr/bin/env bash
# Saves the database and the site settings into one dated file.
set -euo pipefail

DIR="${BACKUP_DIR:-./backups}"
KEEP="${BACKUP_KEEP:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="${CUSTOMER:-site}-$STAMP"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$DIR"
echo "Backing up the database..."
docker compose exec -T postgres pg_dump -U chirpstack -d chirpstack --clean --if-exists > "$WORK/database.sql"

echo "Backing up the settings..."
cp .env "$WORK/env.txt"
[[ -f mqtt-users.conf ]] && cp mqtt-users.conf "$WORK/mqtt-users.conf"
tar -cf "$WORK/configuration.tar" configuration certs 2>/dev/null || tar -cf "$WORK/configuration.tar" configuration

# Caddy's self-signed certificate authority lives in a Docker volume, not in
# this folder. Without it, a rebuilt machine mints a BRAND NEW authority and
# every browser that trusted the old one starts warning again. Save it.
if [[ "${TLS_MODE:-}" == "self-signed" ]]; then
  if docker compose cp caddy:/data/caddy/pki "$WORK/caddy-pki" >/dev/null 2>&1; then
    echo "Saved the certificate authority, so browsers keep trusting this site after a rebuild."
  else
    echo "Note: could not save the certificate authority (is the site running?)."
    echo "      A restore onto a new machine would need browsers to trust a new certificate."
  fi
fi

tar -czf "$DIR/$NAME.tar.gz" -C "$WORK" .
chmod 600 "$DIR/$NAME.tar.gz" 2>/dev/null || true

echo "Saved $DIR/$NAME.tar.gz"
echo "This file contains passwords. Store it somewhere private."

# Keep only the newest BACKUP_KEEP files.
ls -1t "$DIR"/*.tar.gz 2>/dev/null | tail -n "+$((KEEP+1))" | while read -r old; do
  echo "Removing old backup $(basename "$old")"
  rm -f "$old"
done
