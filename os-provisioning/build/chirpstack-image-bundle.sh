#!/usr/bin/env bash
#
# chirpstack-image-bundle.sh
#
# Pulls the ChirpStack container images and packs them into an airgap transfer
# bundle. Standalone: the image list is baked in, no compose file required.
#
# Companion to docker-offline-bundle.sh -- run that first on the target VM so
# Docker exists, then this bundle's load.sh.
#
# Build host: any machine with a working docker. Root not required.

set -Eeuo pipefail

# --------------------------------------------------------------- image set ---
# FALLBACK ONLY. The real list is read out of the compose file itself with
# --from-compose, because a hand-maintained copy of it drifts: the caddy image
# was added to the stack and missing here, which would have produced an
# artifact whose stack could not start on an airgapped machine.
#
# chirpstack-gateway-bridge appears twice in compose (udp + basicstation);
# it is one image, listed once.
DEFAULT_IMAGES=(
  chirpstack/chirpstack:4
  chirpstack/chirpstack-gateway-bridge:4
  chirpstack/chirpstack-rest-api:4
  postgres:14-alpine
  redis:7-alpine
  eclipse-mosquitto:2
  caddy:2
)

# ---------------------------------------------------------------- defaults ---
PLATFORM="linux/amd64"
OUTDIR=""                # default: ./artifacts
NAME=""
FROM_LIST=""
FROM_COMPOSE=""
COMPOSE_FILE=""
EXTRA=()
NO_PULL=0
NO_COMPRESS=0
ALLOW_ARCH_MISMATCH=0

usage() {
  cat <<'EOF'
Usage: chirpstack-image-bundle.sh [options]

      --platform P        Target platform (default: linux/amd64)
      --image REF         Add an image to the set (repeatable)
      --only REF          Use ONLY these images instead of the built-in set
                          (repeatable)
      --from-list FILE    Reproducible rebuild: read an images.pinned file from
                          a previous bundle and pull those exact digests
      --compose FILE      Copy a compose file into the bundle for reference
      --from-compose FILE Read the image list OUT of this compose file, so it
                          can never disagree with what the stack actually runs.
                          Every profile is included: the artifact must serve a
                          customer whatever they switch on.
      --no-pull           Use whatever is already in the local image cache
      --no-compress       Emit .tar instead of .tar.gz
      --allow-arch-mismatch
                          Warn instead of failing when an image's architecture
                          does not match --platform
  -o, --out DIR           Where to write the bundle (default: ./artifacts)
  -n, --name NAME         Bundle basename (default: chirpstack-images-<date>)
  -h, --help              This text

Built-in image set:
EOF
  printf '  %s\n' "${DEFAULT_IMAGES[@]}"
}

ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)  PLATFORM="$2"; shift 2 ;;
    --image)     EXTRA+=("$2"); shift 2 ;;
    --only)      ONLY+=("$2"); shift 2 ;;
    --from-list) FROM_LIST="$2"; shift 2 ;;
    --compose)   COMPOSE_FILE="$2"; shift 2 ;;
    --from-compose) FROM_COMPOSE="$2"; shift 2 ;;
    --no-pull)   NO_PULL=1; shift ;;
    --no-compress) NO_COMPRESS=1; shift ;;
    --allow-arch-mismatch) ALLOW_ARCH_MISMATCH=1; shift ;;
    -o|--out)    OUTDIR="$2"; shift 2 ;;
    -n|--name)   NAME="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '==> %s\n' "$*"; }
warn() { printf '    [warn] %s\n' "$*" >&2; }

command -v docker >/dev/null || die "docker not found in PATH"
docker info >/dev/null 2>&1 || die "docker daemon not reachable (need a working docker on THIS host)"
for b in tar gzip sha256sum; do command -v "$b" >/dev/null || die "missing required tool: $b"; done

NAME="${NAME:-chirpstack-images-$(date -u +%Y%m%d)}"

# ------------------------------------------------------- reference helpers ---
# Registry-port safe: myreg:5000/foo/bar:tag -> repo=myreg:5000/foo/bar tag=tag
ref_repo() {
  local r="${1%%@*}" last
  last="${r##*/}"
  [[ "$last" == *:* ]] && r="${r%:*}"
  printf '%s' "$r"
}
ref_tag() {
  local r="${1%%@*}" last
  last="${r##*/}"
  if [[ "$last" == *:* ]]; then printf '%s' "${last##*:}"; else printf 'latest'; fi
}

