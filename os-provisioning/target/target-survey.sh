#!/usr/bin/env bash
#
# target-survey.sh
#
# READ-ONLY survey of a target box. Changes nothing, installs nothing, needs no
# network. Run it on the customer VM BEFORE you build the bundle, so the bundle
# you build is the one that box can actually use.
#
#   bash target-survey.sh                    # human-readable report
#   bash target-survey.sh -o survey.txt      # also write a machine-readable file
#
# Then, on the build host:
#   ./prepare-airgap.sh --from-survey survey.txt
#
# Exit: 0 = usable (warnings allowed), 1 = blocker found, 2 = bad usage.
#
# This is NOT a replacement for the checks inside install.sh. Those run at the
# moment of install and guard against the box having changed since the survey.
# This one answers a different question: "what do we need to bring?"

set -uo pipefail   # deliberately NOT -e: a survey reports problems, it doesn't abort on them

OUTFILE=""
BUNDLE_TARGET_CODENAME="noble"
BUNDLE_TARGET_ARCH="amd64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out) OUTFILE="$2"; shift 2 ;;
    --expect) BUNDLE_TARGET_CODENAME="$2"; shift 2 ;;
    -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

BLOCKERS=(); WARNINGS=(); FACTS=()

fact()  { FACTS+=("$(printf '%-22s %s' "$1" "$2")"); }
block() { BLOCKERS+=("$1"); }
warn()  { WARNINGS+=("$1"); }

# ------------------------------------------------------------------ os -------
OS_ID=""; CODENAME=""; PRETTY=""
if [[ -r /etc/os-release ]]; then
  OS_ID="$(. /etc/os-release && echo "${ID:-}")"
  CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
  PRETTY="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
fi
fact "OS" "${PRETTY:-unknown}"
fact "Codename" "${CODENAME:-unknown}"

if [[ "$OS_ID" != ubuntu ]]; then
  block "not Ubuntu (ID=${OS_ID:-unknown}) - these bundles target Ubuntu Server"
elif [[ -z "$CODENAME" ]]; then
  block "cannot determine Ubuntu codename - /etc/os-release is incomplete"
elif [[ "$CODENAME" != "$BUNDLE_TARGET_CODENAME" ]]; then
  warn "runs '$CODENAME', not '$BUNDLE_TARGET_CODENAME' - build with: --codename $CODENAME"
fi

# ---------------------------------------------------------------- arch -------
ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
fact "Architecture" "$ARCH"
case "$ARCH" in
  amd64|arm64|armhf) [[ "$ARCH" != "$BUNDLE_TARGET_ARCH" ]] && warn "arch is $ARCH - build with: --arch $ARCH" ;;
  *) block "unsupported architecture '$ARCH' - Docker publishes amd64, arm64, armhf" ;;
esac

# -------------------------------------------------------------- systemd ------
if [[ -d /run/systemd/system ]]; then
  fact "Init" "systemd"
else
  block "no systemd - the installer enables docker.service, which needs it (container/WSL?)"
fi

