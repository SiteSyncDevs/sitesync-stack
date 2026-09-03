#!/usr/bin/env bash
# Moves to newer software, taking a backup first so it can be undone.
set -euo pipefail

echo "Taking a backup before changing anything..."
bash scripts/backup.sh

echo
echo "Downloading newer images..."
docker compose pull

echo
echo "Restarting with the new images..."
docker compose up -d --remove-orphans

echo
echo "Done. Check that everything came back up:"
echo "  ./sitesync status"
echo
echo "If something is broken, the backup taken a moment ago is in ${BACKUP_DIR:-./backups}"
echo "and you can go back by setting the old *_VERSION values in .env, then ./sitesync apply"
