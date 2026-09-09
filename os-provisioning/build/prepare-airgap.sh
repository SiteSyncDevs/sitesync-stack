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
# Operator's job on the target VM:  sudo bash install.sh
#
# Expects docker-offline-bundle.sh and chirpstack-image-bundle.sh next to this
# script (override with DOCKER_BUNDLE_SH / CHIRPSTACK_BUNDLE_SH).

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_SH="${DOCKER_BUNDLE_SH:-$SELF_DIR/docker-offline-bundle.sh}"
CHIRP_SH="${CHIRPSTACK_BUNDLE_SH:-$SELF_DIR/chirpstack-image-bundle.sh}"
IGNITION_SH="${IGNITION_BUNDLE_SH:-$SELF_DIR/ignition-bundle.sh}"

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
STACK_DIR=""
SKIP_STACK=0
LATEST=0
IMAGES_ONLY=0
SKIP_IGNITION=0
IGNITION_VERSION=""
IGNITION_RUN=""
IGNITION_CACHE=""
DOCKER_ARGS=()
IMAGE_ARGS=()

usage() {
  cat <<'EOF'
Usage: prepare-airgap.sh [options]

  -c, --codename NAME   Target Ubuntu codename (default: noble)
  -a, --arch ARCH       Target arch (default: amd64)
      --skip-docker     Don't build the Docker Engine bundle
      --skip-images     Don't build the ChirpStack image bundle
      --skip-ignition   Don't include the bare-metal Ignition gateway
      --ignition-version VER
                        Pin Ignition to an exact release, e.g. 8.1.53. Without
                        this the newest STABLE 8.1 is downloaded and stamped
                        into the artifact.
      --ignition-run FILE
                        Use a .run already on disk instead of downloading. For
                        a build host with no internet.
      --ignition-cache DIR
                        Where to keep downloaded Ignition installers between
                        builds (default: ~/.cache/sitesync-ignition)
      --skip-stack      Don't include the ChirpStack stack itself (compose file,
                        configuration/, sitesync). Only do this if the target
                        already has them -- without the stack the images have
                        nothing to run.
      --stack-dir DIR   Where the stack repo is (default: this script's parent)
      --compose FILE    Compose file to read the image list from, and to
                        include in the bundle. Defaults to the stack's own
                        docker-compose.yml, which is almost always right.
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
    --skip-ignition) SKIP_IGNITION=1; shift ;;
    --ignition-version) IGNITION_VERSION="$2"; shift 2 ;;
    --ignition-run)     IGNITION_RUN="$2"; shift 2 ;;
    --ignition-cache)   IGNITION_CACHE="$2"; shift 2 ;;
    --skip-stack)   SKIP_STACK=1; shift ;;
    --stack-dir)    STACK_DIR="$2"; shift 2 ;;
    --compose)      COMPOSE_FILE="$2"; shift 2 ;;
    # An image update is about containers. Re-shipping a 1.5 GB Ignition
    # installer to a site that already has a gateway would be a two-gigabyte
    # no-op, so update mode never carries one.
    --images-only)  IMAGES_ONLY=1; LATEST=1; SKIP_DOCKER=1; SKIP_IGNITION=1; shift ;;
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
(( SKIP_DOCKER && SKIP_IMAGES && SKIP_IGNITION )) && die "nothing to do (everything is skipped)"
if (( SKIP_IGNITION )) && [[ -n "$IGNITION_VERSION$IGNITION_RUN" ]]; then
  die "--skip-ignition contradicts --ignition-version/--ignition-run: drop one"
fi
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
(( SKIP_IGNITION )) || [[ -x "$IGNITION_SH" || -f "$IGNITION_SH" ]] || die "not found: $IGNITION_SH"
if (( ! SKIP_IGNITION )) && [[ -n "$IGNITION_RUN" && ! -f "$IGNITION_RUN" ]]; then
  die "--ignition-run file not found: $IGNITION_RUN"
fi
if (( ! SKIP_IMAGES )); then
  command -v docker >/dev/null || die "the image bundle needs a working docker on THIS host (or use --skip-images)"
  docker info >/dev/null 2>&1  || die "docker daemon not reachable on THIS host (or use --skip-images)"
