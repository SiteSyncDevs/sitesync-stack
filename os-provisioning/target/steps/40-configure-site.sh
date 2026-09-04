#!/usr/bin/env bash
# Asks the site questions and writes the .env. This is the only interactive step.
set -Eeuo pipefail
banner() { printf '\n########################################\n# %s\n########################################\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

DEST="${AIRGAP_INSTALL_DIR:-/opt/sitesync-chirpstack}"
[[ -f "$DEST/setup.sh" ]] || { echo "   No stack installed at $DEST - nothing to configure."; exit 0; }

banner "Step 40: setting this site up"

if [[ -f "$DEST/.env" ]]; then
  ok "this site is already configured ($DEST/.env exists)"
  echo "   Leaving it untouched. To change any setting later:"
  echo "       cd $DEST && nano .env && ./sitesync apply"
  exit 0
fi

# The wizard needs a real terminal. When there isn't one (an automated build, or
# output piped to a file), skip rather than hang waiting for an answer nobody
# is there to give -- the same trap that made `newgrp docker` freeze installs.
if [[ ! -r /dev/tty ]]; then
  echo "   No terminal available, so the questions cannot be asked here."
  echo "   Finish on the console with:"
  echo "       cd $DEST && sudo bash setup.sh"
  exit 0
fi

cd "$DEST"
export SITESYNC_AIRGAP=1
bash setup.sh < /dev/tty || fail "setup did not complete. You can run it again at any time:
            cd $DEST && sudo bash setup.sh"

# setup.sh hands ownership back itself; re-assert it here so a partial or
# interrupted run still leaves files the operator can read.
OWNER="${SUDO_USER:-root}"
if [[ "$OWNER" != root ]] && id "$OWNER" >/dev/null 2>&1; then
  find "$DEST" -path "$DEST/configuration/mosquitto/config/passwd" -prune -o -print0 2>/dev/null \
    | xargs -0 --no-run-if-empty chown "$OWNER":"$(id -gn "$OWNER")" 2>/dev/null || true
  [[ -f "$DEST/.env" ]] && chmod 600 "$DEST/.env"
  ok "configuration belongs to $OWNER"
fi
