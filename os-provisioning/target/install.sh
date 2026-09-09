#!/usr/bin/env bash
#
# Complete airgap install. On the target Ubuntu Server, run:
#
#     sudo bash install.sh
#
# That is the whole job. It runs the steps in steps/ in order and stops at the
# first real problem, leaving the machine in a state you can re-run from.
#
# WHERE EVERYTHING GOES
#     sudo bash install.sh --install-root /data
#
# One path for the whole install. /data gives:
#     /data/sitesync    the stack        (symlinked from /opt/sitesync)
#     /data/docker      Docker's data-root and containerd's root
#     /data/ignition    the Ignition gateway
#
# Given no path, the installer looks for a second drive and offers it. Answer
# no, or pass --no-install-root, to use the OS disk: /opt/sitesync,
# /var/lib/docker, /usr/local/bin/ignition.
#
# Individual overrides still win over the derived layout:
#     --install-dir DIR   where the stack lives     (default /opt/sitesync)
#     --data-root DIR     where Docker's data lives (default /var/lib/docker)
#     --data-root auto    pick the largest suitable non-root filesystem
#     --ignition-dir DIR  where Ignition goes; without it, step 15 asks
#
# WHICH COMPONENTS
#     --only-docker | --only-chirpstack | --only-ignition   (repeatable)
#     --no-docker   | --no-chirpstack   | --no-ignition
#
#     docker      Docker Engine                       (step 10)
#     chirpstack  images, the stack, site configuration (steps 20, 30, 40)
#     ignition    the Ignition gateway                (step 15)
#
# Preflight and verification always run, narrowed to what was selected.
#
# OTHER OPTIONS
#     --skip-configure    stop after the files are in place; run setup.sh later
#     --resume            carry on from the step that failed last time
#     --redo NN           re-run one step by number, e.g. --redo 20
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
INSTALL_DIR="${INSTALL_DIR:-}"
SKIP_CONFIGURE=0
RESUME=0
REDO=""
IGNITION_DIR="${IGNITION_DIR:-}"
INSTALL_ROOT="${INSTALL_ROOT:-}"
NO_INSTALL_ROOT=0
DATA_ROOT=""
PASSTHRU=()

# Component selection. Empty WANT means "everything that is in the artifact";
# any --only-* narrows it to exactly what was named. --no-* subtracts either
# way, so --no-ignition on its own still installs the other two.
declare -A WANT=() SKIP=()
ONLY=0

want_component() {  # want_component <docker|chirpstack|ignition>
  [[ -z "${SKIP[$1]:-}" ]] || return 1
  (( ONLY )) || return 0
  [[ -n "${WANT[$1]:-}" ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-root)     DATA_ROOT="${2:-}"; shift 2 ;;
    --no-data-root)  DATA_ROOT=none; shift ;;
    --log-max-size)  PASSTHRU+=(--log-max-size "${2:-}"); shift 2 ;;
    --log-max-file)  PASSTHRU+=(--log-max-file "${2:-}"); shift 2 ;;
    --no-log-config) PASSTHRU+=(--no-log-config); shift ;;
    --skip-configure) SKIP_CONFIGURE=1; shift ;;
    --resume)        RESUME=1; shift ;;
    --redo)          REDO="${2:-}"; shift 2 ;;
    --install-dir)   INSTALL_DIR="${2:-}"; shift 2 ;;
    --ignition-dir)  IGNITION_DIR="${2:-}"; shift 2 ;;
    --install-root)  INSTALL_ROOT="${2:-}"; shift 2 ;;
    --no-install-root) NO_INSTALL_ROOT=1; shift ;;
    --only-docker)     ONLY=1; WANT[docker]=1; shift ;;
    --only-chirpstack) ONLY=1; WANT[chirpstack]=1; shift ;;
    --only-ignition)   ONLY=1; WANT[ignition]=1; shift ;;
    --no-docker)     SKIP[docker]=1; shift ;;
    --no-chirpstack) SKIP[chirpstack]=1; shift ;;
    --no-ignition)   SKIP[ignition]=1; shift ;;
    -h|--help)       sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2
       echo "run  bash install.sh --help  for the list" >&2; exit 2 ;;
  esac
done

# A flag that both selects and deselects the same component is a typo, and
# silently honouring one of them would install the wrong set of things.
for _c in docker chirpstack ignition; do
  if [[ -n "${WANT[$_c]:-}" && -n "${SKIP[$_c]:-}" ]]; then
    echo "--only-$_c and --no-$_c contradict each other." >&2; exit 2
  fi
