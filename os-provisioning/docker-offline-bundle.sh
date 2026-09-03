#!/usr/bin/env bash
#
# docker-offline-bundle.sh  (v2)
#
# Builds a self-contained, dependency- AND recommends-complete offline installer
# bundle for Docker Engine on Ubuntu Server. Run on ANY internet-connected
# Debian/Ubuntu host; the target Ubuntu release is chosen with --codename and
# does not have to match this host.
#
# The bundle reproduces exactly what
#     apt-get install docker-ce docker-ce-cli containerd.io \
#                     docker-buildx-plugin docker-compose-plugin
# does on a connected machine -- including everything apt pulls in via
# Recommends (docker-ce-rootless-extras, apparmor, git, pigz, procps,
# xz-utils, libltdl7, ca-certificates, and their closures).
#
# Operator's job on the offline server:  sudo bash install.sh
#
# Build host needs: curl, gpg, apt-get, dpkg, tar, gzip, sha256sum, and either
# dpkg-scanpackages (dpkg-dev) or apt-ftparchive (apt-utils). Root not required.

set -Eeuo pipefail

# ---------------------------------------------------------------- defaults ---
# Fleet target: freshly provisioned Ubuntu Server 24.04 (noble) / amd64.
# Deliberately NOT derived from the build host -- deriving it means building a
# jammy bundle from a jammy laptop and only finding out at the customer site.
CODENAME="noble"
ARCH="amd64"
CHANNEL="stable"
OUTDIR=""                # default: ./artifacts
RECOMMENDS=1
ROOTLESS=1
ALL_DOCKER=0
WITH_HELLO=1
DOCKER_VERSION=""
KEEP_WORK=0
EXTRA_PKGS=()
EXTRA_IMAGES=()

usage() {
  cat <<'EOF'
Usage: docker-offline-bundle.sh [options]

  -c, --codename NAME   Target Ubuntu codename (default: noble = 24.04)
                        jammy = 22.04, focal = 20.04, or 'auto' for this host
  -a, --arch ARCH       Target dpkg arch (default: amd64) | arm64 | armhf
      --channel NAME    Docker channel: stable | test (default: stable)
      --version VER     Pin engine version, e.g. 5:27.3.1-1~ubuntu.24.04~noble
                        (applied to docker-ce, -cli and -rootless-extras)

  COMPLETENESS
      --all-docker      Include every package published in the Docker channel
                        (adds docker-model-plugin etc. if present)
      --extra PKG       Add an extra package (repeatable)
      --image REF       Also bundle a container image, loaded at install time
                        (repeatable; needs a working docker on THIS host)
      --no-rootless     Exclude docker-ce-rootless-extras
      --lean            Depends only, skip Recommends. ~25 MB smaller and
                        NOT equivalent to a normal install. Don't use this
                        unless transfer size is genuinely the constraint.
      --no-hello        Skip the hello-world smoke-test image

  -o, --out DIR         Where to write the tarball (default: ./artifacts)
      --keep-work       Leave the scratch APT root for inspection
  -h, --help            This text
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--codename)
      if [[ "$2" == auto ]]; then
        CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
      else CODENAME="$2"; fi
      shift 2 ;;
    -a|--arch)     ARCH="$2"; shift 2 ;;
    --channel)     CHANNEL="$2"; shift 2 ;;
    --version)     DOCKER_VERSION="$2"; shift 2 ;;
    --all-docker)  ALL_DOCKER=1; shift ;;
    --extra)       EXTRA_PKGS+=("$2"); shift 2 ;;
    --image)       EXTRA_IMAGES+=("$2"); shift 2 ;;
    --no-rootless) ROOTLESS=0; shift ;;
    --lean)        RECOMMENDS=0; shift ;;
    --no-hello)    WITH_HELLO=0; shift ;;
    -o|--out)      OUTDIR="$2"; shift 2 ;;
    --keep-work)   KEEP_WORK=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

OUTDIR="${OUTDIR:-$PWD/artifacts}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

# ------------------------------------------------------------- preflight -----
for b in curl gpg apt-get apt-cache dpkg tar gzip sha256sum; do
  command -v "$b" >/dev/null || die "missing required tool: $b"
done

if command -v dpkg-scanpackages >/dev/null; then SCANNER=dpkg-scanpackages
elif command -v apt-ftparchive >/dev/null; then SCANNER=apt-ftparchive
else die "need dpkg-scanpackages (apt install dpkg-dev) or apt-ftparchive (apt install apt-utils)"; fi

[[ -n "$CODENAME" ]] || die "could not determine codename; pass --codename"
log "building for Ubuntu ${CODENAME} / ${ARCH}  (override with --codename / --arch)"

case "$ARCH" in
  amd64|i386) UBU_MIRROR="http://archive.ubuntu.com/ubuntu" ;;
  *)          UBU_MIRROR="http://ports.ubuntu.com/ubuntu-ports" ;;
esac
DOCKER_BASE="https://download.docker.com/linux/ubuntu"

