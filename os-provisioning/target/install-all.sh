#!/usr/bin/env bash
#
# Complete airgap install. On the target Ubuntu Server, run:
#
#     sudo bash install-all.sh
#
# That is the whole job. It runs the steps in steps/ in order and stops at the
# first real problem, leaving the machine in a state you can re-run from.
#
# Optional, for a VM with a separate data drive:
#     sudo bash install-all.sh --data-root /mnt/data/docker
#     sudo bash install-all.sh --data-root auto
#
# Other options:
#     --skip-configure    stop after the files are in place; run setup.sh later
#     --resume            carry on from the step that failed last time
#     --redo NN           re-run one step by number, e.g. --redo 20
#     --install-dir DIR   where the stack lives (default /opt/sitesync-chirpstack)
#
# Container log rotation is applied by default (10m x 3 per container).
# Override with --log-max-size / --log-max-file, or skip with --no-log-config.
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
[[ -f AIRGAP_INFO ]] || { echo "AIRGAP_INFO missing - this folder is not a complete artifact" >&2; exit 1; }
. "$HERE/AIRGAP_INFO"

STATE_DIR=/var/lib/sitesync-airgap
LOG_DIR=/var/log/sitesync-airgap
INSTALL_DIR="${INSTALL_DIR:-/opt/sitesync-chirpstack}"
SKIP_CONFIGURE=0
RESUME=0
REDO=""
PASSTHRU=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-root)     PASSTHRU+=(--data-root "${2:-}"); shift 2 ;;
    --no-data-root)  PASSTHRU+=(--no-data-root); shift ;;
    --log-max-size)  PASSTHRU+=(--log-max-size "${2:-}"); shift 2 ;;
    --log-max-file)  PASSTHRU+=(--log-max-file "${2:-}"); shift 2 ;;
    --no-log-config) PASSTHRU+=(--no-log-config); shift ;;
    --skip-configure) SKIP_CONFIGURE=1; shift ;;
    --resume)        RESUME=1; shift ;;
    --redo)          REDO="${2:-}"; shift 2 ;;
    --install-dir)   INSTALL_DIR="${2:-}"; shift 2 ;;
    -h|--help)       sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

banner() { printf '\n########################################\n# %s\n########################################\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "must run as root:  sudo bash install-all.sh"

mkdir -p "$STATE_DIR" "$LOG_DIR"
LOG="$LOG_DIR/install-$(date -u +%Y%m%d-%H%M%S).log"

# Everything the tech sees is also written to one file. When they call you, the
# only thing you need to ask for is this path.
exec > >(tee -a "$LOG") 2>&1
echo "Log: $LOG"

export AIRGAP_HERE="$HERE" AIRGAP_INSTALL_DIR="$INSTALL_DIR"
export AIRGAP_PASSTHRU="${PASSTHRU[*]+${PASSTHRU[*]}}"
export AIRGAP_CODENAME AIRGAP_ARCH AIRGAP_MODE
export AIRGAP_DOCKER_TARBALL="${AIRGAP_DOCKER_TARBALL:-}"
export AIRGAP_IMAGE_TARBALL="${AIRGAP_IMAGE_TARBALL:-}"
export AIRGAP_STACK_TARBALL="${AIRGAP_STACK_TARBALL:-}"

banner "Verifying transfer integrity"
sha256sum -c --quiet SHA256SUMS || fail "checksum mismatch - re-copy the whole folder"
ok "all archives intact"

mapfile -t STEPS < <(find "$HERE/steps" -maxdepth 1 -name '[0-9][0-9]-*.sh' | sort)
(( ${#STEPS[@]} )) || fail "no steps found in $HERE/steps"

for step in "${STEPS[@]}"; do
  base="$(basename "$step")"
  num="${base%%-*}"
  done_marker="$STATE_DIR/$num.done"

  if [[ -n "$REDO" ]]; then
    [[ "$num" == "$REDO" ]] || continue
  elif (( RESUME )) && [[ -f "$done_marker" ]]; then
    ok "step $num already completed - skipping (use --redo $num to force)"
    continue
  fi

  if [[ "$num" == 40 ]] && (( SKIP_CONFIGURE )); then
    banner "Skipping site configuration (--skip-configure)"
    echo "   When you are ready:  cd $INSTALL_DIR && sudo bash setup.sh"
    continue
  fi

  if ! bash "$step"; then
    echo
    echo "########################################" >&2
    echo "# Step $num failed: $base" >&2
    echo "########################################" >&2
    echo "  Nothing after this step was attempted." >&2
    echo "  The full log is at: $LOG" >&2
    echo "  Once the cause is fixed, carry on with:" >&2
    echo "      sudo bash install-all.sh --resume" >&2
    exit 1
  fi
  touch "$done_marker"
done

# Step 50 has already printed the address and the everyday commands.
banner "All done"
echo "   Full log: $LOG"