# ------------------------------------------------------------ conflicts ------
CONFLICTS=()
for c in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  dpkg -s "$c" >/dev/null 2>&1 && CONFLICTS+=("$c")
done
if (( ${#CONFLICTS[@]} )); then
  block "conflicting packages installed: ${CONFLICTS[*]}
              remove before installing:  sudo apt-get remove -y ${CONFLICTS[*]}"
else
  fact "Conflicting pkgs" "none"
fi
if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
  block "the 'docker' snap is installed - sudo snap remove docker"
fi

# ------------------------------------------------------- existing docker -----
if command -v docker >/dev/null 2>&1; then
  DV="$(docker --version 2>/dev/null || echo 'present, version unknown')"
  fact "Docker" "$DV"
  if docker info >/dev/null 2>&1; then
    fact "Docker daemon" "running"
    warn "Docker is already installed and running - an --images-only update may be all you need"
    n="$(docker ps -q 2>/dev/null | wc -l)"
    fact "Running containers" "$n"
    if docker ps --format '{{.Image}}' 2>/dev/null | grep -qi chirpstack; then
      warn "ChirpStack containers are already running - capture the current images.pinned before updating"
    fi
  else
    fact "Docker daemon" "installed but not running"
  fi
else
  fact "Docker" "not installed"
fi

# ---------------------------------------------------------------- disk -------
# Docker's data lives under /var/lib/docker. Check the filesystem that will
# actually hold it, not just /.
DPATH=/var/lib
[[ -d /var/lib/docker ]] && DPATH=/var/lib/docker
FREE_B="$(df -PB1 "$DPATH" 2>/dev/null | awk 'NR==2{print $4}')"
FREE_B="${FREE_B:-0}"
FREE_GB=$(( FREE_B / 1073741824 ))
MNT="$(df -P "$DPATH" 2>/dev/null | awk 'NR==2{print $6}')"
fact "Free space" "${FREE_GB} GB on ${MNT:-?} (holds /var/lib/docker)"
# engine installed ~0.6 GB, chirpstack images ~1.5 GB loaded, plus postgres growth
if (( FREE_GB < 5 )); then
  block "only ${FREE_GB} GB free on ${MNT:-?} - engine plus images needs ~3 GB, and postgres grows"
elif (( FREE_GB < 10 )); then
  warn "${FREE_GB} GB free - workable but tight once postgres and image updates accumulate"
fi

# --------------------------------------------------------- data drives ------
# A customer asking for "app data on the data drive" needs a drive that
# overlay2 can actually use. Report every real local filesystem so the layout
# is known before the visit.
printf '%s' "" # (facts appended below)
MOUNTS="$(df -PhT -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{printf "%s %s %s free on %s\n", $2, $1, $5, $7}')"
if [[ -n "$MOUNTS" ]]; then
  n=0
  while read -r line; do
    [[ -z "$line" ]] && continue
    n=$((n+1)); fact "Filesystem $n" "$line"
  done <<< "$MOUNTS"
fi
# overlay2 cannot use xfs formatted with ftype=0, and cannot use NFS at all.
while read -r fstype target; do
  [[ -z "${fstype:-}" ]] && continue
  case "$fstype" in
    nfs|nfs4|cifs) warn "$target is $fstype - Docker's data-root cannot live on a network filesystem" ;;
    xfs) if command -v xfs_info >/dev/null 2>&1; then
           xfs_info "$target" 2>/dev/null | grep -q 'ftype=1' \
             || warn "$target is xfs with ftype=0 - overlay2 will refuse it; needs reformat with -n ftype=1"
         fi ;;
  esac
done < <(df -PT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | awk 'NR>1{print $2, $7}')

# ------------------------------------------------- unused block devices -----
# Detection and guidance only. This script never partitions or formats
# anything: picking the wrong device is unrecoverable, and device names are not
# stable across reboots or hardware changes.
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || echo)"
ROOT_DISK="$(lsblk -nro PKNAME "$ROOT_SRC" 2>/dev/null | head -1)"
[[ -z "$ROOT_DISK" ]] && ROOT_DISK="$(basename "${ROOT_SRC:-none}")"
RAW=()
while read -r name size type; do
  [[ "$type" == disk ]] || continue
  [[ "$name" == "$ROOT_DISK" || "$name" == zram* || "$name" == loop* || "$name" == sr* ]] && continue
  [[ "$size" == 0B ]] && continue
  # a disk with no partitions, no filesystem signature and nothing mounted
  kids="$(lsblk -nro NAME "/dev/$name" 2>/dev/null | wc -l)"
  fst="$(lsblk -nro FSTYPE "/dev/$name" 2>/dev/null | tr -d ' \n')"
  mnt="$(lsblk -nro MOUNTPOINTS "/dev/$name" 2>/dev/null | tr -d ' \n')"
  if (( kids <= 1 )) && [[ -z "$fst" && -z "$mnt" ]]; then
    RAW+=("$name $size"); fact "Unused disk" "/dev/$name ($size) - no filesystem, not mounted"
  fi
done < <(lsblk -dnro NAME,SIZE,TYPE 2>/dev/null)

if (( ${#RAW[@]} )); then
  warn "${#RAW[@]} unused disk(s) present but not set up. Docker cannot use a disk
              that is not partitioned, formatted and mounted. See SETUP below."
fi

# ----------------------------------------------------------------- ram -------
MEM_KB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
MEM_MB=$(( ${MEM_KB:-0} / 1024 ))
CPUS="$(nproc 2>/dev/null || echo '?')"
fact "Memory / CPUs" "${MEM_MB} MB / ${CPUS}"
(( MEM_MB < 1800 )) && warn "${MEM_MB} MB RAM - the full stack (chirpstack, postgres, redis, mosquitto) wants 2 GB+"

# -------------------------------------------------------------- kernel ------
fact "Kernel" "$(uname -r 2>/dev/null || echo unknown)"
if grep -qw overlay /proc/filesystems 2>/dev/null || [[ -d /sys/module/overlay ]]; then
  fact "overlayfs" "available"
else
  warn "overlayfs not detected - Docker will fall back to a slower storage driver"
fi
CG="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
case "$CG" in
  cgroup2fs) fact "cgroups" "v2" ;;
  tmpfs)     fact "cgroups" "v1"; warn "cgroup v1 - supported but deprecated upstream" ;;
  *)         fact "cgroups" "$CG" ;;
esac

# ---------------------------------------------------------------- time -------
fact "Time (UTC)" "$(date -u '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
if command -v timedatectl >/dev/null 2>&1; then
  SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  fact "NTP synced" "$SYNC"
  [[ "$SYNC" == no ]] && warn "clock not NTP-synced - postgres timestamps and TLS to the broker both care"