log "verifying Docker publishes packages for '$CODENAME'"
if ! curl -fsSI "${DOCKER_BASE}/dists/${CODENAME}/Release" >/dev/null 2>&1; then
  echo "Docker has no '${CODENAME}' suite. Published suites:" >&2
  curl -fsS "${DOCKER_BASE}/dists/" 2>/dev/null \
    | grep -oE 'href="[a-z][a-z-]+/"' | tr -d '"' | sed 's|href=||;s|/||' | sort -u | sed 's/^/  /' >&2
  die "pick one with --codename"
fi

# --------------------------------------------------------------- scratch -----
WORK="$(mktemp -d /tmp/docker-offline.XXXXXX)"
cleanup() { (( KEEP_WORK )) || rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/apt/lists/partial" "$WORK/apt/cache/archives/partial" \
         "$WORK/apt/etc/preferences.d" "$WORK/apt/etc/apt.conf.d" "$WORK/keys"
: > "$WORK/apt/status"      # empty dpkg status => apt resolves the FULL closure

log "importing Docker signing key"
curl -fsSL "${DOCKER_BASE}/gpg" | gpg --dearmor > "$WORK/keys/docker.gpg"
[[ -s "$WORK/keys/docker.gpg" ]] || die "failed to fetch Docker GPG key"

cat > "$WORK/apt/sources.list" <<EOF
deb [arch=${ARCH} signed-by=${WORK}/keys/docker.gpg] ${DOCKER_BASE} ${CODENAME} ${CHANNEL}
deb [arch=${ARCH}] ${UBU_MIRROR} ${CODENAME} main universe
deb [arch=${ARCH}] ${UBU_MIRROR} ${CODENAME}-updates main universe
deb [arch=${ARCH}] ${UBU_MIRROR} ${CODENAME}-security main universe
EOF

APT=(
  -o "Dir::Etc::sourcelist=$WORK/apt/sources.list"
  -o "Dir::Etc::sourceparts=/dev/null"
  -o "Dir::Etc::preferencesparts=$WORK/apt/etc/preferences.d"
  -o "Dir::Etc::parts=$WORK/apt/etc/apt.conf.d"
  -o "Dir::State::lists=$WORK/apt/lists"
  -o "Dir::State::status=$WORK/apt/status"
  -o "Dir::Cache=$WORK/apt/cache"
  -o "APT::Architecture=$ARCH"
  -o "APT::Architectures::=$ARCH"
  -o "APT::Install-Recommends=$RECOMMENDS"
  -o "APT::Install-Suggests=0"
  -o "APT::Get::List-Cleanup=0"
  -o "Acquire::Languages=none"
  -o "Debug::NoLocking=1"
  -o "APT::Sandbox::User=root"
)

log "fetching package indexes for ${CODENAME}/${ARCH} (channel: ${CHANNEL})"
apt-get "${APT[@]}" update >/dev/null

# ------------------------------------------------ what's in this channel? ----
mapfile -t DOCKER_AVAIL < <(
  grep -h '^Package: ' "$WORK/apt/lists"/*download.docker.com*_Packages 2>/dev/null \
    | awk '{print $2}' | sort -u
)
(( ${#DOCKER_AVAIL[@]} )) || die "Docker channel index is empty - check --codename/--channel"

# Deprecated / dead upstream; never bundle unless explicitly asked with --extra.
DENY=" docker-scan-plugin "

SEEDS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
(( ROOTLESS )) && SEEDS+=(docker-ce-rootless-extras)

if (( ALL_DOCKER )); then
  for p in "${DOCKER_AVAIL[@]}"; do
    [[ "$DENY" == *" $p "* ]] && continue
    [[ " ${SEEDS[*]} " == *" $p "* ]] || SEEDS+=("$p")
  done
fi
(( ${#EXTRA_PKGS[@]} )) && SEEDS+=("${EXTRA_PKGS[@]}")

# Report anything published in the channel that we are NOT bundling, so nobody
# discovers it missing six months from now.
SKIPPED=()
for p in "${DOCKER_AVAIL[@]}"; do
  [[ " ${SEEDS[*]} " == *" $p "* ]] || SKIPPED+=("$p")
done
if (( ${#SKIPPED[@]} )); then
  echo "    channel also publishes (NOT bundled): ${SKIPPED[*]}"
  echo "    add with --all-docker, or --extra <name>"
fi

# ------------------------------------------------------ resolve + download ---
INSTALL_LIST=("${SEEDS[@]}")
if [[ -n "$DOCKER_VERSION" ]]; then
  for i in "${!INSTALL_LIST[@]}"; do
    case "${INSTALL_LIST[$i]}" in
      docker-ce|docker-ce-cli|docker-ce-rootless-extras)
        INSTALL_LIST[$i]="${INSTALL_LIST[$i]}=${DOCKER_VERSION}" ;;
    esac
  done
fi

if (( RECOMMENDS )); then
  log "resolving Depends + Recommends closure (matches a normal online install)"
else
  log "resolving Depends closure ONLY (--lean: not equivalent to a normal install)"
fi
echo "    seeds: ${SEEDS[*]}"
apt-get "${APT[@]}" install --download-only --yes "${INSTALL_LIST[@]}"

shopt -s nullglob
DEBS=("$WORK/apt/cache/archives"/*.deb)
(( ${#DEBS[@]} )) || die "no .deb files downloaded"

# Sanity gate: the whole point of this revision.
if (( ROOTLESS )); then
  [[ -n "$(printf '%s\n' "$WORK/apt/cache/archives"/docker-ce-rootless-extras_*.deb)" ]] \
    || die "docker-ce-rootless-extras did not land in the bundle - aborting"
fi

# ---------------------------------------------------------------- bundle -----
STAMP="$(date -u +%Y%m%d)"
BUNDLE="$WORK/docker-offline-${CODENAME}-${ARCH}-${STAMP}"
mkdir -p "$BUNDLE/repo/pool" "$BUNDLE/images" "$BUNDLE/apt-repo"
cp "$WORK/keys/docker.gpg" "$BUNDLE/apt-repo/docker.gpg"
cp -- "${DEBS[@]}" "$BUNDLE/repo/pool/"

log "building flat APT repo index (${#DEBS[@]} packages)"
pushd "$BUNDLE/repo" >/dev/null
if [[ "$SCANNER" == dpkg-scanpackages ]]; then
  dpkg-scanpackages --multiversion pool /dev/null > Packages 2>/dev/null
else
  apt-ftparchive packages pool > Packages
fi
gzip -9c Packages > Packages.gz
popd >/dev/null

DOCKER_CE_DEB="$(basename "$(printf '%s\n' "$BUNDLE"/repo/pool/docker-ce_*.deb | head -1)")"

# ---------------------------------------------------------------- images -----
IMAGES=()
(( WITH_HELLO )) && IMAGES+=("hello-world:latest")
(( ${#EXTRA_IMAGES[@]} )) && IMAGES+=("${EXTRA_IMAGES[@]}")

if (( ${#IMAGES[@]} )); then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "bundling container images"
    for ref in "${IMAGES[@]}"; do
      if docker pull -q --platform "linux/${ARCH}" "$ref" >/dev/null 2>&1; then
        safe="${ref//[^A-Za-z0-9._-]/_}"
        docker save "$ref" -o "$BUNDLE/images/${safe}.tar"
        echo "    + $ref"
      else
        echo "    ! could not pull $ref - skipped" >&2
      fi
    done
  else
    echo "    no usable docker on this host - skipping image bundling" >&2
  fi
fi
rmdir "$BUNDLE/images" 2>/dev/null || true

# ------------------------------------------------------------- bundle info ---
cat > "$BUNDLE/BUNDLE_INFO" <<EOF
BUNDLE_CODENAME="${CODENAME}"
BUNDLE_ARCH="${ARCH}"
BUNDLE_CHANNEL="${CHANNEL}"
BUNDLE_BUILT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUNDLE_DOCKER_CE="${DOCKER_CE_DEB}"
BUNDLE_RECOMMENDS="${RECOMMENDS}"
BUNDLE_ROOTLESS="${ROOTLESS}"
BUNDLE_PKGS="${SEEDS[*]}"
EOF

# ------------------------------------------------------------- installer -----
cat > "$BUNDLE/install.sh" <<'INSTALLER'
#!/usr/bin/env bash
# Offline Docker Engine installer.  Run on the target Ubuntu Server:
#     sudo bash install.sh
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/BUNDLE_INFO"

# Docker's data location is a per-customer decision, so it is an argument here
# rather than something baked into the artifact at build time.
#   --data-root /mnt/data/docker   put Docker's data there
#   --data-root auto              pick the largest suitable non-root filesystem
#   --no-data-root                force the default /var/lib/docker, no prompt
#
# Container log rotation is configured by default (10m x 3 per container),
# because json-file logs are unbounded otherwise and will eventually fill
# whichever disk they are on.
#   --log-max-size 50m   --log-max-file 5   --no-log-config
DATA_ROOT=""
LOG_MAX_SIZE="10m"
LOG_MAX_FILE="3"
LOG_CONFIG=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-root)     DATA_ROOT="${2:-}"; shift 2 ;;
    --no-data-root)  DATA_ROOT="none"; shift ;;
    --log-max-size)  LOG_MAX_SIZE="${2:-}"; shift 2 ;;
    --log-max-file)  LOG_MAX_FILE="${2:-}"; shift 2 ;;
    --no-log-config) LOG_CONFIG=0; shift ;;
    -h|--help)       sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$LOG_MAX_SIZE" =~ ^[0-9]+[kmg]$ ]] || { echo "--log-max-size must look like 10m" >&2; exit 2; }
[[ "$LOG_MAX_FILE" =~ ^[0-9]+$ ]]      || { echo "--log-max-file must be a number" >&2; exit 2; }

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
warn() { printf '   [warn] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "must run as root:  sudo bash install.sh"

HOST_ARCH="$(dpkg --print-architecture)"
HOST_CODE="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-unknown}}")"

say "Bundle targets Ubuntu '$BUNDLE_CODENAME' / $BUNDLE_ARCH  (engine: $BUNDLE_DOCKER_CE)"
echo "   This machine is Ubuntu '$HOST_CODE' / $HOST_ARCH"
[[ "$HOST_ARCH" == "$BUNDLE_ARCH" ]] || fail "architecture mismatch - wrong bundle for this machine"
if [[ "$HOST_CODE" != "$BUNDLE_CODENAME" ]]; then
  if [[ "${FORCE:-0}" == 1 ]]; then
    warn "release mismatch overridden by FORCE=1; dependencies may not resolve"
  else
    fail "release mismatch: this bundle is for Ubuntu '$BUNDLE_CODENAME', the machine runs '$HOST_CODE'.
        Get a bundle built for '$HOST_CODE'. To override anyway: sudo FORCE=1 bash install.sh"
  fi
fi
ok "release and architecture match"

# systemd is assumed below; a container/WSL target has none.
[[ -d /run/systemd/system ]] || fail "no systemd detected - this installer targets a normal Ubuntu Server VM"

# Docker's own docs require these gone first; a provisioner image may carry them.
CONFLICTS=()
for c in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  dpkg -s "$c" >/dev/null 2>&1 && CONFLICTS+=("$c")
done
if (( ${#CONFLICTS[@]} )); then
  fail "conflicting packages installed: ${CONFLICTS[*]}
        Remove them first:  sudo apt-get remove -y ${CONFLICTS[*]}
        (this bundle installs Docker CE, which conflicts with those)"
fi
if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
  fail "the 'docker' snap is installed; remove it first:  sudo snap remove docker"
fi
command -v docker >/dev/null 2>&1 && warn "docker already present: $(docker --version 2>/dev/null || echo unknown)"

say "Verifying bundle integrity"
( cd "$HERE" && sha256sum -c --quiet SHA256SUMS ) || fail "checksum mismatch - re-copy the bundle"
ok "all files intact"

say "Installing Docker Engine (no network required)"
# No pre-flight wait for cloud-init or apt-daily: DPkg::Lock::Timeout below is
# apt's own lock wait. It prints "Waiting for cache lock: ... held by process
# N", proceeds the instant the lock frees, and needs no guessing about which
# systemd units might be holding it.
LISTS="$HERE/.aptlists"; mkdir -p "$LISTS/partial"
printf 'deb [trusted=yes] file://%s/repo ./\n' "$HERE" > "$HERE/.aptsource.list"

# Scoped entirely to this bundle: /etc/apt and /var/lib/apt/lists are untouched
# and apt never attempts to reach the internet.
APT=(
  -o "Dir::Etc::sourcelist=$HERE/.aptsource.list"
  -o "Dir::Etc::sourceparts=/dev/null"
  -o "Dir::State::lists=$LISTS"
  -o "APT::Get::List-Cleanup=0"
  -o "Acquire::Languages=none"
  -o "APT::Install-Recommends=$BUNDLE_RECOMMENDS"
  -o "APT::Install-Suggests=0"
  -o "DPkg::Lock::Timeout=600"
  -o "APT::Sandbox::User=root"
)
export DEBIAN_FRONTEND=noninteractive
apt-get "${APT[@]}" update >/dev/null
# shellcheck disable=SC2086
apt-get "${APT[@]}" install -y $BUNDLE_PKGS || fail "apt install failed - see output above.
        If it complained about a dpkg lock, something else is using apt:
          systemctl list-jobs; ps aux | grep -i [a]pt
        Wait for it to finish, then re-run this installer."
rm -f "$HERE/.aptsource.list"; rm -rf "$LISTS"

# ------------------------------------------------------------ data root -----
# Applied BEFORE the daemon's first start, so /var/lib/docker is never
# populated and there is nothing to migrate afterwards.
data_candidates() {
  df -PB1 -x tmpfs -x devtmpfs -x squashfs -x overlay -x nfs -x nfs4 -x cifs 2>/dev/null \
    | awk 'NR>1 && $6!="/" && $4>=10737418240 {print $6, $4}' | sort -k2 -rn
}

if [[ -z "$DATA_ROOT" ]] && [[ -t 0 ]]; then
  mapfile -t CANDS < <(data_candidates)
  if (( ${#CANDS[@]} )); then
    say "Separate filesystem(s) detected"
    i=0
    for c in "${CANDS[@]}"; do
      i=$((i+1)); mp="${c%% *}"; av="${c##* }"
      printf '     %d) %-28s %d GB free\n' "$i" "$mp" "$((av/1073741824))"
    done
    echo "   Leave blank to use the OS drive (/var/lib/docker)."
    read -r -p "   Put Docker's data on one of these? [1-$i / blank] " pick
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= i )); then
      DATA_ROOT="${CANDS[$((pick-1))]%% *}/docker"
    fi
  fi
fi

if [[ "$DATA_ROOT" == auto ]]; then
  top="$(data_candidates | head -1)"
  [[ -n "$top" ]] || fail "--data-root auto found no non-root filesystem with 10 GB+ free"
  DATA_ROOT="${top%% *}/docker"
  ok "auto-selected $DATA_ROOT"
fi

if [[ -n "$DATA_ROOT" && "$DATA_ROOT" != none ]]; then
  say "Configuring Docker's data root: $DATA_ROOT"
  [[ "$DATA_ROOT" == /* ]] || fail "--data-root must be an absolute path, got: $DATA_ROOT"

  install -d -m 0711 "$DATA_ROOT" || fail "cannot create $DATA_ROOT"
  MP="$(df -P "$DATA_ROOT" | awk 'NR==2{print $6}')"
  FSTYPE="$(df -PT "$DATA_ROOT" | awk 'NR==2{print $2}')"
  echo "   on $MP ($FSTYPE)"

  # The silent killer: data drive not mounted, so this is really the OS disk
  # and dockerd quietly fills the root filesystem.
  if [[ "$MP" == "/" && "${DATA_ROOT_FORCE:-0}" != 1 ]]; then
    fail "$DATA_ROOT resolves to the root filesystem, not a separate drive.
        The data drive is probably not mounted. Check 'lsblk' and /etc/fstab,
        mount it, then re-run. To proceed anyway: DATA_ROOT_FORCE=1"
  fi
  case "$FSTYPE" in
    nfs|nfs4|cifs) fail "$MP is $FSTYPE - Docker's data root does not work on a network filesystem" ;;
    xfs) if command -v xfs_info >/dev/null 2>&1 && ! xfs_info "$MP" 2>/dev/null | grep -q 'ftype=1'; then
           fail "$MP is xfs with ftype=0 - overlay2 refuses it; needs mkfs.xfs -n ftype=1"
         fi ;;
  esac

  # Engine 29+ uses the containerd image store by default, so image content and
  # snapshots live under containerd's root, not Docker's data-root. Move both
  # or the images (the bulk of the data) stay on the OS drive.
  CONTAINERD_ROOT="${MP}/containerd"
  CCFG=/etc/containerd/config.toml
  install -d -m 0711 "$CONTAINERD_ROOT" || fail "cannot create $CONTAINERD_ROOT"
  if [[ -f "$CCFG" ]]; then
    cp -a "$CCFG" "$CCFG.bak"
  else
    install -d -m 0755 /etc/containerd; : > "$CCFG"
  fi
  if grep -qE '^[[:space:]]*root[[:space:]]*=' "$CCFG"; then
    sed -i -E "s|^[[:space:]]*root[[:space:]]*=.*|root = \"$CONTAINERD_ROOT\"|" "$CCFG"
  elif grep -qE '^[[:space:]]*version[[:space:]]*=' "$CCFG"; then
    sed -i -E "0,/^[[:space:]]*version[[:space:]]*=.*/s||&\nroot = \"$CONTAINERD_ROOT\"|" "$CCFG"
  else
    sed -i "1i root = \"$CONTAINERD_ROOT\"" "$CCFG"
  fi
  ok "containerd root set to $CONTAINERD_ROOT (backup: $CCFG.bak)"

  # A boot where the data drive fails to mount must not start either daemon
  # against an empty directory on the OS drive.
  for u in docker containerd; do
    install -d -m 0755 "/etc/systemd/system/${u}.service.d"
    printf '[Unit]\nRequiresMountsFor=%s\n' "$MP" \
      > "/etc/systemd/system/${u}.service.d/10-data-root.conf"
  done
  systemctl daemon-reload
  ok "docker.service and containerd.service now require $MP to be mounted"

  # containerd was already started by the package install, on the old root.
  systemctl restart containerd.service || fail "containerd would not restart with root=$CONTAINERD_ROOT"
  sleep 1
  [[ -d "$CONTAINERD_ROOT/io.containerd.content.v1.content" ]] \
    && ok "containerd is using $CONTAINERD_ROOT" \
    || warn "containerd did not populate $CONTAINERD_ROOT - check 'journalctl -u containerd'"
fi

# --------------------------------------------------------- daemon.json ------
# One merge for everything, applied before the daemon's first start. dockerd
# refuses to start on malformed JSON, so a successful start below is also the
# proof that this parsed.
DJ=/etc/docker/daemon.json
WANT_DR=0; [[ -n "$DATA_ROOT" && "$DATA_ROOT" != none ]] && WANT_DR=1

if (( WANT_DR || LOG_CONFIG )); then
  say "Configuring $DJ"
  install -d -m 0755 /etc/docker

  if [[ -s "$DJ" ]]; then
    command -v python3 >/dev/null || fail "$DJ already exists and python3 is absent, so it
        cannot be merged safely. Set the values by hand and re-run with
        --no-log-config --no-data-root."
    cp -a "$DJ" "$DJ.bak"
    DR_ARG=""; (( WANT_DR )) && DR_ARG="$DATA_ROOT"
    LOG_ARG=""; (( LOG_CONFIG )) && LOG_ARG="${LOG_MAX_SIZE}:${LOG_MAX_FILE}"
    python3 - "$DJ" "$DR_ARG" "$LOG_ARG" <<'PYMERGE' || fail "could not merge $DJ"
import json, sys
path, dr, log = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(path))
notes = []
if dr:
    cfg["data-root"] = dr
if log:
    # Do not silently override a log setup the customer already chose --
    # they may be shipping to journald, syslog or a collector.
    if "log-driver" in cfg or "log-opts" in cfg:
        notes.append("existing log-driver/log-opts left untouched")
    else:
        size, count = log.split(":")
        cfg["log-driver"] = "json-file"
        cfg["log-opts"] = {"max-size": size, "max-file": count}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2); f.write("\n")
