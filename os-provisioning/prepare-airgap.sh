#!/usr/bin/env bash
#
# prepare-airgap.sh
#
# Builds both airgap bundles and packs them into ONE artifact with ONE operator
# command. The two inner bundles stay byte-identical to what their own scripts
# produce, so they remain independently rebuildable and independently traceable.
#
#   ./prepare-airgap.sh                      # docker + chirpstack images
#   ./prepare-airgap.sh --skip-images        # docker only
#   ./prepare-airgap.sh --skip-docker        # image refresh for a VM that has docker
#   ./prepare-airgap.sh --compose ./docker-compose.yml
#
# Operator's job on the target VM:  sudo bash install-all.sh
#
# Expects docker-offline-bundle.sh and chirpstack-image-bundle.sh next to this
# script (override with DOCKER_BUNDLE_SH / CHIRPSTACK_BUNDLE_SH).

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_SH="${DOCKER_BUNDLE_SH:-$SELF_DIR/docker-offline-bundle.sh}"
CHIRP_SH="${CHIRPSTACK_BUNDLE_SH:-$SELF_DIR/chirpstack-image-bundle.sh}"

# ---------------------------------------------------------------- defaults ---
CODENAME="noble"
ARCH="amd64"
OUTDIR=""                      # default: ./artifacts
RECORDSDIR="none"              # opt in with --records DIR
NAME=""
SKIP_DOCKER=0
SKIP_IMAGES=0
COMPOSE_FILE=""
FROM_LIST=""
SURVEY=""
LATEST=0
IMAGES_ONLY=0
DOCKER_ARGS=()
IMAGE_ARGS=()

usage() {
  cat <<'EOF'
Usage: prepare-airgap.sh [options]

  -c, --codename NAME   Target Ubuntu codename (default: noble)
  -a, --arch ARCH       Target arch (default: amd64)
      --skip-docker     Don't build the Docker Engine bundle
      --skip-images     Don't build the ChirpStack image bundle
      --compose FILE    Include a compose file in the image bundle
      --images-only     UPDATE an existing site: current ChirpStack images
                        only, no Docker Engine. This is the one to run when a
                        site already has Docker and just needs new images.
      --latest          Full install with current ChirpStack images, versions
                        resolved and stamped into the artifact name and a
                        VERSIONS.txt. Needs no other flags.
      --from-survey F   Take --codename and --arch from a target-survey.sh
                        output file, so the bundle matches the actual box
      --from-list FILE  Rebuild images from a previous images.pinned
      --docker-arg ARG  Pass an extra arg to docker-offline-bundle.sh (repeatable)
      --image-arg ARG   Pass an extra arg to chirpstack-image-bundle.sh (repeatable)
  -o, --out DIR         Where to write the artifact (default: ./artifacts)
      --records DIR     Also copy the build's images.pinned / VERSIONS.txt to
                        DIR as plain text. Off by default; images.pinned is
                        already inside the artifact either way.
  -n, --name NAME       Artifact basename (default: airgap-<codename>-<date>)
  -h, --help            This text

Examples:
  ./prepare-airgap.sh --latest                      # what a tech should run
  ./prepare-airgap.sh --latest --skip-docker        # image refresh only
  ./prepare-airgap.sh --skip-docker --from-list ./images.pinned
  ./prepare-airgap.sh --docker-arg --version --docker-arg 5:28.0.0-1~ubuntu.24.04~noble
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--codename)  CODENAME="$2"; shift 2 ;;
    -a|--arch)      ARCH="$2"; shift 2 ;;
    --skip-docker)  SKIP_DOCKER=1; shift ;;
    --skip-images)  SKIP_IMAGES=1; shift ;;
    --compose)      COMPOSE_FILE="$2"; shift 2 ;;
    --images-only)  IMAGES_ONLY=1; LATEST=1; SKIP_DOCKER=1; shift ;;
    --latest)       LATEST=1; shift ;;
    --from-survey)  SURVEY="$2"; shift 2 ;;
    --from-list)    FROM_LIST="$2"; shift 2 ;;
    --docker-arg)   DOCKER_ARGS+=("$2"); shift 2 ;;
    --image-arg)    IMAGE_ARGS+=("$2"); shift 2 ;;
    -o|--out)       OUTDIR="$2"; shift 2 ;;
    --records)      RECORDSDIR="$2"; shift 2 ;;
    -n|--name)      NAME="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\n######## %s\n' "$*"; }