done
if (( ONLY )) && [[ ${#WANT[@]} -eq 0 ]]; then
  echo "every --only-* component was also excluded with --no-*; nothing to do." >&2; exit 2
fi

banner() { printf '\n########################################\n# %s\n########################################\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "must run as root:  sudo bash install.sh"

mkdir -p "$STATE_DIR" "$LOG_DIR"
LOG="$LOG_DIR/install-$(date -u +%Y%m%d-%H%M%S).log"

# Everything the tech sees is also written to one file. When they call you, the
# only thing you need to ask for is this path.
exec > >(tee -a "$LOG") 2>&1
echo "Log: $LOG"

# --------------------------------------------------------- where it all goes --
# One question decides three locations. Asked here, before any work, because
# it is the only decision that is expensive to change afterwards -- moving
# Docker's data-root or a configured stack later means downtime.
#
# A drive is offered only when nothing has already answered the question: no
# --install-root, no --no-install-root, and no individual override.
data_candidates() {
  df -PB1 -x tmpfs -x devtmpfs -x squashfs -x overlay -x nfs -x nfs4 -x cifs 2>/dev/null \
    | awk 'NR>1 && $6!="/" && $4>=10737418240 {print $6, $4}' | sort -k2 -rn
}

if [[ -z "$INSTALL_ROOT" ]] && (( ! NO_INSTALL_ROOT )) \
   && [[ -z "$INSTALL_DIR" && -z "$DATA_ROOT" && -z "$IGNITION_DIR" ]]; then
  mapfile -t _cands < <(data_candidates)
  if (( ${#_cands[@]} )) && [[ -r /dev/tty ]]; then
    _mp="${_cands[0]%% *}"; _av="${_cands[0]##* }"
    banner "Where should this be installed?"
    printf '   This machine has a second drive:\n\n'
    for _c in "${_cands[@]}"; do
      printf '     %-28s %d GB free\n' "${_c%% *}" "$(( ${_c##* } / 1073741824 ))"
    done
    printf '\n   Installing everything on %s:\n' "$_mp"
    printf '     stack      %s/sitesync   (also reachable as /opt/sitesync)\n' "$_mp"
    printf '     docker     %s/docker\n' "$_mp"
    printf '     ignition   %s/ignition\n' "$_mp"
    printf '\n   Answering no uses the OS disk instead:\n'
    printf '     /opt/sitesync, /var/lib/docker, /usr/local/bin/ignition\n\n'
    printf '   Install everything on %s? [Y/n]: ' "$_mp"
    read -r _reply < /dev/tty || _reply=""
    if [[ -z "$_reply" || "${_reply,,}" == y* ]]; then
      INSTALL_ROOT="$_mp"
    else
      echo "   using the OS disk"
    fi
  elif (( ${#_cands[@]} )); then
    # No terminal to ask on. Silence must mean the safe, unchanged default.
    echo "note: a second drive was found but there is no terminal to ask on;" >&2
    echo "      installing to the OS disk. Use --install-root to place it." >&2
  fi
fi

# Derive the three locations, letting any individual flag win over the root.
if [[ -n "$INSTALL_ROOT" ]]; then
  [[ "$INSTALL_ROOT" == /* ]] || fail "--install-root must be an absolute path, got: $INSTALL_ROOT"
  INSTALL_ROOT="${INSTALL_ROOT%/}"
  [[ -n "$INSTALL_DIR"  ]] || INSTALL_DIR="$INSTALL_ROOT/sitesync"
  [[ -n "$IGNITION_DIR" ]] || IGNITION_DIR="$INSTALL_ROOT/ignition"
  [[ -n "$DATA_ROOT"    ]] || DATA_ROOT="$INSTALL_ROOT/docker"

  # The Docker installer refuses to relocate onto the root filesystem, because
  # that is what an unmounted drive looks like. Here the path was named on
  # purpose, so the refusal is wrong -- but say plainly that it is not the
  # separate disk it looks like, since that is worth knowing before a failure.
  if [[ "$DATA_ROOT" != none ]]; then
    _mnt="$(df -P "$INSTALL_ROOT" 2>/dev/null | awk 'NR==2{print $6}')" || _mnt=""
    if [[ "$_mnt" == "/" ]]; then
      echo
      echo "   note: $INSTALL_ROOT is a directory on the OS disk, not a separate drive."
      echo "         Installing there anyway, as asked. Docker's data will share"
      echo "         the root filesystem, so watch free space."
      export DATA_ROOT_FORCE=1
    fi
  fi
fi
INSTALL_DIR="${INSTALL_DIR:-/opt/sitesync}"

# The data root reaches the Docker installer as a passthrough flag.
if [[ "$DATA_ROOT" == none ]]; then
  PASSTHRU+=(--no-data-root)
elif [[ -n "$DATA_ROOT" ]]; then
  PASSTHRU+=(--data-root "$DATA_ROOT")
fi

export AIRGAP_HERE="$HERE" AIRGAP_INSTALL_DIR="$INSTALL_DIR"
export AIRGAP_INSTALL_ROOT="$INSTALL_ROOT"
export AIRGAP_PASSTHRU="${PASSTHRU[*]+${PASSTHRU[*]}}"
export AIRGAP_CODENAME AIRGAP_ARCH AIRGAP_MODE
export AIRGAP_DOCKER_TARBALL="${AIRGAP_DOCKER_TARBALL:-}"
export AIRGAP_IMAGE_TARBALL="${AIRGAP_IMAGE_TARBALL:-}"
export AIRGAP_STACK_TARBALL="${AIRGAP_STACK_TARBALL:-}"
export AIRGAP_IGNITION_TARBALL="${AIRGAP_IGNITION_TARBALL:-}"
export AIRGAP_IGNITION_VERSION="${AIRGAP_IGNITION_VERSION:-}"
export AIRGAP_IGNITION_DIR="$IGNITION_DIR"

# --------------------------------------------------------- what will happen --
# Which component each numbered step belongs to. Preflight and verify belong to
# none: they always run, and narrow themselves using the exported selection.
step_component() {  # step_component <NN>
  case "$1" in
    10) echo docker ;;
    15) echo ignition ;;
    20|30|40) echo chirpstack ;;
    *) echo "" ;;
  esac
}

# Tell the steps what was selected. Step 00 needs it so that --only-ignition
# does not demand a working Docker, and step 50 so it does not check a service
# that was never asked for.
DO_DOCKER=0; DO_CHIRPSTACK=0; DO_IGNITION=0
if want_component docker;     then DO_DOCKER=1;     fi
if want_component chirpstack; then DO_CHIRPSTACK=1; fi
if want_component ignition;   then DO_IGNITION=1;   fi
export AIRGAP_DO_DOCKER="$DO_DOCKER"
export AIRGAP_DO_CHIRPSTACK="$DO_CHIRPSTACK"
export AIRGAP_DO_IGNITION="$DO_IGNITION"

if (( ! DO_DOCKER && ! DO_CHIRPSTACK && ! DO_IGNITION )); then
  fail "every component was excluded, so there is nothing to install."
fi

# Installing the stack onto a machine that has no Docker and is not getting any
# produces a directory of files and no running site. Say so now rather than at
# step 20, halfway through.
if (( DO_CHIRPSTACK && ! DO_DOCKER )) && ! command -v docker >/dev/null 2>&1; then
  fail "ChirpStack was selected but Docker is neither installed nor being installed.
        Install Docker too:   sudo bash install.sh
        or only Docker first: sudo bash install.sh --only-docker"
fi

banner "Verifying transfer integrity"
sha256sum -c --quiet SHA256SUMS || fail "checksum mismatch - re-copy the whole folder"
ok "all archives intact"

# Written as plain ifs, not `(( x )) && echo`: under `set -e` that idiom aborts
# the whole installer the moment a component is switched off.
banner "Plan"
if (( DO_DOCKER )); then
  echo "   docker      Docker Engine            -> ${DATA_ROOT:-/var/lib/docker}"
fi
if (( DO_IGNITION )); then
  echo "   ignition    Ignition gateway         -> ${IGNITION_DIR:-(asked during install)}"
fi
if (( DO_CHIRPSTACK )); then
  echo "   chirpstack  images, stack, site      -> $INSTALL_DIR"
fi
for _c in docker chirpstack ignition; do
  if [[ -n "${SKIP[$_c]:-}" ]]; then echo "   (skipping $_c)"; fi
done
if (( ONLY )); then echo "   (only the components named above will be touched)"; fi
echo

mapfile -t STEPS < <(find "$HERE/steps" -maxdepth 1 -name '[0-9][0-9]-*.sh' | sort)
(( ${#STEPS[@]} )) || fail "no steps found in $HERE/steps"

for step in "${STEPS[@]}"; do
  base="$(basename "$step")"
  num="${base%%-*}"
  done_marker="$STATE_DIR/$num.done"

  # A step belonging to a component that was not selected is skipped quietly:
  # the Plan above already said what would be touched, and repeating it per
  # step buries the steps that do run.
  comp="$(step_component "$num")"
  if [[ -n "$comp" ]] && ! want_component "$comp"; then
    continue
  fi

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
    echo "      sudo bash install.sh --resume" >&2
    exit 1
  fi
  touch "$done_marker"
done

# Step 50 has already printed the address and the everyday commands.
banner "All done"
echo "   Full log: $LOG"