for n in notes:
    print("NOTE:" + n)
PYMERGE
    ok "merged into existing $DJ (backup: $DJ.bak)"
  else
    { printf '{'
      sep=""
      if (( WANT_DR )); then printf '\n  "data-root": "%s"' "$DATA_ROOT"; sep=","; fi
      if (( LOG_CONFIG )); then
        printf '%s\n  "log-driver": "json-file",\n  "log-opts": {\n    "max-size": "%s",\n    "max-file": "%s"\n  }' \
          "$sep" "$LOG_MAX_SIZE" "$LOG_MAX_FILE"
      fi
      printf '\n}\n'
    } > "$DJ"
    ok "wrote $DJ"
  fi

  if command -v python3 >/dev/null; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$DJ" \
      || fail "$DJ is not valid JSON - dockerd will refuse to start"
  fi
  (( LOG_CONFIG )) && ok "container logs capped at ${LOG_MAX_SIZE} x ${LOG_MAX_FILE} per container"
fi

say "Enabling services"
systemctl enable --now containerd.service >/dev/null 2>&1 || true
systemctl enable --now docker.socket >/dev/null 2>&1 || true
systemctl enable --now docker.service || fail "docker.service would not start (journalctl -u docker)"
ok "docker.service enabled and running"
if [[ -n "$DATA_ROOT" && "$DATA_ROOT" != none ]]; then
  ACTUAL="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo unknown)"
  [[ "$ACTUAL" == "$DATA_ROOT" ]] \
    || fail "docker reports its root dir as '$ACTUAL', expected '$DATA_ROOT'"
  ok "Docker root dir is $ACTUAL"
  DS="$(docker info -f '{{.DriverStatus}}' 2>/dev/null || echo '')"
  if [[ "$DS" == *"io.containerd.snapshotter"* ]]; then
    ok "containerd image store in use - image layers are under $CONTAINERD_ROOT"
  else
    ok "legacy graph driver in use - image layers are under $ACTUAL/overlay2"
  fi