OUTDIR="${OUTDIR:-$PWD/artifacts}"

if (( IMAGES_ONLY && SKIP_IMAGES )); then
  die "--images-only and --skip-images are contradictory: drop one"
fi
(( SKIP_DOCKER && SKIP_IMAGES )) && die "nothing to do (both --skip-docker and --skip-images)"
if (( LATEST )) && [[ -n "$FROM_LIST" ]]; then
  die "--latest and --from-list are opposites: one takes whatever is current, the other reproduces a past build. Pick one."
fi
if (( LATEST && SKIP_IMAGES )); then
  echo "note: --latest has no effect with --skip-images (it only concerns container images)" >&2
fi

if [[ -n "$SURVEY" ]]; then
  [[ -f "$SURVEY" ]] || die "--from-survey file not found: $SURVEY"
  _sc="$(grep -m1 '^SURVEY_CODENAME=' "$SURVEY" | cut -d= -f2- || true)"
  _sa="$(grep -m1 '^SURVEY_ARCH='     "$SURVEY" | cut -d= -f2- || true)"
  _sv="$(grep -m1 '^SURVEY_VERDICT='  "$SURVEY" | cut -d= -f2- || true)"
  [[ -n "$_sc" && "$_sc" != unknown ]] || die "survey has no usable SURVEY_CODENAME: $SURVEY"
  [[ -n "$_sa" && "$_sa" != unknown ]] || die "survey has no usable SURVEY_ARCH: $SURVEY"
  CODENAME="$_sc"; ARCH="$_sa"
  echo "survey $(basename "$SURVEY"): targeting ${CODENAME}/${ARCH} (verdict: ${_sv:-none})"
  if [[ "$_sv" == BLOCKED ]]; then
    echo "  the surveyed box reported BLOCKERS. Building anyway, but the install will" >&2
    echo "  fail until they are fixed. Re-run target-survey.sh after fixing them." >&2
  fi
fi

MODE="full"; (( IMAGES_ONLY )) && MODE="update"
NAME_GIVEN=0; [[ -n "$NAME" ]] && NAME_GIVEN=1
if [[ "$MODE" == update ]]; then
  NAME="${NAME:-chirpstack-update-${ARCH}-$(date -u +%Y%m%d)}"
else
  NAME="${NAME:-airgap-${CODENAME}-$(date -u +%Y%m%d)}"
fi

# Fail before doing any work, not halfway through a 200 MB download.
(( SKIP_DOCKER )) || [[ -x "$DOCKER_SH" || -f "$DOCKER_SH" ]] || die "not found: $DOCKER_SH"
(( SKIP_IMAGES )) || [[ -x "$CHIRP_SH" || -f "$CHIRP_SH" ]] || die "not found: $CHIRP_SH"
if (( ! SKIP_IMAGES )); then
  command -v docker >/dev/null || die "the image bundle needs a working docker on THIS host (or use --skip-images)"
  docker info >/dev/null 2>&1  || die "docker daemon not reachable on THIS host (or use --skip-images)"
fi
[[ -z "$COMPOSE_FILE" || -f "$COMPOSE_FILE" ]] || die "--compose file not found: $COMPOSE_FILE"
[[ -z "$FROM_LIST"    || -f "$FROM_LIST"    ]] || die "--from-list file not found: $FROM_LIST"

STAGE="$(mktemp -d /tmp/prepare-airgap.XXXXXX)"
OUTER="$STAGE/$NAME"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
mkdir -p "$OUTER"

