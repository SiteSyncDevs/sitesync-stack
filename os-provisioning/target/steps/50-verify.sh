#!/usr/bin/env bash
# Confirms the result and tells the tech exactly what they have.
set -Eeuo pipefail
banner() { printf '\n########################################\n# %s\n########################################\n' "$*"; }
DEST="${AIRGAP_INSTALL_DIR:-/opt/sitesync-chirpstack}"
SUMMARY_ONLY=0
[[ "${1:-}" == "--summary-only" ]] && SUMMARY_ONLY=1

if (( ! SUMMARY_ONLY )); then
  banner "Step 50: checking the result"
fi

if [[ ! -f "$DEST/.env" ]]; then
  cat <<TXT

   Docker and the container images are installed, and the stack is at:
       $DEST

   This site is not configured yet. Finish with:
       cd $DEST
       sudo bash setup.sh

TXT
  exit 0
fi

cd "$DEST"
bash scripts/doctor.sh || true
./sitesync status 2>/dev/null || true

cat <<TXT

   Everyday commands, from $DEST:
       ./sitesync status      is it running, and what is the address
       ./sitesync doctor      check the settings
       ./sitesync logs        watch what a service is saying
       nano .env              change a setting, then ./sitesync apply

   To have it start automatically after a power cut:
       sudo bash systemd/install.sh

   If the person who ran this install wants to use ./sitesync without sudo,
   they need to log out and back in once, to pick up the docker group.

TXT
