#!/usr/bin/env bash
# Puts the ChirpStack stack itself on the machine: the compose file, the whole
# configuration/ tree, the sitesync command and its scripts.
#
# This is the step whose absence used to mean "put the compose file and its
# ./configuration/ directory in place" by hand -- and containers that start and
# immediately die when it was done wrong.
set -Eeuo pipefail
banner() { printf '\n########################################\n# %s\n########################################\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
warn() { printf '   [ note ] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
cd "$AIRGAP_HERE"

DEST="${AIRGAP_INSTALL_DIR:-/opt/sitesync}"

if [[ -z "${AIRGAP_STACK_TARBALL:-}" ]]; then
  banner "Step 30: stack files - none in this artifact"
  echo "   This artifact carries no stack snapshot, so nothing was installed to $DEST."
  exit 0
fi

banner "Step 30: installing the stack to $DEST"

# The stack lived at /opt/sitesync-chirpstack until 2026-09. On a box
# provisioned under the old name, installing to the new one silently leaves two
# copies -- and the old one still holds the site's real .env and certificates,
# so it is the one worth keeping. Say so rather than letting the tech discover
# it when the wrong directory is the one they edit.
LEGACY_DEST=/opt/sitesync-chirpstack
if [[ "$DEST" != "$LEGACY_DEST" && -d "$LEGACY_DEST" ]]; then
  warn "this machine has an older install at $LEGACY_DEST."
  if [[ -f "$LEGACY_DEST/.env" ]]; then
    warn "it holds a configured site (.env, certificates, MQTT users)."
    warn "To carry that site over to $DEST instead of starting fresh, stop here"
    warn "and run:"
    warn "    sudo bash install-all.sh --install-dir $LEGACY_DEST"
    warn "or move it first:"
    warn "    cd /opt && sudo systemctl stop 'sitesync-chirpstack-*' 2>/dev/null; sudo mv $LEGACY_DEST $DEST"
  else
    warn "it is unconfigured, so nothing is lost by leaving it; delete it when convenient."
  fi
  warn "continuing with $DEST."
fi

# An existing install is never overwritten blindly -- it holds the site's .env,
# certificates and MQTT users.
if [[ -d "$DEST" ]]; then
  BACKUP="$DEST.replaced-$(date -u +%Y%m%d-%H%M%S)"
  if [[ -f "$DEST/.env" ]]; then
    warn "$DEST already exists and has a configured site in it."
    warn "keeping .env, certs/, mqtt-users.conf and backups/; the rest is replaced."
    KEEP="$(mktemp -d)"
    for item in .env certs mqtt-users.conf backups; do
      [[ -e "$DEST/$item" ]] && cp -a "$DEST/$item" "$KEEP/" || true
    done
    mv "$DEST" "$BACKUP"
    mkdir -p "$DEST"
    tar xzf "$AIRGAP_STACK_TARBALL" -C "$DEST"
    for item in .env certs mqtt-users.conf backups; do
      [[ -e "$KEEP/$item" ]] && cp -a "$KEEP/$item" "$DEST/" || true
    done
    rm -rf "$KEEP"
    ok "upgraded in place; the previous copy is at $BACKUP"
  else
    mv "$DEST" "$BACKUP"
    mkdir -p "$DEST"
    tar xzf "$AIRGAP_STACK_TARBALL" -C "$DEST"
    ok "replaced an unconfigured install; the previous copy is at $BACKUP"
  fi
else
  mkdir -p "$DEST"
  tar xzf "$AIRGAP_STACK_TARBALL" -C "$DEST"
  ok "installed"
fi

# The files must be usable by the person who ran sudo, not only by root.
OWNER="${SUDO_USER:-root}"
if [[ "$OWNER" != root ]] && id "$OWNER" >/dev/null 2>&1; then
  chown -R "$OWNER":"$(id -gn "$OWNER")" "$DEST"
  ok "owned by $OWNER"
  # So they can run ./sitesync without sudo -- takes effect at next login.
  if ! id -nG "$OWNER" | tr ' ' '\n' | grep -qx docker; then
    usermod -aG docker "$OWNER" && ok "added $OWNER to the docker group (needs a re-login)"
  fi
fi

chmod +x "$DEST/sitesync" "$DEST/setup.sh" 2>/dev/null || true
chmod +x "$DEST"/scripts/*.sh "$DEST"/os-provisioning/*.sh 2>/dev/null || true
[[ -f "$DEST/.env" ]] && chmod 600 "$DEST/.env"

# Prove the snapshot is complete rather than discovering it at first start.
for required in docker-compose.yml sitesync setup.sh .env.example \
                scripts/lib-regions.sh \
                configuration/chirpstack/chirpstack.toml.template \
                configuration/mosquitto/config/mosquitto.conf \
                configuration/postgresql/initdb; do
  [[ -e "$DEST/$required" ]] || fail "the stack snapshot is missing $required.
        The artifact was built incorrectly - rebuild it with prepare-airgap.sh."
done
n_regions=$(find "$DEST/configuration/chirpstack" -name 'region_*.toml' | wc -l)
(( n_regions > 0 )) || fail "the snapshot contains no region files - rebuild the artifact."
ok "snapshot verified: compose, configuration and $n_regions region files present"