# ------------------------------------------------------------ 1. engine ------
DOCKER_TARBALL=""
if (( ! SKIP_DOCKER )); then
  log "1/2  Docker Engine bundle"
  bash "$DOCKER_SH" --codename "$CODENAME" --arch "$ARCH" --out "$OUTER" \
    "${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}"
  shopt -s nullglob
  found=("$OUTER"/docker-offline-*.tar.gz)
  (( ${#found[@]} == 1 )) || die "expected exactly one docker bundle tarball, got ${#found[@]}"
  DOCKER_TARBALL="$(basename "${found[0]}")"
fi

# ------------------------------------------------------------ 2. images ------
IMAGE_TARBALL=""
if (( ! SKIP_IMAGES )); then
  log "2/2  ChirpStack image bundle"
  args=(--platform "linux/${ARCH}" --out "$OUTER")
  [[ -n "$COMPOSE_FILE" ]] && args+=(--compose "$COMPOSE_FILE")
  [[ -n "$FROM_LIST"    ]] && args+=(--from-list "$FROM_LIST")
  bash "$CHIRP_SH" "${args[@]}" "${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"}"
  shopt -s nullglob
  found=("$OUTER"/chirpstack-images-*.tar.gz "$OUTER"/chirpstack-images-*.tar)
  (( ${#found[@]} == 1 )) || die "expected exactly one image bundle tarball, got ${#found[@]}"
  IMAGE_TARBALL="$(basename "${found[0]}")"
fi

# ------------------------------------------------- resolve versions ---------
# The floating tags (:4, :14-alpine, :2) already give current content, so
# "latest" needs no registry query. What is missing is a human-readable record
# of WHICH version arrived. Read it out of the pulled images themselves --
# no registry API, no auth token, no rate limit, nothing new to break.
VERSIONS_TXT=""
CS_VERSION=""

image_version() {
  local tag="$1" v=""
  for label in org.opencontainers.image.version version; do
    v="$(docker image inspect "$tag" --format "{{index .Config.Labels \"$label\"}}" 2>/dev/null || true)"
    [[ -n "$v" && "$v" != "<no value>" ]] && { printf '%s' "$v"; return; }
  done
  v="$(docker image inspect "$tag" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | grep -m1 -E '^(PG_VERSION|REDIS_VERSION|MOSQUITTO_VERSION|VERSION)=' | cut -d= -f2- || true)"
  [[ -n "$v" ]] && printf '%s' "$v" || printf 'unknown'
}

if (( LATEST )) && [[ -n "$IMAGE_TARBALL" ]]; then
  log "resolving image versions"
  # The image list belongs to the image bundle, so read it back rather than
  # duplicating it here.
  mapfile -t _tags < <(
    tar -xzOf "$OUTER/$IMAGE_TARBALL" --wildcards '*/images.txt' 2>/dev/null \
      | grep -v '^#' | cut -f1 | sed '/^$/d'
  )
  if (( ${#_tags[@]} == 0 )); then
    echo "    could not read the image list back; skipping version stamping" >&2
  else
    for t in "${_tags[@]}"; do
      v="$(image_version "$t")"
      printf '    %-42s %s\n' "$t" "$v"
      VERSIONS_TXT+="$(printf '%s\t%s' "$t" "$v")"$'\n'
      [[ "$t" == chirpstack/chirpstack:* ]] && CS_VERSION="$v"
    done
    if (( ! NAME_GIVEN )) && [[ -n "$CS_VERSION" && "$CS_VERSION" != unknown ]]; then
      _v="${CS_VERSION//[^0-9A-Za-z._-]/_}"
      if [[ "$MODE" == update ]]; then
        NEWNAME="chirpstack-update-cs${_v}-${ARCH}-$(date -u +%Y%m%d)"
      else
        NEWNAME="airgap-${CODENAME}-cs${_v}-$(date -u +%Y%m%d)"
      fi
      mv "$OUTER" "$STAGE/$NEWNAME"
      NAME="$NEWNAME"; OUTER="$STAGE/$NAME"
      echo "    artifact will be named: $NAME"
    fi
  fi
fi

# --------------------------------------------------- ordered installer -------
cat > "$OUTER/install-all.sh" <<'RUNALL'
#!/usr/bin/env bash
# Complete airgap install. Run on the target Ubuntu Server:
#     sudo bash install-all.sh
#
# Runs the Docker Engine install first, then loads the container images. That
# order is not optional: images cannot be loaded without a running daemon.
#
# Optional, for a VM with a separate data drive:
#     sudo bash install-all.sh --data-root /mnt/data/docker
#     sudo bash install-all.sh --data-root auto
# With no flag it offers any separate filesystem it finds, defaulting to the
# OS drive.
#
# Container log rotation is applied by default (10m x 3 per container).
# Override with --log-max-size / --log-max-file, or skip with --no-log-config.
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
. "$HERE/AIRGAP_INFO"

# Passed straight through to the engine installer. Nothing about the data
# location is baked into this artifact - one artifact serves every customer.
#   --data-root /mnt/data/docker | --data-root auto | --no-data-root
PASSTHRU=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-root)     PASSTHRU+=(--data-root "${2:-}"); shift 2 ;;
    --no-data-root)  PASSTHRU+=(--no-data-root); shift ;;
    --log-max-size)  PASSTHRU+=(--log-max-size "${2:-}"); shift 2 ;;
    --log-max-file)  PASSTHRU+=(--log-max-file "${2:-}"); shift 2 ;;
    --no-log-config) PASSTHRU+=(--no-log-config); shift ;;
    -h|--help)      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

banner() { printf '\n########################################\n# %s\n########################################\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "must run as root:  sudo bash install-all.sh"

banner "Verifying transfer integrity"
sha256sum -c --quiet SHA256SUMS || fail "checksum mismatch - re-copy the whole folder"
ok "all archives intact"

if [[ -n "${AIRGAP_DOCKER_TARBALL:-}" ]]; then
  banner "Step 1 of 2: Docker Engine"
  d="${AIRGAP_DOCKER_TARBALL%.tar.gz}"
  [[ -d "$d" ]] || tar xzf "$AIRGAP_DOCKER_TARBALL"
  bash "$d/install.sh" "${PASSTHRU[@]+"${PASSTHRU[@]}"}" \
    || fail "Docker Engine install failed (see above). Nothing else was attempted."
else
  banner "Checking Docker is already installed"
  command -v docker >/dev/null || fail "docker is not installed on this machine, and this
        artifact is an image update only. Run the full airgap artifact first."
  docker info >/dev/null 2>&1  || fail "docker is installed but the daemon is not running:
          sudo systemctl start docker"
  ok "$(docker --version)"
fi

if [[ -n "${AIRGAP_IMAGE_TARBALL:-}" ]]; then
  if [[ "${AIRGAP_MODE:-full}" == update ]]; then banner "Loading updated container images"
  else banner "Step 2 of 2: container images"; fi
  i="${AIRGAP_IMAGE_TARBALL%.tar.gz}"; i="${i%.tar}"
  [[ -d "$i" ]] || tar xf "$AIRGAP_IMAGE_TARBALL"
  bash "$i/load.sh" || fail "image load failed (see above)"
else
  banner "Container images - none in this artifact"
fi

banner "All done"
if [[ "${AIRGAP_MODE:-full}" == update ]]; then
cat <<'NEXT'
   The new images are loaded, but NOTHING IS RUNNING THEM YET.
   Loading images does not touch running containers - the stack is still
   on the old ones until you recreate it.

   Finish the update from the directory that holds your docker-compose.yml:

       docker compose up -d

   Then confirm and clean up:

       docker compose ps
       docker image prune        # drops the images the update replaced
NEXT
else
cat <<'NEXT'
   Remaining manual steps:
     1. Log out and back in, so your user picks up the docker group.
     2. Put the compose file and its ./configuration/ directory in place.
     3. Check the region config (upstream ships EU868; US sites need us915).
     4. docker compose up -d
NEXT
fi
RUNALL

cat > "$OUTER/AIRGAP_INFO" <<EOF
AIRGAP_BUILT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
AIRGAP_CODENAME="${CODENAME}"
AIRGAP_ARCH="${ARCH}"
AIRGAP_MODE="${MODE}"
AIRGAP_DOCKER_TARBALL="${DOCKER_TARBALL}"
AIRGAP_IMAGE_TARBALL="${IMAGE_TARBALL}"
EOF

if [[ "$MODE" == update ]]; then
cat > "$OUTER/README.txt" <<EOF
ChirpStack image UPDATE
=======================
This is NOT a full install. It contains updated container images only and
assumes Docker is already installed and running on the server.
Target : linux/${ARCH}
Built  : $(date -u +%Y-%m-%dT%H:%M:%SZ)
$( [[ -n "$CS_VERSION" ]] && printf 'ChirpStack : %s\n' "$CS_VERSION" )

INSTRUCTIONS
------------
1. Copy this whole folder onto the server.
2. Open a terminal in this folder and run:

       sudo bash install-all.sh

3. Then, from the directory containing your docker-compose.yml:

       docker compose up -d

Step 3 is required. Loading images does not restart anything - the stack
keeps running the old images until the containers are recreated.

See VERSIONS.txt for exactly which versions this contains.
EOF
else
cat > "$OUTER/README.txt" <<EOF
Airgap install artifact
=======================
Target : Ubuntu ${CODENAME} / ${ARCH}
Built  : $(date -u +%Y-%m-%dT%H:%M:%SZ)

Contents:
$( [[ -n "$DOCKER_TARBALL" ]] && echo "  ${DOCKER_TARBALL}   Docker Engine, offline apt repo" )
$( [[ -n "$IMAGE_TARBALL"  ]] && echo "  ${IMAGE_TARBALL}   ChirpStack container images" )
$( [[ -n "$VERSIONS_TXT"   ]] && echo "  VERSIONS.txt                          what version of each image is inside" )

INSTRUCTIONS
------------
1. Copy this whole folder onto the server.
2. Open a terminal in this folder.
3. Run exactly:

       sudo bash install-all.sh

Everything runs in the correct order and stops at the first real problem.
No internet connection is needed on the server.

Each inner archive is a complete, self-contained bundle with its own README
and its own installer, so either half can be run on its own if needed.
EOF
fi

if [[ -n "$VERSIONS_TXT" ]]; then
  {
    printf 'Resolved image versions -- %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Exact digests are in the image bundle: images.txt / images.pinned\n\n'
    printf '%-42s %s\n' "IMAGE" "VERSION"
    printf '%s' "$VERSIONS_TXT" | while IFS=$'\t' read -r t v; do
      [[ -n "${t:-}" ]] && printf '%-42s %s\n' "$t" "$v"
    done
  } > "$OUTER/VERSIONS.txt"
fi

pushd "$OUTER" >/dev/null
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
popd >/dev/null

# ------------------------------------------------------------- records ------
# Opt-in convenience: copy the two small text files out of the artifact so they
# can be kept somewhere durable. Same content either way.
if [[ "$RECORDSDIR" != none ]]; then
  mkdir -p "$RECORDSDIR"
  if [[ ! -e "$RECORDSDIR/README.md" ]]; then
    cat > "$RECORDSDIR/README.md" <<'REC'
# Build records

Copies of the small text files from each build.

- `<artifact>.pinned`   image digests. Rebuild that exact bundle with:
                        `--from-list <artifact>.pinned`. This is the rollback
                        path if an update goes badly.
- `<artifact>.versions` human-readable version of each image in that build.
- `builds.log`          one append-only line per build.
REC
  fi

  if [[ -n "$IMAGE_TARBALL" ]]; then
    if tar -xzOf "$OUTER/$IMAGE_TARBALL" --wildcards '*/images.pinned' \
         > "$RECORDSDIR/${NAME}.pinned" 2>/dev/null && [[ -s "$RECORDSDIR/${NAME}.pinned" ]]; then
      :
    else
      rm -f "$RECORDSDIR/${NAME}.pinned"
      echo "    warning: could not extract images.pinned - no rollback record written" >&2
    fi
  fi
  [[ -f "$OUTER/VERSIONS.txt" ]] && cp "$OUTER/VERSIONS.txt" "$RECORDSDIR/${NAME}.versions"

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAME" "$MODE" \
    "chirpstack=${CS_VERSION:-n/a}" "engine=${DOCKER_TARBALL:-none}" \
    >> "$RECORDSDIR/builds.log"
fi

# Outer archive is uncompressed on purpose: the inner tarballs and the image
# layers are already compressed, so gzipping again costs minutes and saves ~0%.
mkdir -p "$OUTDIR"
ARCHIVE="$OUTDIR/${NAME}.tar"
log "packing $ARCHIVE"
tar -C "$STAGE" -cf "$ARCHIVE" "$NAME"

cat <<EOF

########################################
Artifact ready.
  file     : $ARCHIVE
  size     : $(du -h "$ARCHIVE" | cut -f1)
  mode     : $( [[ "$MODE" == update ]] && echo 'IMAGE UPDATE (no Docker Engine)' || echo "full install - Ubuntu ${CODENAME} / ${ARCH}" )
  engine   : ${DOCKER_TARBALL:-(not included)}
  images   : ${IMAGE_TARBALL:-(skipped)}
$( [[ -n "$CS_VERSION" ]] && printf '  chirpstack: %s\n' "$CS_VERSION" )

Hand off with:
  cd $(dirname "$ARCHIVE") && tar xf $(basename "$ARCHIVE") && cd ${NAME} && sudo bash install-all.sh
$( [[ "$RECORDSDIR" != none ]] && cat <<REC

Build records written to $RECORDSDIR:
$( [[ -f "$RECORDSDIR/${NAME}.pinned"   ]] && echo "  ${NAME}.pinned     rollback: --from-list records/${NAME}.pinned" )
$( [[ -f "$RECORDSDIR/${NAME}.versions" ]] && echo "  ${NAME}.versions   what shipped" )
  builds.log
REC
)
EOF