fi
# build/ -> os-provisioning/ -> repo root -> stack/
STACK_DIR="${STACK_DIR:-$(cd -- "$SELF_DIR/../../stack" 2>/dev/null && pwd || echo "$SELF_DIR/../../stack")}"
if (( ! SKIP_STACK )); then
  [[ -d "$STACK_DIR" ]] || die "--stack-dir not found: $STACK_DIR"
  for req in docker-compose.yml sitesync setup.sh .env.example configuration/chirpstack; do
    [[ -e "$STACK_DIR/$req" ]] || die "$STACK_DIR does not look like the stack repo (no $req).
       Point at it with --stack-dir, or use --skip-stack to build without it."
  done
fi
TARGET_DIR="$(cd -- "$SELF_DIR/../target" 2>/dev/null && pwd || echo "")"
[[ -n "$TARGET_DIR" && -d "$TARGET_DIR" ]] || die "not found: $SELF_DIR/../target (the target-side installer)"

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
  # Default to the stack's own compose file, so the image list is READ from
  # what the stack runs rather than kept in step with it by hand.
  [[ -z "$COMPOSE_FILE" && -f "$STACK_DIR/docker-compose.yml" ]] && COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
  if [[ -n "$COMPOSE_FILE" ]]; then
    args+=(--compose "$COMPOSE_FILE")
    if [[ -z "$FROM_LIST" ]]; then
      args+=(--from-compose "$COMPOSE_FILE")
      # The gateway bridges are generated per site into compose/gateways.yml,
      # so their image appears in NO tracked compose file and reading
      # docker-compose.yml alone would leave it out of the artifact. Add it
      # explicitly, at the version the stack ships with.
      _gwv="$(sed -n 's/^GATEWAY_BRIDGE_VERSION=\(.*\)/\1/p' "$STACK_DIR/.env.example" 2>/dev/null | head -1)"
      args+=(--image "chirpstack/chirpstack-gateway-bridge:${_gwv:-4}")
    fi
  fi
  [[ -n "$FROM_LIST"    ]] && args+=(--from-list "$FROM_LIST")
  bash "$CHIRP_SH" "${args[@]}" "${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"}"
  shopt -s nullglob
  found=("$OUTER"/chirpstack-images-*.tar.gz "$OUTER"/chirpstack-images-*.tar)
  (( ${#found[@]} == 1 )) || die "expected exactly one image bundle tarball, got ${#found[@]}"
  IMAGE_TARBALL="$(basename "${found[0]}")"
fi

# ------------------------------------------------------------ 3. stack -------
# The images are useless without the compose file and configuration/ beside
# them. Carry them in the artifact so nothing is placed by hand on site.
STACK_TARBALL=""
STACK_COMMIT=""
if (( ! SKIP_STACK )); then
  log "3/3  ChirpStack stack snapshot"
  STACK_TARBALL="stack.tar.gz"
  if git -C "$STACK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    STACK_COMMIT="$(git -C "$STACK_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    git -C "$STACK_DIR" diff --quiet 2>/dev/null || STACK_COMMIT="${STACK_COMMIT}-dirty"
  fi

  # Per-site secrets must never travel in an artifact that goes to a customer.
  # These exclusions are the security boundary of this whole tool.
  # stack/ contains only what belongs on a customer machine, so this is a
  # directory boundary rather than a long exclude list. What remains to exclude
  # is strictly per-site state that must never travel.
  tar -czf "$OUTER/$STACK_TARBALL" -C "$STACK_DIR" \
    --exclude='./.env' \
    --exclude='./.env.bak.*' \
    --exclude='./mqtt-users.conf' \
    --exclude='./restored-env-*.txt' \
    --exclude='./certs/*.pem' \
    --exclude='./certs/*.crt' \
    --exclude='./certs/*.key' \
    --exclude='./backups' \
    --exclude='./data' \
    --exclude='./lorawan-devices' \
    --exclude='./configuration/mosquitto/conf.d/*.conf' \
    --exclude='./configuration/mosquitto/config/passwd' \
    --exclude='./configuration/mosquitto/config/acl' \
    --exclude='./configuration/chirpstack/chirpstack.toml' \
    --exclude='./compose/gateways.yml' \
    .

  # Refuse to ship an artifact containing a secret, rather than trusting the
  # exclude list to be right.
  leaked="$(tar -tzf "$OUTER/$STACK_TARBALL" \
    | grep -E '(^|/)\.env$|(^|/)mqtt-users\.conf$|(^|/)passwd$|(^|/)acl$|\.pem$|\.key$|(^|/)restored-env-' \
    || true)"
  [[ -z "$leaked" ]] || die "refusing to build: the stack snapshot contains secrets:
$leaked"
  echo "    snapshot: $(du -h "$OUTER/$STACK_TARBALL" | cut -f1)${STACK_COMMIT:+  (commit $STACK_COMMIT)}"
fi

# ----------------------------------------------------------- 4. ignition ----
# Ignition runs on the metal, not in a container, so it is a third payload
# rather than another image: the vendor's .run plus the script that drives it
# unattended. ignition-bundle.sh owns everything about how it is fetched and
# verified; this is only the hand-off.
IGNITION_TARBALL=""
IGNITION_VERSION_RESOLVED=""
if (( ! SKIP_IGNITION )); then
  log "4/4  Ignition gateway (bare metal)"
  ig_args=(--out "$OUTER")
  [[ -n "$IGNITION_VERSION" ]] && ig_args+=(--version "$IGNITION_VERSION")
  [[ -n "$IGNITION_RUN"     ]] && ig_args+=(--installer "$IGNITION_RUN")
  [[ -n "$IGNITION_CACHE"   ]] && ig_args+=(--cache "$IGNITION_CACHE")
  bash "$IGNITION_SH" "${ig_args[@]}" \
    || die "the Ignition bundle failed (see above).
       To build without it:            --skip-ignition
       To use a hand-downloaded file:  --ignition-run ./ignition-8.1.x-linux-64-installer.run"
  shopt -s nullglob
  found=("$OUTER"/ignition-*-linux-64.tar.gz)
  (( ${#found[@]} == 1 )) || die "expected exactly one Ignition tarball, got ${#found[@]}"
  IGNITION_TARBALL="$(basename "${found[0]}")"
  IGNITION_VERSION_RESOLVED="$(sed -nE 's/^ignition-([0-9.]+)-linux-64\.tar\.gz$/\1/p' <<<"$IGNITION_TARBALL")"
  echo "    Ignition ${IGNITION_VERSION_RESOLVED:-unknown}: $(du -h "${found[0]}" | cut -f1)"
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
# The installer is NOT generated here. It lives as real files in
# os-provisioning/target/ so it can be shellchecked, tested and read in a diff
# like any other code. It is copied in verbatim.
log "adding the target-side installer"
cp -a "$TARGET_DIR/install.sh" "$OUTER/install.sh"
cp -a "$TARGET_DIR/steps" "$OUTER/steps"
# The uninstaller ships too, so a bad install can be undone on site without
# waiting for someone to send a script.
# install-all.sh is the pre-2026-09 name, kept as a shim so a tech working from
# an older runbook is not stuck at a customer site with no way to look it up.
for extra in uninstall.sh target-survey.sh install-all.sh; do
  [[ -f "$TARGET_DIR/$extra" ]] && cp -a "$TARGET_DIR/$extra" "$OUTER/$extra"
done
chmod +x "$OUTER/install.sh" "$OUTER"/steps/*.sh
chmod +x "$OUTER"/uninstall.sh "$OUTER"/target-survey.sh 2>/dev/null || true
chmod +x "$OUTER"/install-all.sh 2>/dev/null || true
echo "    steps: $(cd "$OUTER/steps" && ls -1 *.sh | tr '\n' ' ')"

cat > "$OUTER/AIRGAP_INFO" <<EOF
AIRGAP_BUILT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
AIRGAP_CODENAME="${CODENAME}"
AIRGAP_ARCH="${ARCH}"
AIRGAP_MODE="${MODE}"
AIRGAP_DOCKER_TARBALL="${DOCKER_TARBALL}"
AIRGAP_IMAGE_TARBALL="${IMAGE_TARBALL}"
AIRGAP_STACK_TARBALL="${STACK_TARBALL}"
AIRGAP_STACK_COMMIT="${STACK_COMMIT}"
AIRGAP_IGNITION_TARBALL="${IGNITION_TARBALL}"
AIRGAP_IGNITION_VERSION="${IGNITION_VERSION_RESOLVED}"
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

       sudo bash install.sh

The update loads the new images and refreshes the stack files, keeping this
site's .env, certificates and MQTT users exactly as they are.

3. Apply the update:

       cd /opt/sitesync && ./sitesync apply

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
$( [[ -n "$STACK_TARBALL"  ]] && echo "  ${STACK_TARBALL}                         the ChirpStack stack itself${STACK_COMMIT:+ (commit ${STACK_COMMIT})}" )
$( [[ -n "$IGNITION_TARBALL" ]] && echo "  ${IGNITION_TARBALL}   Ignition ${IGNITION_VERSION_RESOLVED}, installed on the metal" )
$( [[ -n "$VERSIONS_TXT"   ]] && echo "  VERSIONS.txt                          what version of each image is inside" )

INSTRUCTIONS
------------
1. Copy this whole folder onto the server.
2. Open a terminal in this folder.
3. Run exactly:

       sudo bash install.sh

It will ask you a short list of questions about this site near the end.

Everything runs in the correct order and stops at the first real problem,
leaving the machine in a state you can re-run from:

       sudo bash install.sh --resume

No internet connection is needed on the server.

WHAT IT DOES, IN ORDER
  00  checks this machine before changing anything
  10  installs Docker Engine from the offline package repo
$( [[ -n "$IGNITION_TARBALL" ]] && echo "  15  installs Ignition ${IGNITION_VERSION_RESOLVED} on the metal and starts the gateway" )
  20  loads the container images
  30  installs the stack to /opt/sitesync
  40  asks the site questions and writes the settings
  50  starts it and prints the address

Everything it prints is also saved to /var/log/sitesync-airgap/.
That log is the one thing to send if you need help.
EOF
fi

if [[ -n "$VERSIONS_TXT" || -n "$IGNITION_VERSION_RESOLVED" ]]; then
  {
    printf 'Resolved versions -- %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Exact digests are in the image bundle: images.txt / images.pinned\n\n'
    if [[ -n "$VERSIONS_TXT" ]]; then
      printf '%-42s %s\n' "IMAGE" "VERSION"
      printf '%s' "$VERSIONS_TXT" | while IFS=$'\t' read -r t v; do
        [[ -n "${t:-}" ]] && printf '%-42s %s\n' "$t" "$v"
      done
      printf '\n'
    fi
    if [[ -n "$IGNITION_VERSION_RESOLVED" ]]; then
      printf '%-42s %s\n' "BARE METAL" "VERSION"
      printf '%-42s %s\n' "ignition (gateway)" "$IGNITION_VERSION_RESOLVED"
      # The vendor's own checksum, carried out of the inner bundle so the
      # record of what shipped does not depend on unpacking it again.
      _igsha="$(tar -xzOf "$OUTER/$IGNITION_TARBALL" --wildcards '*/IGNITION_INFO' 2>/dev/null \
                 | sed -n 's/^IGNITION_SHA256="\(.*\)"$/\1/p' | head -1)"
      [[ -n "$_igsha" ]] && printf '%-42s %s\n' "  installer sha256" "$_igsha"
    fi
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

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAME" "$MODE" \
    "chirpstack=${CS_VERSION:-n/a}" "engine=${DOCKER_TARBALL:-none}" \
    "ignition=${IGNITION_VERSION_RESOLVED:-none}" \
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
  stack    : ${STACK_TARBALL:-(not included)}${STACK_COMMIT:+  commit ${STACK_COMMIT}}
  ignition : ${IGNITION_TARBALL:-(not included)}
$( [[ -n "$CS_VERSION" ]] && printf '  chirpstack: %s\n' "$CS_VERSION" )

Hand off with:
  cd $(dirname "$ARCHIVE") && tar xf $(basename "$ARCHIVE") && cd ${NAME} && sudo bash install.sh
$( [[ "$RECORDSDIR" != none ]] && cat <<REC

Build records written to $RECORDSDIR:
$( [[ -f "$RECORDSDIR/${NAME}.pinned"   ]] && echo "  ${NAME}.pinned     rollback: --from-list records/${NAME}.pinned" )
$( [[ -f "$RECORDSDIR/${NAME}.versions" ]] && echo "  ${NAME}.versions   what shipped" )
  builds.log
REC
)
EOF
