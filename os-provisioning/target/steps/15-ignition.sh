#!/usr/bin/env bash
# Installs the Ignition gateway on the metal -- not in a container -- from the
# vendor installer carried in this artifact.
#
# It runs here, after Docker and before the images, for one reason: Ignition is
# the long pole. It takes minutes and it is the step most likely to need a
# human. Finding that out before spending time loading images means a failure
# costs the tech less, and --resume picks up exactly where it stopped.
set -Eeuo pipefail
banner() { printf '\n########################################\n# %s\n########################################\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
warn() { printf '   [ note ] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
cd "$AIRGAP_HERE"

if [[ -z "${AIRGAP_IGNITION_TARBALL:-}" ]]; then
  banner "Step 15: Ignition - none in this artifact"
  exit 0
fi

banner "Step 15: Ignition ${AIRGAP_IGNITION_VERSION:-} (bare metal)"

d="${AIRGAP_IGNITION_TARBALL%.tar.gz}"
[[ -d "$d" ]] || tar xzf "$AIRGAP_IGNITION_TARBALL"
[[ -f "$d/install.sh" ]] || fail "$AIRGAP_IGNITION_TARBALL did not unpack into $d/install.sh"

# --------------------------------------------------------------- location ---
# The installer offers a choice of directory, so the tech gets that choice
# here. Anywhere else it would be a flag nobody remembers; this is the one
# moment they are looking at the screen and thinking about this machine.
#
# The default is the installer's own, so doing nothing gives exactly what the
# vendor's own installer gives. --ignition-dir wins over the prompt, so an
# unattended or scripted run is still fully determined.
DEFAULT_LOCATION="/usr/local/bin/ignition"
LOCATION="${AIRGAP_IGNITION_DIR:-}"

if [[ -z "$LOCATION" ]]; then
  if [[ -r /dev/tty ]]; then
    echo
    echo "   Where should Ignition be installed?"
    echo "   Press Enter for the default, or type a full path."
    echo
    printf '   Location [%s]: ' "$DEFAULT_LOCATION"
    read -r answer < /dev/tty || answer=""
    LOCATION="${answer:-$DEFAULT_LOCATION}"
  else
    # No terminal: an automated run. Silence means the default, not a hang.
    LOCATION="$DEFAULT_LOCATION"
    warn "no terminal to ask on; using the default location"
  fi
fi

case "$LOCATION" in
  /*) : ;;
  *)  fail "the install location must be an absolute path, not '$LOCATION'" ;;
esac
ok "installing to $LOCATION"

# --- room to put it ----------------------------------------------------------
# The unpacked gateway is several times the size of the installer, and running
# out of disk halfway through leaves a corrupt install that the uninstaller
# then has to clean up. Check first.
need_mb=4096
parent="$LOCATION"
while [[ ! -d "$parent" && "$parent" != / ]]; do parent="$(dirname "$parent")"; done
free_mb=$(df -Pm "$parent" 2>/dev/null | awk 'NR==2{print $4}')
if [[ -n "${free_mb:-}" ]] && (( free_mb < need_mb )); then
  fail "only ${free_mb} MB free on $parent, and Ignition needs about ${need_mb} MB.
        Free some space, or choose a location on a bigger disk."
fi

# --- install -----------------------------------------------------------------
# Ownership follows the same rule as the stack: the person who ran sudo should
# be able to read the logs and edit the config afterwards.
OWNER="${SUDO_USER:-root}"
args=(--location "$LOCATION")
[[ "$OWNER" != root ]] && id "$OWNER" >/dev/null 2>&1 && args+=(--user "$OWNER")

bash "$d/install.sh" "${args[@]}" \
  || fail "the Ignition install failed (see above). Nothing after this step was attempted."

# --- prove it is actually serving --------------------------------------------
# "The installer exited 0" is not the same as "there is a gateway". 8.1 has
# shipped releases where the service silently never gets created, so the
# gateway works until the first reboot and then does not.
. /var/lib/sitesync-airgap/ignition.info 2>/dev/null || true
UNIT="${IGNITION_SERVICE_UNIT:-}"

if [[ -n "$UNIT" ]]; then
  systemctl is-enabled --quiet "$UNIT" 2>/dev/null \
    && ok "$UNIT is enabled at boot" \
    || warn "$UNIT exists but is NOT enabled at boot - it will not survive a power cut"
else
  warn "no systemd unit was created for Ignition (a known 8.1 installer defect)."
  warn "the gateway can be started by hand with:"
  warn "    sudo $LOCATION/ignition.sh start"
  warn "but it will not come back after a reboot. Worth fixing before you leave."
fi

# The gateway takes a while to open its port on a cold first start; it is
# unpacking modules. Wait rather than declaring failure at second one.
GW_PORT=8088
printf '   waiting for the gateway to answer on port %s ' "$GW_PORT"
up=0
for _ in $(seq 1 60); do
  if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$GW_PORT" 2>/dev/null | grep -q .; then
    up=1; break
  fi
  printf '.'; sleep 5
done
echo

if (( up )); then
  ok "Ignition ${IGNITION_VERSION:-} is listening on port $GW_PORT"
else
  # Not fatal. The files are installed and the service exists; a gateway that
  # is slow to start is a thing to look at, not a reason to abandon an install
  # and leave the machine half-provisioned.
  warn "the gateway is not answering on port $GW_PORT yet."
  warn "it is installed at $LOCATION. Check on it with:"
  [[ -n "$UNIT" ]] && warn "    sudo systemctl status $UNIT"
  warn "    sudo tail -50 $LOCATION/logs/wrapper.log"
fi