fi

TARGET_USER="${SUDO_USER:-}"
if [[ -n "$TARGET_USER" && "$TARGET_USER" != root ]]; then
  usermod -aG docker "$TARGET_USER"
  ok "added '$TARGET_USER' to the docker group (log out and back in)"
fi

say "Capability check"
docker version --format 'Client {{.Client.Version}} / Server {{.Server.Version}}' \
  >/dev/null 2>&1 || fail "docker installed but the daemon is not responding"
ok "engine: $(docker version --format '{{.Server.Version}}')"
LD="$(docker info -f '{{.LoggingDriver}}' 2>/dev/null || echo unknown)"
if (( LOG_CONFIG )); then
  [[ "$LD" == json-file ]] && ok "log driver: $LD, rotating at ${LOG_MAX_SIZE} x ${LOG_MAX_FILE}" \
                           || warn "log driver is '$LD', expected json-file"
else
  ok "log driver: $LD (rotation not configured by this installer)"
fi
docker buildx version  >/dev/null 2>&1 && ok "docker buildx: $(docker buildx version | head -1)"   || warn "docker buildx MISSING"
docker compose version >/dev/null 2>&1 && ok "docker compose: $(docker compose version --short)"    || warn "docker compose MISSING"
if [[ "$BUNDLE_ROOTLESS" == 1 ]]; then
  command -v dockerd-rootless-setuptool.sh >/dev/null \
    && ok "rootless support present (run 'dockerd-rootless-setuptool.sh install' as a normal user)" \
    || warn "rootless tooling MISSING"