# Read the images a compose file actually references, with every profile on.
compose_images() {  # compose_images <compose-file>  -> one image per line
  local f="$1" envf prof
  envf="$(mktemp)"
  printf 'POSTGRES_PASSWORD=x\nCHIRPSTACK_API_SECRET=x\nREGION=eu868\n' > "$envf"
  prof="$(docker compose -f "$f" --env-file "$envf" config --profiles 2>/dev/null | paste -sd, - || true)"
  COMPOSE_PROFILES="$prof" docker compose -f "$f" --env-file "$envf" config --images 2>/dev/null | sed '/^$/d'
  rm -f "$envf"
}

# ------------------------------------------------------------ build the set --
# TAGS[i]  = the friendly repo:tag the compose file references
# PULLS[i] = what we actually pull (a digest ref when reproducing a bundle)
TAGS=(); PULLS=()

if [[ -n "$FROM_LIST" ]]; then
  [[ -f "$FROM_LIST" ]] || die "--from-list file not found: $FROM_LIST"
  while IFS=$'\t' read -r tag pull _; do
    [[ -z "${tag:-}" || "$tag" == \#* ]] && continue
    TAGS+=("$tag"); PULLS+=("${pull:-$tag}")
  done < "$FROM_LIST"
  (( ${#TAGS[@]} )) || die "no usable entries in $FROM_LIST"
  log "reproducible rebuild from $FROM_LIST (${#TAGS[@]} pinned images)"
else
  SET=("${DEFAULT_IMAGES[@]}")

  # Read the image list straight out of the compose file. Every profile is
  # enabled, and a scratch env file supplies only the variables compose refuses
  # to run without -- so the versions resolved are the ${VAR:-default} ones the
  # stack ships with, never whatever happens to be in a local .env.
  if [[ -n "$FROM_COMPOSE" ]]; then
    [[ -f "$FROM_COMPOSE" ]] || die "--from-compose file not found: $FROM_COMPOSE"
    command -v docker >/dev/null || die "--from-compose needs docker on this host to read the compose file"
    mapfile -t _derived < <(compose_images "$FROM_COMPOSE")
    (( ${#_derived[@]} )) || die "could not read any images out of $FROM_COMPOSE.
       Check it with:  docker compose -f $FROM_COMPOSE config --images"
    SET=("${_derived[@]}")
    log "image list read from $(basename "$FROM_COMPOSE") (${#_derived[@]} images, all profiles)"
  fi

  (( ${#ONLY[@]} )) && SET=("${ONLY[@]}")
  (( ${#EXTRA[@]} )) && SET+=("${EXTRA[@]}")
  # dedupe, preserve order
  for ref in "${SET[@]}"; do
    [[ " ${TAGS[*]:-} " == *" $ref "* ]] && continue
    TAGS+=("$ref"); PULLS+=("$ref")
  done
fi

log "${#TAGS[@]} image(s) for $PLATFORM"
printf '    %s\n' "${TAGS[@]}"

# Whatever built the list -- built-in set, --only, --from-list -- it must cover
# every image the stack actually runs. An image missing here is not noticed
# until a container will not start on a machine with no internet, which is the
# worst possible place to find out.
_check="${FROM_COMPOSE:-$COMPOSE_FILE}"
if [[ -n "$_check" && -f "$_check" ]] && command -v docker >/dev/null; then
  _missing=()
  while read -r want; do
    [[ -z "$want" ]] && continue
    _base="${want%@*}"                       # ignore any digest suffix
    _hit=0
    for have in "${TAGS[@]}"; do [[ "${have%@*}" == "$_base" ]] && _hit=1 && break; done
    (( _hit )) || _missing+=("$want")
  done < <(compose_images "$_check")
  if (( ${#_missing[@]} )); then
    die "$(basename "$_check") runs these images, but they are not in this bundle:
       ${_missing[*]}
       The stack would fail to start on a machine with no internet.
       Build with --from-compose $_check so the list is taken from the compose
       file instead of a hand-maintained copy."
  fi
  echo "    verified: every image in $(basename "$_check") is in this bundle"
fi

# --------------------------------------------------------------- staging -----
STAGE="$(mktemp -d /tmp/cs-images.XXXXXX)"
BUNDLE="$STAGE/$NAME"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
mkdir -p "$BUNDLE"

# ------------------------------------------------------------------ pull -----
if (( NO_PULL )); then
  log "--no-pull: using the local image cache as-is"
else
  log "pulling images"
  for i in "${!PULLS[@]}"; do
    printf '    %s\n' "${PULLS[$i]}"
    docker pull -q --platform "$PLATFORM" "${PULLS[$i]}" >/dev/null \
      || die "pull failed: ${PULLS[$i]}"
  done
fi

# Pulling by digest leaves the image untagged, so `docker save` would produce an
# archive that loads as <none>:<none> and the compose file's `image: ...:4`
# would not resolve. Re-apply the friendly tag before saving.
for i in "${!TAGS[@]}"; do
  if [[ "${PULLS[$i]}" != "${TAGS[$i]}" ]]; then
    docker tag "${PULLS[$i]}" "${TAGS[$i]}" || die "could not tag ${PULLS[$i]} as ${TAGS[$i]}"
  fi
done

# -------------------------------------------------- manifest + digest pins ---
log "recording digests and architectures"
MANIFEST="$BUNDLE/images.txt"
PINNED="$BUNDLE/images.pinned"
{ printf '# TAG\tOS/ARCH\tDIGEST_REF\tIMAGE_ID\n'; } > "$MANIFEST"
{ printf '# TAG\tDIGEST_REF   -- feed back in with --from-list for an identical rebuild\n'; } > "$PINNED"

MISMATCH=0
WANT_OSARCH="$(printf '%s' "$PLATFORM" | cut -d/ -f1,2)"

for tag in "${TAGS[@]}"; do
  docker image inspect "$tag" >/dev/null 2>&1 || die "image not present locally: $tag (drop --no-pull?)"
  repo="$(ref_repo "$tag")"
  osarch="$(docker image inspect "$tag" --format '{{.Os}}/{{.Architecture}}')"
  imgid="$(docker image inspect "$tag" --format '{{.Id}}')"
  digest="$(docker image inspect "$tag" --format '{{range .RepoDigests}}{{println .}}{{end}}' \
              | grep -m1 "^${repo}@" || true)"
  [[ -n "$digest" ]] || digest="<none>"

  printf '%s\t%s\t%s\t%s\n' "$tag" "$osarch" "$digest" "$imgid" >> "$MANIFEST"
  if [[ "$digest" != "<none>" ]]; then
    printf '%s\t%s\n' "$tag" "$digest" >> "$PINNED"
  else
    printf '%s\t%s\n' "$tag" "$tag" >> "$PINNED"
    warn "$tag has no registry digest (built locally or loaded from a tar) - not reproducibly pinned"
  fi

  if [[ "$osarch" != "$WANT_OSARCH" ]]; then
    warn "$tag is $osarch, expected $WANT_OSARCH"
    MISMATCH=1
  fi
done

if (( MISMATCH )); then
  if (( ALLOW_ARCH_MISMATCH )); then
    warn "architecture mismatch overridden by --allow-arch-mismatch"
  else
    die "architecture mismatch (see warnings above).
       A wrong-arch image only fails when the container starts, on site.
       Fix: docker image rm the offending tags and re-run without --no-pull,
       or pass --allow-arch-mismatch if you know what you are doing."
  fi
fi

# ------------------------------------------------------------------ save -----
# One archive for the whole set: docker save dedupes layers shared between the
# three chirpstack images and between the alpine-based postgres/redis/mosquitto.
log "saving ${#TAGS[@]} images to images.tar"
docker save -o "$BUNDLE/images.tar" "${TAGS[@]}"
printf '    %s\n' "$(du -h "$BUNDLE/images.tar" | cut -f1) uncompressed"

if [[ -n "$COMPOSE_FILE" ]]; then
  [[ -f "$COMPOSE_FILE" ]] || die "--compose file not found: $COMPOSE_FILE"
  cp -- "$COMPOSE_FILE" "$BUNDLE/docker-compose.yml"
  log "included $(basename "$COMPOSE_FILE") for reference"
fi

# ------------------------------------------------------------- loader --------
cat > "$BUNDLE/load.sh" <<'LOADER'
#!/usr/bin/env bash
# Load the bundled ChirpStack images on the airgapped host.
#     sudo bash load.sh        (or plain 'bash load.sh' if you are in the docker group)
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
warn() { printf '   [warn] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || fail "docker not found - install Docker Engine first"
docker info >/dev/null 2>&1 || fail "cannot talk to the docker daemon.
        If you were just added to the docker group, log out and back in,
        or re-run with sudo."

say "Verifying bundle integrity"
sha256sum -c --quiet SHA256SUMS || fail "checksum mismatch - re-copy the bundle"
ok "all files intact"

say "Loading images"
docker load -i images.tar | sed 's/^/   /'

say "Verifying every expected image is present"
MISSING=0
while IFS=$'\t' read -r tag osarch digest _; do
  [[ -z "${tag:-}" || "$tag" == \#* ]] && continue
  if have="$(docker image inspect "$tag" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null)"; then
    if [[ "$have" == "$osarch" ]]; then ok "$tag ($have)"
    else warn "$tag is $have, bundle recorded $osarch"; fi
  else
    warn "$tag MISSING after load"; MISSING=1
  fi
done < images.txt
(( MISSING == 0 )) || fail "one or more images did not load"

say "Done. Images are in the local cache."
echo "   These are the exact tags your compose file references, so"
echo "   'docker compose up -d' will use them without contacting a registry."
if timeout 5 bash -c 'exec 3<>/dev/tcp/registry-1.docker.io/443' 2>/dev/null; then
  echo
  echo "   This box can reach Docker Hub, so 'docker compose pull' would also"
  echo "   work - but it defeats the point: it may fetch a newer :4 than the"
  echo "   one just verified here. Use 'up -d' and let these images stand."
else
  echo
  echo "   No registry reachable from here, so:"
  echo "     - do NOT run 'docker compose pull' (it will fail)"
  echo "     - if a service is set to always pull, add to that service:"
  echo "           pull_policy: never"
fi
LOADER
chmod +x "$BUNDLE/load.sh"

# ------------------------------------------------------------- readme --------
cat > "$BUNDLE/README.txt" <<EOF
ChirpStack container images - airgap transfer bundle
====================================================
Built    : $(date -u +%Y-%m-%dT%H:%M:%SZ)
Platform : ${PLATFORM}
Images   : ${#TAGS[@]}

INSTRUCTIONS
------------
1. Docker must already be installed on this server. If it is not, run the
   Docker offline bundle first.
2. Copy this whole folder onto the server.
3. Open a terminal in this folder and run:

       sudo bash load.sh

4. Every line of the verification output should say [ ok ].

WHAT THIS IS AND IS NOT
-----------------------
This bundle contains container IMAGES only. To actually run ChirpStack you
also need, from the upstream chirpstack-docker repository:

  - the docker-compose.yml
  - the ./configuration/ directory (chirpstack toml config, the
    chirpstack-gateway-bridge toml files, mosquitto.conf, and the
    postgresql initdb SQL)

Those are plain text and are not included here unless --compose was used.
Without ./configuration/ the containers start and immediately fail.

REGION SETTING
--------------
The upstream gateway-bridge config is EU868. For US deployments the
gateway-bridge topic templates and the chirpstack region config must be
changed to us915 before this stack is useful.

IMAGE LIST
----------
$(cut -f1 "$MANIFEST" | grep -v '^#' | sed 's/^/  /')

REPRODUCIBLE REBUILD
--------------------
images.pinned records the digest each floating tag resolved to. To rebuild a
byte-identical bundle later:

    ./chirpstack-image-bundle.sh --from-list images.pinned

LAYOUT
------
images.tar     all images in one archive (layers deduped)
images.txt     tag, os/arch, digest, image id
images.pinned  tag -> digest, for --from-list
load.sh        the loader
SHA256SUMS     integrity checksums, verified automatically
EOF

# ---------------------------------------------------------- checksums --------
log "writing checksums"
pushd "$BUNDLE" >/dev/null
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
popd >/dev/null

# --------------------------------------------------------------- pack --------
mkdir -p "$OUTDIR"
if (( NO_COMPRESS )); then
  ARCHIVE="$OUTDIR/${NAME}.tar"
  log "packing $ARCHIVE"
  tar -C "$STAGE" -cf "$ARCHIVE" "$NAME"
else
  ARCHIVE="$OUTDIR/${NAME}.tar.gz"
  log "packing $ARCHIVE"
  # images.tar is already-compressed layer blobs; gzip buys little, so use pigz
  # when available purely to keep the wall time down.
  if command -v pigz >/dev/null; then
    tar -C "$STAGE" -cf - "$NAME" | pigz -6 > "$ARCHIVE"
  else
    tar -C "$STAGE" -czf "$ARCHIVE" "$NAME"
  fi
fi

cat <<EOF

Bundle ready.
  file      : $ARCHIVE
  size      : $(du -h "$ARCHIVE" | cut -f1)
  images    : ${#TAGS[@]}
  platform  : ${PLATFORM}

Hand off with:
  tar xzf $(basename "$ARCHIVE") && cd ${NAME} && sudo bash load.sh
EOF
