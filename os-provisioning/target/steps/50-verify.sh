#!/usr/bin/env bash
# Confirms the result and tells the tech exactly what they have.
set -Eeuo pipefail
banner() { printf '\n########################################\n# %s\n########################################\n' "$*"; }
DEST="${AIRGAP_INSTALL_DIR:-/opt/sitesync}"
SUMMARY_ONLY=0
[[ "${1:-}" == "--summary-only" ]] && SUMMARY_ONLY=1

if (( ! SUMMARY_ONLY )); then
  banner "Step 50: checking the result"
fi

# --- Ignition ----------------------------------------------------------------
# Reported before the ChirpStack summary and independently of it: the gateway
# is a separate product on the same box, and it is installed even when the
# ChirpStack side of the install was skipped or is not configured yet.
if [[ -f /var/lib/sitesync-airgap/ignition.info ]]; then
  # shellcheck disable=SC1091
  . /var/lib/sitesync-airgap/ignition.info
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  state="not responding"
  if command -v ss >/dev/null 2>&1 && ss -ltnH 'sport = :8088' 2>/dev/null | grep -q .; then
    state="running"
  fi
  cat <<TXT

   Ignition ${IGNITION_VERSION:-} -- ${state}
       http://${IP:-<this machine>}:8088
       installed at ${IGNITION_LOCATION:-unknown}
$( [[ -n "${IGNITION_SERVICE_UNIT:-}" ]] \
     && printf '       service: %s\n' "$IGNITION_SERVICE_UNIT" \
     || printf '       NO systemd service - it will not start after a reboot\n' )

   The first visit to that address runs the commissioning wizard, where you
   set the admin password. Until that is done, anyone on the network can.

TXT
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
