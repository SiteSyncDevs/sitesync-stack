#!/usr/bin/env bash
# Makes this site start automatically when the machine boots.
# Run with:  sudo bash systemd/install.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$DIR/.env" ]] || { echo "Run setup.sh first -- there is no .env yet." >&2; exit 1; }
. "$DIR/.env"

NAME="sitesync-chirpstack-${CUSTOMER:-site}"
UNIT="/etc/systemd/system/${NAME}.service"

sed -e "s#__DIR__#$DIR#g" -e "s#__LABEL__#${SITE_LABEL:-$CUSTOMER}#g" \
  "$DIR/systemd/sitesync-chirpstack.service" > "$UNIT"

systemctl daemon-reload
systemctl enable "$NAME"

echo "Installed as $NAME."
echo "It will now start on boot. Useful commands:"
echo "  sudo systemctl status  $NAME"
echo "  sudo systemctl restart $NAME"
echo "  sudo systemctl disable $NAME     (stop starting on boot)"
