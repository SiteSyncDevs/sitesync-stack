#!/usr/bin/env bash
#
# uninstall-all.sh
#
# Undoes everything install-all.sh does, so a test VM can be re-run from a
# clean slate without rebuilding it. Run on the TARGET:
#
#     sudo bash uninstall-all.sh            # asks before doing anything
#     sudo bash uninstall-all.sh --yes      # no prompt
#     sudo bash uninstall-all.sh --dry-run  # print the plan, change nothing
#
# THIS IS A TEST-RESET TOOL. It destroys every container, image and named
# volume on the machine, including the ChirpStack postgres and redis data.
# It is not a maintenance script and has no business on a customer VM.
#
# NOT removed, on purpose: /var/log/sitesync-airgap (the install logs -- the
# record of what happened, and the first thing to ask for when something went
# wrong). Delete it by hand if you want the machine truly pristine.
#
# It is deliberately standalone: it takes no arguments from the artifact and
# reads no bundle metadata, so it still works when the artifact folder is gone
# or the install died halfway through. Everything it removes is either
# discovered from the live system or a fixed path the installer writes.
#
# What it reverses, in the order install.sh created it:
#   - every container, image and named volume, removed through Docker itself
#     so it works wherever --data-root points (a separate disk included)
#   - the six Docker packages and (opt-in) their auto-installed closure
#   - /etc/docker/daemon.json          and the .bak install.sh leaves
#   - /etc/containerd/config.toml      and the .bak install.sh leaves
#   - the RequiresMountsFor drop-ins on docker.service / containerd.service
#   - Docker's data-root and containerd's root, wherever they were pointed
#   - /var/lib/docker, /var/lib/containerd
#   - the docker group and the group membership install.sh granted
#   - the apt key and repo definition, if enable-online-updates.sh ever ran
#   - scratch files install.sh leaves behind when it fails mid-run
#   - the sitesync-chirpstack-*.service boot unit, disabled and deleted
#   - /opt/sitesync-chirpstack and its .replaced-* copies (the stack, the site
#     settings, certificates and MQTT users), plus /var/lib/sitesync-airgap
#     (the install step markers that drive --resume)

set -Eeuo pipefail

YES=0
DRY=0
AUTOREMOVE=0
KEEP_PACKAGES=0
KEEP_DATA=0
KEEP_GROUP=0
EXTRA_ROOTS=()
STACK_DIR_TARGET="${STACK_DIR_TARGET:-/opt/sitesync-chirpstack}"

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; cat <<'EOF'

Options:
  -y, --yes            Don't prompt for confirmation
  -n, --dry-run        Print what would be removed and exit
      --autoremove     Also 'apt-get autoremove --purge' the closure Docker
                       pulled in (pigz, git, apparmor...). Off by default:
                       autoremove judges by what is auto-installed, and on a
                       box that had those already it will not touch them --
                       but on a fresh VM it removes them, which is usually
                       what you want when resetting for a test.
      --keep-packages  Wipe config and data only; leave Docker installed
      --keep-data      Remove packages; leave the data roots on disk
      --keep-group     Leave the 'docker' group and its members alone
      --root PATH      Also remove this directory as a Docker/containerd root
                       (repeatable; for a root that can no longer be discovered
                       because daemon.json is already gone)
  -h, --help           This text
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)        YES=1; shift ;;
    -n|--dry-run)    DRY=1; shift ;;
    --autoremove)    AUTOREMOVE=1; shift ;;
    --keep-packages) KEEP_PACKAGES=1; shift ;;
    --keep-data)     KEEP_DATA=1; shift ;;
    --keep-group)    KEEP_GROUP=1; shift ;;
    --root)          EXTRA_ROOTS+=("${2:-}"); shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   [ ok ] %s\n' "$*"; }