fi
for p in git pigz xz-utils ca-certificates; do
  dpkg -s "$p" >/dev/null 2>&1 && ok "$p present" || warn "$p missing (build-from-git / layer perf / TLS may be affected)"
done

if compgen -G "$HERE/images/*.tar" >/dev/null; then
  say "Loading bundled images"
  for t in "$HERE"/images/*.tar; do docker load -i "$t" | sed 's/^/   /'; done
  if docker image inspect hello-world:latest >/dev/null 2>&1; then
    docker run --rm hello-world >/dev/null 2>&1 && ok "end-to-end container smoke test passed" \
      || warn "hello-world container failed to run"
  fi
fi

say "Done."
if [[ -f "$HERE/enable-online-updates.sh" ]]; then
  if timeout 5 bash -c 'exec 3<>/dev/tcp/download.docker.com/443' 2>/dev/null; then
    echo "   This machine can reach download.docker.com. Docker is installed but"
    echo "   no apt repo tracks it, so 'apt upgrade' will never offer a newer"
    echo "   docker-ce. To track it upstream from here on, run once:"
    echo "       sudo bash $HERE/enable-online-updates.sh"
  else
    echo "   No route to download.docker.com, so this box stays on the bundled"
    echo "   engine version - which is what you want offline. Ubuntu's own"
    echo "   security updates are unaffected. Upgrade Docker by installing a"
    echo "   newer bundle, not by adding a repo."
  fi
fi
INSTALLER

# ------------------------------------------------- online-updates opt-in -----
# install.sh deliberately leaves /etc/apt untouched, which means docker-ce ends
# up installed with no upstream repo tracking it: apt reports nothing to
# upgrade, and says nothing about why. That is correct for a genuinely
# airgapped box (a docker.list there would make every apt update hang on an
# unreachable host) and wrong for one that gets internet later. So ship the key
# and a script, and let whoever knows the answer run it.
cat > "$BUNDLE/enable-online-updates.sh" <<'ONLINE'
#!/usr/bin/env bash
# Point this machine at Docker's live apt repo, so docker-ce can be upgraded
# normally from here on. ONLY run this if the machine has internet access.
#     sudo bash enable-online-updates.sh
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/BUNDLE_INFO"

# Docker's data location is a per-customer decision, so it is an argument here
# rather than something baked into the artifact at build time.
#   --data-root /mnt/data/docker   put Docker's data there
#   --data-root auto              pick the largest suitable non-root filesystem
#   --no-data-root                force the default /var/lib/docker, no prompt
#
# Container log rotation is configured by default (10m x 3 per container),
# because json-file logs are unbounded otherwise and will eventually fill
# whichever disk they are on.
#   --log-max-size 50m   --log-max-file 5   --no-log-config
DATA_ROOT=""
LOG_MAX_SIZE="10m"
LOG_MAX_FILE="3"
LOG_CONFIG=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-root)     DATA_ROOT="${2:-}"; shift 2 ;;
    --no-data-root)  DATA_ROOT="none"; shift ;;
    --log-max-size)  LOG_MAX_SIZE="${2:-}"; shift 2 ;;
    --log-max-file)  LOG_MAX_FILE="${2:-}"; shift 2 ;;
    --no-log-config) LOG_CONFIG=0; shift ;;
    -h|--help)       sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$LOG_MAX_SIZE" =~ ^[0-9]+[kmg]$ ]] || { echo "--log-max-size must look like 10m" >&2; exit 2; }
[[ "$LOG_MAX_FILE" =~ ^[0-9]+$ ]]      || { echo "--log-max-file must be a number" >&2; exit 2; }

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "must run as root:  sudo bash enable-online-updates.sh"
[[ -f "$HERE/apt-repo/docker.gpg" ]] || fail "apt-repo/docker.gpg missing from this bundle"

say "Checking this machine can reach download.docker.com"
if ! timeout 10 bash -c 'exec 3<>/dev/tcp/download.docker.com/443' 2>/dev/null; then
  fail "cannot reach download.docker.com:443.
        Do NOT enable the repo on an airgapped machine - every future
        'apt update' would stall on an unreachable host."
fi
ok "reachable"

say "Installing Docker's signing key and repo definition"
install -d -m 0755 /etc/apt/keyrings
install -m 0644 "$HERE/apt-repo/docker.gpg" /etc/apt/keyrings/docker.gpg
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s %s\n' \
  "$BUNDLE_ARCH" "$BUNDLE_CODENAME" "$BUNDLE_CHANNEL" > /etc/apt/sources.list.d/docker.list
ok "/etc/apt/sources.list.d/docker.list written"

say "Refreshing package lists"
apt-get update
say "Docker Engine is now tracked upstream"
apt-cache policy docker-ce | sed 's/^/   /'
cat <<'NEXT'

   Upgrade later with:
       sudo apt-get update && sudo apt-get install --only-upgrade             docker-ce docker-ce-cli containerd.io             docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras

   Note: upgrading docker-ce restarts the daemon, which restarts containers.
   Do it in a maintenance window, not on a live gateway.

   To undo:  sudo rm /etc/apt/sources.list.d/docker.list && sudo apt-get update
NEXT
ONLINE

# ---------------------------------------------------------------- README -----
cat > "$BUNDLE/README.txt" <<EOF
Offline Docker Engine installer
===============================
Target  : Ubuntu ${CODENAME} (${ARCH})
Channel : ${CHANNEL}
Built   : $(date -u +%Y-%m-%d)
Engine  : ${DOCKER_CE_DEB}
Mode    : $( ((RECOMMENDS)) && echo "complete (Depends + Recommends)" || echo "LEAN (Depends only)")

INSTRUCTIONS
------------
1. Copy this whole folder onto the server (USB stick, scp, whatever).
2. Open a terminal in this folder.
3. Run exactly:

       sudo bash install.sh

4. Wait for "Done", then log out and back in.

No internet connection is needed on the server. The installer prints a
capability check at the end - every line should say [ ok ].

This bundle is built for Ubuntu ${CODENAME} / ${ARCH} and will REFUSE to run on
anything else rather than half-install. If it reports a mismatch, or reports
conflicting packages (docker.io, containerd, the docker snap), the VM was not
provisioned the way this bundle expects - stop and report it.

On a freshly provisioned VM the installer first waits for cloud-init and the
boot-time apt jobs to finish. That can take a couple of minutes on first boot.
This is normal; do not interrupt it.

WHAT THIS INSTALLS
------------------
Top-level packages: ${SEEDS[*]}

Plus their full dependency$( ((RECOMMENDS)) && echo " and Recommends") closure -- ${#DEBS[@]} .deb files in total.
This is the same package set a normal, internet-connected
"apt-get install docker-ce ..." would produce.

ROOTLESS MODE
-------------
$( ((ROOTLESS)) && cat <<'RL'
Rootless support is included. To enable it for a specific user, log in as
that user (not root) and run:

    dockerd-rootless-setuptool.sh install
    systemctl --user enable --now docker

Persisting it across logouts also needs, once, as root:

    loginctl enable-linger <username>
RL
) $( ((ROOTLESS)) || echo "Not included in this bundle (--no-rootless was used).")

DATA ON A SEPARATE DRIVE
------------------------
By default Docker stores everything (images, containers, volumes, logs) under
/var/lib/docker on the OS drive. If this VM has a data drive, pass the path
when installing:

    sudo bash install.sh --data-root /mnt/data/docker

Or let it pick the largest suitable filesystem:

    sudo bash install.sh --data-root auto

With no flag, it lists any separate filesystems it finds and asks; pressing
Enter uses the OS drive. Nothing about the location is baked into this bundle,
so the same artifact works for every site.

The drive must already be mounted (check 'lsblk' and /etc/fstab). The
installer refuses if the path turns out to be on the root filesystem, because
an unmounted data drive means dockerd silently fills the OS disk instead.

Docker Engine 29+ keeps image layers in containerd's store, not in Docker's
data-root, so the installer relocates BOTH. Given --data-root /mnt/data/docker
it also sets containerd's root to /mnt/data/containerd (derived from the
mount point, not from the path you passed).

WHAT ENDS UP WHERE
  data drive   image layers and content (containerd root)
               named volumes -- including the ChirpStack postgres and redis data
               container filesystems and container JSON logs
               build cache
  OS drive     the Docker and containerd binaries (~400 MB, from apt)
               /etc/docker, /etc/containerd
               daemon logs in the systemd journal
               your compose file and ./configuration directory, wherever you
               put them - those are NOT covered by --data-root

CONTAINER LOG ROTATION
----------------------
json-file logs are unbounded by default: a chatty container will grow its log
until the disk is full. The installer therefore writes rotation into
/etc/docker/daemon.json before the daemon first starts:

    "log-driver": "json-file"
    "log-opts": { "max-size": "10m", "max-file": "3" }

That caps each container at 30 MB, so the whole ChirpStack stack is bounded at
roughly 210 MB of logs. Override with --log-max-size / --log-max-file, or skip
entirely with --no-log-config.

If daemon.json already sets log-driver or log-opts, the installer leaves them
alone and says so - a customer shipping to journald or a collector should not
have that silently reset.

Note that a log-driver change only affects containers created afterwards.
Existing containers keep their original logging config until recreated.

ONLINE UPDATES LATER
--------------------
install.sh does not touch /etc/apt. Docker ends up installed with no repo
tracking it, so "apt upgrade" will never offer a newer docker-ce and will not
say why. That is deliberate: on an airgapped box a docker.list entry makes
every "apt update" stall on an unreachable host.

Ubuntu's own packages (apparmor, git, ca-certificates and the rest) are
unaffected - the machine's existing sources.list still covers those.

If this machine has internet access, or gets it later, run once:

    sudo bash enable-online-updates.sh

That installs Docker's signing key and repo definition, after checking the
host is actually reachable, and docker-ce becomes upgradeable normally.
Upgrading docker-ce restarts the daemon and therefore the containers, so do it
in a maintenance window.

LAYOUT
------
repo/         offline APT repository (${#DEBS[@]} packages)
apt-repo/     Docker's signing key, for enable-online-updates.sh
enable-online-updates.sh  opt-in: switch to the live Docker repo
images/       container images loaded at install time (if any)
install.sh    the installer
BUNDLE_INFO   machine-readable build metadata
SHA256SUMS    integrity checksums, verified automatically
MANIFEST.txt  full package list with sizes
EOF

log "writing manifest and checksums"
{
  printf 'Offline Docker bundle\n'
  printf '  target    : Ubuntu %s (%s), channel %s\n' "$CODENAME" "$ARCH" "$CHANNEL"
  printf '  built     : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  mode      : %s\n' "$( ((RECOMMENDS)) && echo 'Depends + Recommends' || echo 'Depends only (LEAN)')"
  printf '  top-level : %s\n' "${SEEDS[*]}"
  (( ${#SKIPPED[@]} )) && printf '  available in channel but NOT bundled: %s\n' "${SKIPPED[*]}"
  printf '\n%-56s %12s\n' "PACKAGE_FILE" "BYTES"
  for f in "$BUNDLE"/repo/pool/*.deb; do
    printf '%-56s %12s\n' "$(basename "$f")" "$(stat -c%s "$f")"
  done
} > "$BUNDLE/MANIFEST.txt"

pushd "$BUNDLE" >/dev/null
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
popd >/dev/null

mkdir -p "$OUTDIR"
TARBALL="$OUTDIR/$(basename "$BUNDLE").tar.gz"
log "creating $TARBALL"
tar -C "$WORK" -czf "$TARBALL" "$(basename "$BUNDLE")"

cat <<EOF

Bundle ready.
  file      : $TARBALL
  size      : $(du -h "$TARBALL" | cut -f1)
  packages  : ${#DEBS[@]}
  mode      : $( ((RECOMMENDS)) && echo 'Depends + Recommends (complete)' || echo 'Depends only (LEAN)')
  rootless  : $( ((ROOTLESS)) && echo 'included' || echo 'EXCLUDED')
  engine    : ${DOCKER_CE_DEB}
  target    : Ubuntu ${CODENAME} / ${ARCH}

Hand off with:
  tar xzf $(basename "$TARBALL") && cd $(basename "$BUNDLE") && sudo bash install.sh
EOF
