#!/usr/bin/env bash
# Puts a backup back. Asks before it overwrites anything.
set -euo pipefail

FILE="${1:-}"
if [[ -z "$FILE" ]]; then
  echo "Which backup? For example:"
  ls -1t "${BACKUP_DIR:-./backups}"/*.tar.gz 2>/dev/null | head -5 | sed 's/^/  .\/sitesync restore /'
  exit 1
fi
[[ -f "$FILE" ]] || { echo "No such file: $FILE" >&2; exit 1; }

echo
echo "This will REPLACE the current database with the contents of:"
echo "  $FILE"
echo "The current database will be lost."
read -r -p "Type the word RESTORE to continue: " answer
[[ "$answer" == "RESTORE" ]] || { echo "Nothing was changed."; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
tar -xzf "$FILE" -C "$WORK"

echo "Making a safety copy of the current state first..."
bash scripts/backup.sh || echo "(could not make a safety copy -- continuing anyway)"

echo "Restoring the database..."
docker compose up -d postgres
until docker compose exec -T postgres pg_isready -U chirpstack -d chirpstack >/dev/null 2>&1; do sleep 1; done
docker compose exec -T postgres psql -U chirpstack -d chirpstack < "$WORK/database.sql" >/dev/null

echo
echo "Database restored."
echo "The settings from that backup are in $WORK/env.txt but were NOT applied,"
echo "because .env may have changed on purpose since then. Compare them yourself"
echo "if you need to, then run: ./sitesync apply"
cp "$WORK/env.txt" "./restored-env-$(date +%Y%m%d-%H%M%S).txt"
echo "A copy was left in this folder for you to compare."