warn() { printf '   [warn] %s\n' "$*"; }
skip() { printf '   [skip] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
run()  { if (( DRY )); then printf '   [dry ] %s\n' "$*"; else eval "$@"; fi; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "must run as root:  sudo bash uninstall-all.sh"

DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin
             docker-compose-plugin docker-ce-rootless-extras)

# ---------------------------------------------------------------- discover ---
# Everything destructive below acts on paths found here, never on guesses. Do
# this while the daemon is still up: 'docker info' is the most authoritative
# answer, and it stops being available the moment we disable the service.
say "Surveying what is installed"

INSTALLED=()
for p in "${DOCKER_PKGS[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 && INSTALLED+=("$p")
done
if (( ${#INSTALLED[@]} )); then
  ok "packages present: ${INSTALLED[*]}"
else
  skip "none of the Docker packages are installed"
fi

DOCKER_ROOT=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  DOCKER_ROOT="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
  ok "daemon running, data-root: ${DOCKER_ROOT:-unknown}"
fi
# Fall back to the config file when the daemon is dead or was never started.
if [[ -z "$DOCKER_ROOT" && -s /etc/docker/daemon.json ]] && command -v python3 >/dev/null; then
  DOCKER_ROOT="$(python3 - <<'PY' 2>/dev/null || true
import json
try:
    print(json.load(open("/etc/docker/daemon.json")).get("data-root", ""))
except Exception:
    pass
PY
)"
  [[ -n "$DOCKER_ROOT" ]] && ok "data-root from daemon.json: $DOCKER_ROOT"
fi

CONTAINERD_ROOT=""
if [[ -f /etc/containerd/config.toml ]]; then
  CONTAINERD_ROOT="$(grep -m1 -E '^[[:space:]]*root[[:space:]]*=' /etc/containerd/config.toml \
                     | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' || true)"
  [[ -n "$CONTAINERD_ROOT" ]] && ok "containerd root from config.toml: $CONTAINERD_ROOT"
fi

# Candidate directories, deduplicated. The two /var/lib paths are always
# candidates: even with --data-root set, the package install populates them
# briefly before the relocation takes effect.
ROOTS=()
for d in "$DOCKER_ROOT" "$CONTAINERD_ROOT" /var/lib/docker /var/lib/containerd \
         "${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"}"; do
  [[ -n "$d" ]] || continue
  for seen in "${ROOTS[@]+"${ROOTS[@]}"}"; do [[ "$seen" == "$d" ]] && continue 2; done
  ROOTS+=("$d")
done

# A wrong path here is an unrecoverable rm -rf, so each one has to prove it is
# a container root before it is eligible. Refusing is always safe; the operator
# can delete a stubborn directory by hand.
DELETABLE=()
UNSURE=()
for d in "${ROOTS[@]+"${ROOTS[@]}"}"; do
  [[ -d "$d" ]] || continue
  case "$d" in
    /|/usr|/etc|/var|/home|/root|/boot|/mnt|/opt|/srv|/var/lib) UNSURE+=("$d (refusing: system directory)"); continue ;;
  esac
  [[ "$d" == /* ]] || { UNSURE+=("$d (refusing: not an absolute path)"); continue; }
  (( $(tr -cd / <<<"$d" | wc -c) >= 2 )) || { UNSURE+=("$d (refusing: too close to the root of the tree)"); continue; }
  if [[ -d "$d/overlay2" || -d "$d/image" || -d "$d/containers" || -d "$d/buildkit" \
     || -d "$d/io.containerd.content.v1.content" || -d "$d/io.containerd.snapshotter.v1.overlayfs" ]]; then
    DELETABLE+=("$d")
  elif [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then
    DELETABLE+=("$d")   # created by install.sh, never populated
  else
    UNSURE+=("$d (refusing: does not look like a Docker or containerd root)")
  fi
done

DROPINS=(/etc/systemd/system/docker.service.d/10-data-root.conf
         /etc/systemd/system/containerd.service.d/10-data-root.conf)
CONFIGS=(/etc/docker/daemon.json /etc/docker/daemon.json.bak
         /etc/containerd/config.toml /etc/containerd/config.toml.bak)
APTBITS=(/etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg)

# ------------------------------------------------------------------ plan -----
say "Plan"
if (( KEEP_PACKAGES )); then
  skip "packages (--keep-packages)"
elif (( ${#INSTALLED[@]} )); then
  echo "   purge: ${INSTALLED[*]}"
  (( AUTOREMOVE )) && echo "   then: apt-get autoremove --purge"
fi
for f in "${DROPINS[@]}" "${CONFIGS[@]}" "${APTBITS[@]}"; do
  [[ -e "$f" ]] && echo "   remove file: $f"
done
if (( KEEP_DATA )); then
  skip "data roots (--keep-data)"
else
  for d in "${DELETABLE[@]+"${DELETABLE[@]}"}"; do
    printf '   DELETE TREE: %-34s (%s)\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1 || echo '?')"
  done
fi
for u in "${UNSURE[@]+"${UNSURE[@]}"}"; do warn "$u"; done
if (( KEEP_GROUP )); then
  skip "docker group (--keep-group)"
elif getent group docker >/dev/null; then
  echo "   remove group: docker (members: $(getent group docker | cut -d: -f4 | sed 's/^$/none/'))"
fi

if (( DRY )); then
  say "Dry run - nothing was changed."
  exit 0
fi

if (( ! YES )); then
  echo
  echo "   This destroys ALL containers, images and named volumes on this machine,"
  echo "   including the ChirpStack database. There is no undo."
  read -r -p "   Type 'wipe' to continue: " answer
  [[ "$answer" == wipe ]] || { echo "   aborted."; exit 1; }
fi

# ------------------------------------------------------------- services ------
# Stop before removing anything underneath a running daemon. Failures here are
# non-fatal: a half-finished install may have left the units in any state, and
# that is exactly the case this script exists to clean up.
say "Stopping services"
for u in docker.service docker.socket containerd.service; do
  if systemctl list-unit-files "$u" >/dev/null 2>&1 && systemctl is-enabled --quiet "$u" 2>/dev/null; then
    run "systemctl disable --now '$u' >/dev/null 2>&1 || true"
    ok "disabled $u"
  else
    run "systemctl stop '$u' >/dev/null 2>&1 || true"
  fi
done
# Rootless daemons hold their own mounts under a user's home and keep the
# per-user unit alive; they are not touched by the system units above.
if command -v loginctl >/dev/null 2>&1; then
  while read -r uid user _; do
    [[ -n "${uid:-}" ]] || continue
    if systemctl --user -M "${user}@" is-active --quiet docker.service 2>/dev/null; then
      warn "user '$user' has a rootless docker running; stop it with:"
      warn "    sudo -u $user XDG_RUNTIME_DIR=/run/user/$uid dockerd-rootless-setuptool.sh uninstall"
    fi
  done < <(loginctl list-users --no-legend 2>/dev/null || true)
fi

# ------------------------------------------------------------- packages ------
# --------------------------------------------- containers, images, volumes ---
# Delete these THROUGH DOCKER, while Docker still exists. Deleting the data
# root afterwards is not equivalent: the root has to be discovered first, and
# discovery fails whenever the daemon is already stopped or daemon.json has
# gone -- in which case a volume living on a separate disk (a --data-root on
# /data, say) is silently left behind. A leftover postgres volume is not a
# cosmetic problem: POSTGRES_PASSWORD is only ever applied when the volume is
# first created, so the next install comes up with a fresh password in .env
# and a database that still has the old one, and nothing can log in.
if (( ! KEEP_DATA )) && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  say "Removing containers, images and volumes through Docker"
  run "docker ps -aq | xargs -r docker rm -f"          ; ok "containers removed"
  run "docker volume ls -q | xargs -r docker volume rm -f"
  ok "named volumes removed (this is where the ChirpStack database lived)"
  run "docker system prune -af --volumes"              ; ok "images and build cache removed"
elif (( ! KEEP_DATA )); then
  warn "Docker is not running, so containers and volumes cannot be removed through it."
  warn "Falling back to deleting the data directories, which only works if they"
  warn "can be discovered below. If a volume survives, the next install will fail"
  warn "with 'password authentication failed for user chirpstack'."
fi

if (( ! KEEP_PACKAGES )) && (( ${#INSTALLED[@]} )); then
  say "Purging packages"
  # No network and no repo needed to purge; the lock timeout is here because a
  # fresh VM's apt-daily jobs are the usual reason a reset stalls.
  export DEBIAN_FRONTEND=noninteractive
  run "apt-get -o DPkg::Lock::Timeout=600 purge -y ${INSTALLED[*]}" \
    || fail "apt purge failed - see above"
  ok "purged ${INSTALLED[*]}"
  if (( AUTOREMOVE )); then
    run "apt-get -o DPkg::Lock::Timeout=600 autoremove --purge -y"
    ok "autoremoved the leftover closure"
  fi
fi

# --------------------------------------------------------------- config ------
say "Removing configuration"
for f in "${DROPINS[@]}"; do
  [[ -e "$f" ]] || continue
  run "rm -f '$f'"; ok "removed $f"
done
for d in /etc/systemd/system/docker.service.d /etc/systemd/system/containerd.service.d; do
  [[ -d "$d" ]] && run "rmdir '$d' 2>/dev/null || true"
done
run "systemctl daemon-reload"

for f in "${CONFIGS[@]}"; do
  [[ -e "$f" ]] || continue
  run "rm -f '$f'"; ok "removed $f"
done
for d in /etc/docker /etc/containerd; do
  [[ -d "$d" ]] && run "rmdir '$d' 2>/dev/null || true"
done

for f in "${APTBITS[@]}"; do
  [[ -e "$f" ]] || continue
  run "rm -f '$f'"; ok "removed $f (from enable-online-updates.sh)"
done

# install.sh writes these next to itself and deletes them on success. They are
# only ever present when a previous run died mid-install.
while IFS= read -r leftover; do
  [[ -n "$leftover" ]] || continue
  run "rm -rf '$leftover'"; ok "removed stale installer scratch: $leftover"
done < <(find / -xdev -maxdepth 6 \( -name .aptsource.list -o -name .aptlists \) 2>/dev/null || true)

# ------------------------------------------------------- sitesync stack ------
# install-all.sh writes these; without removing them a "clean" reinstall is not
# clean. The state markers matter most: they make --resume skip steps that were
# never actually run on this machine.
if (( ! KEEP_DATA )); then
  say "Removing the SiteSync stack and its install state"

  if [[ -d /var/lib/sitesync-airgap ]]; then
    run "rm -rf --one-file-system -- /var/lib/sitesync-airgap"
    ok "removed /var/lib/sitesync-airgap (install step markers)"
  fi

  if [[ -d "$STACK_DIR_TARGET" ]]; then
    # This holds the site's .env, certificates and MQTT users. Keeping it would
    # make the next install silently reuse the old settings and skip setup.sh.
    run "rm -rf --one-file-system -- '$STACK_DIR_TARGET'"
    ok "removed $STACK_DIR_TARGET (settings, certificates, MQTT users)"
  fi

  # The previous-version copies step 30 leaves behind.
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    run "rm -rf --one-file-system -- '$old'"; ok "removed $old"
  done < <(find "$(dirname "$STACK_DIR_TARGET")" -maxdepth 1 -name "$(basename "$STACK_DIR_TARGET").replaced-*" 2>/dev/null || true)
else
  if [[ -d "$STACK_DIR_TARGET" || -d /var/lib/sitesync-airgap ]]; then
    say "Keeping the SiteSync stack (--keep-data)"
    warn "$STACK_DIR_TARGET and /var/lib/sitesync-airgap are left in place."
    warn "A later install will reuse that .env and will NOT ask the setup questions."
  fi
fi

# ----------------------------------------------------------------- data ------
if (( ! KEEP_DATA )); then
  say "Removing data"
  for d in "${DELETABLE[@]+"${DELETABLE[@]}"}"; do
    [[ -d "$d" ]] || continue
    run "rm -rf --one-file-system -- '$d'"
    ok "removed $d"
  done
  (( ${#DELETABLE[@]} )) || skip "nothing to remove"
fi

# ---------------------------------------------------------------- group ------
if (( ! KEEP_GROUP )) && getent group docker >/dev/null; then
  say "Removing the docker group"
  # gpasswd first: groupdel refuses while it is anyone's primary group, and
  # leaving stale members behind means the next install's usermod is a no-op
  # and the operator never gets prompted to log out.
  for m in $(getent group docker | cut -d: -f4 | tr ',' ' '); do
    run "gpasswd -d '$m' docker >/dev/null 2>&1 || true"
    ok "removed '$m' from the docker group"
  done
  run "groupdel docker 2>/dev/null || true"
  getent group docker >/dev/null && warn "group 'docker' still exists (someone's primary group?)" \
                                 || ok "group 'docker' removed"
fi

# ----------------------------------------------------------------- check -----
say "Verifying the machine is clean"
CLEAN=1
command -v docker >/dev/null 2>&1 && { warn "'docker' is still on PATH: $(command -v docker)"; CLEAN=0; } \
                                  || ok "docker binary gone"
for p in "${DOCKER_PKGS[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 && { warn "$p still installed"; CLEAN=0; }
done
for d in /var/lib/docker /var/lib/containerd "$DOCKER_ROOT" "$CONTAINERD_ROOT"; do
  [[ -n "$d" && -d "$d" ]] && { warn "$d still exists"; CLEAN=0; }
done
for f in "${DROPINS[@]}" "${CONFIGS[@]}"; do
  [[ -e "$f" ]] && { warn "$f still exists"; CLEAN=0; }
done
(( CLEAN )) && ok "no leftovers found"

say "Done."
if (( ! CLEAN )); then
  echo "   Leftovers are listed above. Re-running is safe and usually clears them;"
  echo "   if something persists, it was not created by this tooling."
elif (( KEEP_PACKAGES || KEEP_DATA || KEEP_GROUP )); then
  echo "   Partial reset - some things were kept by request. Re-run without the"
  echo "   --keep-* flags for a full wipe."
else
cat <<'NEXT'
   The machine is back to its pre-install state as far as this tooling is
   concerned. Two things it cannot undo, both harmless for a re-test:

     - Ubuntu packages that were already installed before Docker (git,
       ca-certificates, apparmor and friends) stay put unless --autoremove
       was passed.
     - your shell still has the old group membership. Log out and back in,
       or the next install's group check reads stale.

   Ready for another 'sudo bash install-all.sh'.
NEXT
fi
