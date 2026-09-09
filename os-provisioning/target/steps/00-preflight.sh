#!/usr/bin/env bash
# Checks everything BEFORE anything is installed or changed.
# A failure here leaves the machine exactly as it was found.
set -Eeuo pipefail
banner() { printf '\n########################################\n# %s\n########################################\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
warn() { printf '   [ note ] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

banner "Step 00: checking this machine before changing anything"

# What was actually selected. Unset means a full install, which is what a
# direct run of this step (outside install.sh) should assume.
DO_DOCKER="${AIRGAP_DO_DOCKER:-1}"
DO_CHIRPSTACK="${AIRGAP_DO_CHIRPSTACK:-1}"
DO_IGNITION="${AIRGAP_DO_IGNITION:-1}"

# --- operating system --------------------------------------------------------
. /etc/os-release 2>/dev/null || fail "cannot read /etc/os-release - is this Ubuntu?"
HOST_CODENAME="${VERSION_CODENAME:-unknown}"
HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"

if [[ -n "${AIRGAP_CODENAME:-}" && "$HOST_CODENAME" != "$AIRGAP_CODENAME" ]]; then
  if [[ "${FORCE:-0}" == 1 ]]; then
    warn "this machine is '$HOST_CODENAME' but the artifact was built for '$AIRGAP_CODENAME' (FORCE=1)"
  else
    fail "this artifact was built for Ubuntu '$AIRGAP_CODENAME' but this machine is '$HOST_CODENAME'.
        The Docker packages will not match. Build an artifact for this release with:
            ./prepare-airgap.sh --latest --codename $HOST_CODENAME
        To override anyway:  sudo FORCE=1 bash install.sh"
  fi
else
  ok "Ubuntu $HOST_CODENAME"
fi

if [[ -n "${AIRGAP_ARCH:-}" && "$HOST_ARCH" != "$AIRGAP_ARCH" ]]; then
  [[ "${FORCE:-0}" == 1 ]] \
    && warn "architecture mismatch: machine is $HOST_ARCH, artifact is $AIRGAP_ARCH (FORCE=1)" \
    || fail "this machine is $HOST_ARCH but the artifact was built for $AIRGAP_ARCH. Nothing here will run."
else
  ok "architecture $HOST_ARCH"
fi

# --- conflicting packages ----------------------------------------------------
# Only when Docker Engine is actually going on. An --only-ignition run has no
# business refusing to proceed because the machine has podman on it.
if (( DO_DOCKER )); then
CONFLICTS=()
for p in docker.io docker-doc docker-compose podman-docker containerd runc; do
  dpkg -l "$p" 2>/dev/null | grep -q '^ii' && CONFLICTS+=("$p")
done
if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
  CONFLICTS+=("docker (snap)")
fi
if (( ${#CONFLICTS[@]} )); then
  fail "these conflict with Docker Engine and must be removed first:
            ${CONFLICTS[*]}
        Remove them with:
            sudo apt-get remove -y ${CONFLICTS[*]}
        (a docker snap is removed with: sudo snap remove docker)"
fi
ok "no conflicting container packages"
fi

# --- an Ignition gateway already here ----------------------------------------
# Step 15 installs, it does not upgrade. Finding an existing gateway now is a
# conversation; finding it after Docker is installed is a half-provisioned box.
if [[ -n "${AIRGAP_IGNITION_TARBALL:-}" ]] && (( DO_IGNITION )); then
  EXISTING=()
  for d in /usr/local/bin/ignition /usr/local/ignition /opt/ignition; do
    [[ -x "$d/ignition.sh" ]] && EXISTING+=("$d")
  done
  # A service by any of the names the installer uses counts too, even if it
  # points somewhere unusual.
  if command -v systemctl >/dev/null 2>&1; then
    while read -r u; do
      [[ -n "$u" ]] && EXISTING+=("service $u")
    done < <(systemctl list-unit-files --no-legend 2>/dev/null \
             | awk '$1 ~ /^([Ii]gnition|.*-Gateway)\.service$/ {print $1}')
  fi
  if (( ${#EXISTING[@]} )); then
    if [[ "${FORCE:-0}" == 1 ]]; then
      warn "an Ignition install is already here: ${EXISTING[*]} (FORCE=1, continuing)"
    else
      fail "Ignition is already installed on this machine:
            ${EXISTING[*]}
        This installer installs, it does not upgrade in place. Either remove
        the existing gateway first:
            sudo bash uninstall.sh
        or build an artifact without it:
            ./prepare-airgap.sh --latest --skip-ignition
        To install alongside it anyway, into a different directory:
            sudo bash install.sh --ignition-dir /opt/ignition-new"
    fi
  else
    ok "no existing Ignition install"
  fi
fi

# --- disk space --------------------------------------------------------------
# Ignition is installed unpacked on the filesystem rather than as images under
# /var/lib, so it is real extra space on top of what the containers need.
need_mb=0
if (( DO_CHIRPSTACK )); then need_mb=$((need_mb + 4096)); fi
if (( DO_IGNITION )) && [[ -n "${AIRGAP_IGNITION_TARBALL:-}" ]]; then
  need_mb=$((need_mb + 4096))
fi
# Check the filesystem this install will actually land on. With --install-root
# that is the chosen drive, and checking /var/lib instead would fail a perfectly
# good install on a box with a small OS disk and a large data drive.
SPACE_PATH=/var/lib
if [[ -n "${AIRGAP_INSTALL_ROOT:-}" ]]; then
  SPACE_PATH="${AIRGAP_INSTALL_ROOT}"
  while [[ ! -d "$SPACE_PATH" && "$SPACE_PATH" != / ]]; do
    SPACE_PATH="$(dirname "$SPACE_PATH")"
  done
fi
free_mb=$(df -Pm "$SPACE_PATH" 2>/dev/null | awk 'NR==2{print $4}')
if [[ -n "${free_mb:-}" ]] && (( free_mb < need_mb )); then
  fail "only ${free_mb} MB free on $SPACE_PATH, and this install needs about ${need_mb} MB.
        Free some space, or install onto a data drive:
            sudo bash install.sh --install-root /data"
fi
ok "disk space: ${free_mb:-unknown} MB free on $SPACE_PATH"

# --- the payload is actually here -------------------------------------------
for var in AIRGAP_DOCKER_TARBALL AIRGAP_IMAGE_TARBALL AIRGAP_STACK_TARBALL AIRGAP_IGNITION_TARBALL; do
  f="${!var:-}"
  [[ -z "$f" ]] && continue
  [[ -f "$AIRGAP_HERE/$f" ]] || fail "$f is named in AIRGAP_INFO but is not in this folder.
        The copy is incomplete - copy the whole folder again."
done
ok "every archive named in AIRGAP_INFO is present"

# --- ports we are about to want ---------------------------------------------
if command -v ss >/dev/null 2>&1; then
  WANT_PORTS=()
  if (( DO_CHIRPSTACK )); then WANT_PORTS+=(80 443 1883); fi
  # Ignition's gateway (8088) and its TLS port (8043). Unlike ChirpStack's,
  # these are not something setup.sh can move later, so a clash here matters
  # more -- but it is still a warning: the tech may be about to stop whatever
  # is holding the port.
  if (( DO_IGNITION )) && [[ -n "${AIRGAP_IGNITION_TARBALL:-}" ]]; then
    WANT_PORTS+=(8088 8043)
  fi
  BUSY=()
  for p in "${WANT_PORTS[@]}"; do
    ss -ltnH "sport = :$p" 2>/dev/null | grep -q . && BUSY+=("$p")
  done
  if (( ${#BUSY[@]} )); then
    warn "port(s) ${BUSY[*]} are already in use by something else on this machine."
    warn "the installer continues; you can move ChirpStack's ports during setup."
    for p in "${BUSY[@]}"; do
      [[ "$p" == 8088 || "$p" == 8043 ]] && \
        warn "  port $p is Ignition's and is NOT configurable during this install."
    done
  else
    ok "ports ${WANT_PORTS[*]} are free"
  fi
fi

# --- systemd -----------------------------------------------------------------
[[ -d /run/systemd/system ]] || fail "this machine is not running systemd. Docker Engine's
        packages expect it, and the stack will not start on boot without it."
ok "systemd present"

echo
ok "Preflight passed - safe to proceed."
