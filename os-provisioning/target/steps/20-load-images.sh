#!/usr/bin/env bash
# Loads the ChirpStack container images from the artifact into the local daemon.
set -Eeuo pipefail
banner() { printf '\n########################################\n# %s\n########################################\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
cd "$AIRGAP_HERE"

if [[ -z "${AIRGAP_IMAGE_TARBALL:-}" ]]; then
  banner "Step 20: container images - none in this artifact"
  exit 0
fi

banner "Step 20: container images"
i="${AIRGAP_IMAGE_TARBALL%.tar.gz}"; i="${i%.tar}"
[[ -d "$i" ]] || tar xf "$AIRGAP_IMAGE_TARBALL"
bash "$i/load.sh" || fail "image load failed (see above)"

# docker save/load drops RepoDigests, so the digests in images.pinned are the
# only record of what these actually are. Confirm the tags at least arrived.
if [[ -f "$i/images.txt" ]]; then
  missing=()
  while IFS=$'\t' read -r tag _; do
    [[ -z "${tag:-}" || "${tag:0:1}" == "#" ]] && continue
    docker image inspect "$tag" >/dev/null 2>&1 || missing+=("$tag")
  done < "$i/images.txt"
  (( ${#missing[@]} == 0 )) || fail "these images did not load: ${missing[*]}"
  ok "every image in the bundle is present locally"
fi
