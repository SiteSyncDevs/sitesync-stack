#!/usr/bin/env bash
# Installs Docker Engine from the offline apt repo carried in this artifact,
# or confirms a working Docker if this artifact is an image update only.
set -Eeuo pipefail
banner() { printf '\n########################################\n# %s\n########################################\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
cd "$AIRGAP_HERE"

# shellcheck disable=SC2206
PASSTHRU=(${AIRGAP_PASSTHRU:-})

if [[ -n "${AIRGAP_DOCKER_TARBALL:-}" ]]; then
  banner "Step 10: Docker Engine"
  d="${AIRGAP_DOCKER_TARBALL%.tar.gz}"
  [[ -d "$d" ]] || tar xzf "$AIRGAP_DOCKER_TARBALL"
  bash "$d/install.sh" "${PASSTHRU[@]+"${PASSTHRU[@]}"}" \
    || fail "Docker Engine install failed (see above). Nothing else was attempted."
else
  banner "Step 10: checking Docker is already installed"
  command -v docker >/dev/null || fail "docker is not installed on this machine, and this
        artifact is an image update only. Run the full airgap artifact first."
  docker info >/dev/null 2>&1  || fail "docker is installed but the daemon is not running:
            sudo systemctl start docker"
  ok "$(docker --version)"
fi

docker info >/dev/null 2>&1 || fail "Docker is installed but the daemon is not responding."
ok "Docker daemon is responding"