fi

# ------------------------------------------------------------- network ------
# Worth knowing: if this box actually has egress, the whole airgap dance may be
# unnecessary.
NET="no egress detected"
if timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null; then
  NET="TCP egress works"
  warn "this box appears to have internet access - confirm an offline install is actually required"
elif timeout 3 getent hosts download.docker.com >/dev/null 2>&1; then
  NET="DNS resolves but no TCP"
fi
fact "Network" "$NET"

# --------------------------------------------------------------- report ------
printf '\n=== Target survey: %s ===\n' "$(hostname 2>/dev/null || echo unknown)"
printf '%s\n' "${FACTS[@]}" | sed 's/^/  /'

if (( ${#BLOCKERS[@]} )); then
  printf '\nBLOCKERS (install will not succeed until these are fixed)\n'
  printf '  [X] %s\n' "${BLOCKERS[@]}"
fi
if (( ${#WARNINGS[@]} )); then
  printf '\nWARNINGS (proceed, but know about these)\n'
  printf '  [!] %s\n' "${WARNINGS[@]}"
fi

if (( ${#BLOCKERS[@]} )); then
  VERDICT="BLOCKED"
  printf '\nVERDICT: BLOCKED - %d blocker(s). Fix them, then re-run this survey.\n' "${#BLOCKERS[@]}"
elif (( ${#WARNINGS[@]} )); then
  VERDICT="OK_WITH_WARNINGS"
  printf '\nVERDICT: OK with %d warning(s).\n' "${#WARNINGS[@]}"
else
  VERDICT="OK"
  printf '\nVERDICT: OK.\n'
fi

printf '\nBuild the matching bundle with:\n  ./prepare-airgap.sh --latest --codename %s --arch %s\n' \
  "${CODENAME:-noble}" "${ARCH:-amd64}"

if (( ${#RAW[@]} )); then
  d="${RAW[0]%% *}"; sz="${RAW[0]##* }"
  cat <<SETUP

SETUP FOR THE UNUSED DISK  /dev/$d ($sz)
------------------------------------------------------------------
Whoever administers this VM should run these, having FIRST confirmed with
'lsblk' that /dev/$d is the intended empty data disk. mkfs destroys whatever
is on the device it is pointed at, and there is no undo.

    sudo parted -s /dev/$d mklabel gpt
    sudo parted -s -a opt /dev/$d mkpart data ext4 0% 100%
    sudo mkfs.ext4 -L data /dev/${d}1
    sudo mkdir -p /mnt/data
    echo "UUID=\$(sudo blkid -s UUID -o value /dev/${d}1)  /mnt/data  ext4  defaults,nofail  0 2" \\
      | sudo tee -a /etc/fstab
    sudo systemctl daemon-reload && sudo mount -a
    findmnt /mnt/data          # must show the mount before you install

Two details that matter:
  - fstab uses UUID, not /dev/${d}1. Device names reorder when disks are
    added or removed; UUIDs do not.
  - 'nofail' means a missing disk still lets the machine boot, so you can log
    in and fix it. The installer's own mount check then stops Docker from
    starting on the OS drive by mistake.

Then install with:
    sudo bash install.sh --data-root /mnt/data/docker
SETUP
fi

# ---------------------------------------------------------- machine file -----
if [[ -n "$OUTFILE" ]]; then
  {
    printf 'SURVEY_DATE=%s\n'      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'SURVEY_HOST=%s\n'      "$(hostname 2>/dev/null || echo unknown)"
    printf 'SURVEY_OS=%s\n'        "${PRETTY:-unknown}"
    printf 'SURVEY_CODENAME=%s\n'  "${CODENAME:-unknown}"
    printf 'SURVEY_ARCH=%s\n'      "${ARCH:-unknown}"
    printf 'SURVEY_FREE_GB=%s\n'   "$FREE_GB"
    printf 'SURVEY_DATA_CANDIDATE=%s\n' "$(df -PB1 -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null \
        | awk 'NR>1 && $6!="/" {print $4, $6}' | sort -rn | head -1 | awk '{print $2}')"
    printf 'SURVEY_MEM_MB=%s\n'    "$MEM_MB"
    printf 'SURVEY_DOCKER=%s\n'    "$(command -v docker >/dev/null 2>&1 && echo present || echo absent)"
    printf 'SURVEY_VERDICT=%s\n'   "$VERDICT"
    printf 'SURVEY_BLOCKERS=%s\n'  "${#BLOCKERS[@]}"
    printf 'SURVEY_WARNINGS=%s\n'  "${#WARNINGS[@]}"
  } > "$OUTFILE"
  printf '\nMachine-readable survey written to %s - send this back before the visit.\n' "$OUTFILE"
fi

(( ${#BLOCKERS[@]} )) && exit 1
exit 0
