#!/usr/bin/env bash
#
# ignition-bundle.sh
#
# Builds an offline bundle for a BARE METAL Ignition gateway: the vendor's own
# Linux .run installer, verified against the SHA-256 Inductive Automation
# publishes, plus a small install.sh that runs it unattended on the target.
#
# Run on ANY internet-connected machine. Nothing here needs root, docker, or a
# matching OS -- the .run is a self-contained blob with its own bundled JRE, so
# there is no dependency resolution to do and no target-release to match.
#
#   ./ignition-bundle.sh                      # newest STABLE 8.1
#   ./ignition-bundle.sh --version 8.1.53     # pin an exact release
#   ./ignition-bundle.sh --installer ./ignition-8.1.54-linux-64-installer.run
#
# Operator's job on the offline server:  sudo bash install.sh
#
# --------------------------------------------------------------------------
# HOW THE DOWNLOAD IS AUTOMATED
#
# There is no public API, but the archive page is honest about its data. It
# server-renders the whole release catalog into one JSON blob:
#
#     var ignition_versions = JSON.parse('{ "8.3": {...}, "8.1": {"builds": [
#         {"buildid": 3213, "version": "8.1.54", "state": "STABLE", ...},
#         ...
#     ]}}')
#
# so "newest stable 8.1" is a question this script can answer without guessing
# at URLs. The per-release download links are NOT in that page -- they come
# from a second request, POST /downloads/switch_build with the buildid, which
# returns an HTML fragment carrying both the direct CDN link and the published
# SHA-256. Two requests, no login, no token beyond the CSRF cookie the first
# request sets.
#
# The .run itself is a plain CDN object: no cookie, no referer, no gate. If a
# hand-run curl "gives errors", it is nearly always a missing -L (the CDN
# redirects) or a missing -o (1.5 GB of binary into a terminal).
#
# Both of those page details are Inductive Automation's, not a contract, and
# they can change without warning. That is what --installer is for: when the
# resolver breaks, a tech downloads the .run from the website by hand and the
# bundle still builds, byte-identical. The failure is loud and the workaround
# is one flag -- never a silently wrong artifact.
# --------------------------------------------------------------------------
#
# Build host needs: curl, python3, tar, gzip, sha256sum.

set -Eeuo pipefail

# ---------------------------------------------------------------- defaults ---
BRANCH="8.1"                   # the LTS line SiteSync standardizes on
VERSION=""                     # empty = newest STABLE on $BRANCH
INSTALLER=""                   # a .run already on disk; skips all networking
OUTDIR=""                      # default: ./artifacts
CACHE_DIR="${IGNITION_CACHE_DIR:-$HOME/.cache/sitesync-ignition}"
NO_CACHE=0
ARCH_BITS=64

IA_BASE="https://inductiveautomation.com"
ARCHIVE_URL="$IA_BASE/downloads/archive/"
SWITCH_URL="$IA_BASE/downloads/switch_build"

# A plain browser UA. Not decoration: the site sits behind a WAF that answers
# 403 to unrecognised agents, which is the difference between "curl works" and
# "curl gives errors" on these URLs.
#
# The version here will go stale, and a stale one can itself be refused. That
# is survivable by design: the download probes several header profiles and
# uses whichever the host accepts, and IGNITION_UA overrides this outright. If
# you are updating it, copy the string from a current browser.
UA="${IGNITION_UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36}"

usage() {
  cat <<'EOF'
Usage: ignition-bundle.sh [options]

      --branch VER      Ignition branch to track (default: 8.1)
      --version VER     Pin an exact release, e.g. 8.1.53. Without this the
                        newest STABLE release on the branch is used. Nightlies
                        and release candidates are never selected.
      --installer PATH  Use this .run instead of downloading. For a build host
                        with no internet, or when the download resolver breaks
                        and the tech fetched the file by hand.
  -o, --out DIR         Where to write the tarball (default: ./artifacts)
      --cache DIR       Keep downloaded installers here and reuse them
                        (default: ~/.cache/sitesync-ignition)
      --no-cache        Download to a temp dir and throw it away afterwards
      --resolve-only    Print what WOULD be downloaded and exit. Costs one
                        small request and no gigabytes; this is the cheap way
                        to check the resolver still works.
  -h, --help            This text

Examples:
  ./ignition-bundle.sh                       # newest stable 8.1
  ./ignition-bundle.sh --resolve-only        # what is current right now?
  ./ignition-bundle.sh --version 8.1.53      # match an existing site
EOF
}

RESOLVE_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)     BRANCH="$2"; shift 2 ;;
    --version)    VERSION="$2"; shift 2 ;;
    --installer)  INSTALLER="$2"; shift 2 ;;
    -o|--out)     OUTDIR="$2"; shift 2 ;;
    --cache)      CACHE_DIR="$2"; shift 2 ;;
    --no-cache)   NO_CACHE=1; shift ;;
    --resolve-only) RESOLVE_ONLY=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

OUTDIR="${OUTDIR:-$PWD/artifacts}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

# ------------------------------------------------------------- preflight -----
for b in tar gzip sha256sum; do
  command -v "$b" >/dev/null || die "missing required tool: $b"
done
if [[ -z "$INSTALLER" ]]; then
  for b in curl python3; do
    command -v "$b" >/dev/null || die "missing required tool: $b (or pass --installer PATH)"
  done
fi

WORK="$(mktemp -d /tmp/ignition-bundle.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ------------------------------------------------------------- resolving -----
# Fills in: RES_VERSION, RES_URL, RES_SHA256, RES_FILENAME, RES_BUILDID
RES_VERSION=""; RES_URL=""; RES_SHA256=""; RES_FILENAME=""; RES_BUILDID=""

resolve_from_ia() {
  local page="$WORK/archive.html" jar="$WORK/cookies.txt" frag="$WORK/build.html"

  log "asking $IA_BASE which $BRANCH release is current"
  curl -fsSL --retry 3 --retry-delay 2 --max-time 60 \
       -A "$UA" \
       -c "$jar" -o "$page" "$ARCHIVE_URL" \
    || die "could not reach $ARCHIVE_URL.
       If this build host has no internet, download the installer by hand from
       $IA_BASE/downloads/archive and pass it with --installer PATH."

  # The catalog is one JSON blob inside a JSON.parse('...') call. Pull the
  # blob out with python rather than a regex chain, so a quote or a unicode
  # escape in a release note cannot corrupt the parse.
  local picked
  picked="$(BRANCH="$BRANCH" WANT="$VERSION" python3 - "$page" <<'PY'
import json, os, re, sys

html = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"ignition_versions\s*=\s*JSON\.parse\(\s*'(.*?)'\s*\)", html, re.S)
if not m:
    sys.exit("catalog-not-found")

raw = m.group(1)
# The blob is embedded in a single-quoted JS string literal.
raw = raw.replace("\\'", "'").replace("\\\\", "\\")
try:
    data = json.loads(raw)
except Exception as exc:
    sys.exit("catalog-unparseable: %s" % exc)

branch, want = os.environ["BRANCH"], os.environ["WANT"]

# Shape seen in the wild: {"branches": [{"8.3": {...}}, {"8.1": {...}}]} or a
# bare list/dict of the same. Walk whatever it is and collect every build.
builds = []
def walk(node, key=None):
    if isinstance(node, dict):
        if "buildid" in node and "version" in node:
            builds.append((key, node))
            return
        for k, v in node.items():
            walk(v, k if re.fullmatch(r"\d+\.\d+", str(k)) else key)
    elif isinstance(node, list):
        for v in node:
            walk(v, key)
walk(data)

def vkey(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:3])

cands = []
for bkey, b in builds:
    ver = str(b.get("version", ""))
    # A bare X.Y.Z only. Anything with a suffix is a nightly or an RC.
    if not re.fullmatch(r"\d+\.\d+\.\d+", ver):
        continue
    if str(b.get("state", "")).upper() != "STABLE":
        continue
    if want:
        if ver != want:
            continue
    elif not ver.startswith(branch + "."):
        continue
    cands.append((vkey(ver), ver, b.get("buildid")))

if not cands:
    sys.exit("no-match")
cands.sort()
_, ver, buildid = cands[-1]
print("%s %s" % (ver, buildid))
PY
)" || die "could not read the release catalog from $ARCHIVE_URL ($picked).
       Inductive Automation changed the page. Download the installer by hand
       and pass it with --installer PATH -- the bundle builds the same either
       way -- then fix the resolver at your leisure."

  RES_VERSION="${picked%% *}"
  RES_BUILDID="${picked##* }"
  [[ -n "$RES_VERSION" && -n "$RES_BUILDID" ]] || die "resolver returned nothing usable: '$picked'"
  log "current stable on $BRANCH: $RES_VERSION (build $RES_BUILDID)"

  local token
  token="$(awk '$6=="csrftoken"{print $7}' "$jar" | tail -1)"
  [[ -n "$token" ]] || die "no csrftoken cookie from $ARCHIVE_URL"

  curl -fsSL --retry 3 --retry-delay 2 --max-time 60 \
       -A "$UA" \
       -b "$jar" -c "$jar" \
       -H "Referer: $ARCHIVE_URL" \
       -H 'X-Requested-With: XMLHttpRequest' \
       --data-urlencode "build=$RES_BUILDID" \
       --data-urlencode "OSArch=$ARCH_BITS" \
       --data-urlencode "csrfmiddlewaretoken=$token" \
       --data-urlencode "page=archive" \
       -o "$frag" "$SWITCH_URL" \
    || die "the download-link request failed for build $RES_BUILDID"

  # The fragment lists every artifact for the release. Take the link whose
  # filename is exactly the Linux 64-bit SYSTEM installer -- not Edge, not
  # Cloud, not a zip -- and the checksum from the same row.
  local found
  found="$(VER="$RES_VERSION" python3 - "$frag" <<'PY'
import os, re, sys
html = open(sys.argv[1], encoding="utf-8", errors="replace").read()
ver = os.environ["VER"]
want = "ignition-%s-linux-%s-installer.run" % (ver, "64")

# Rows are <div class="flex-row data"> ... </div>; the sha lives in the same
# row as the href, so split on the row boundary rather than pairing by index.
best = None
for row in re.split(r'class="flex-row data"', html)[1:]:
    m = re.search(r'href="(https://releases\.inductiveautomation\.com/[^"]+)"', row)
    if not m:
        continue
    url = m.group(1)
    if url.rsplit("/", 1)[-1] != want:
        continue
    s = re.search(r"installer-sha'>([a-fA-F0-9]{64})", row)
    best = (url, s.group(1).lower() if s else "")
    break

if not best:
    sys.exit("no-linux-installer")
print("%s %s" % best)
PY
)" || die "the release page for $RES_VERSION has no '$RES_VERSION linux 64 installer'.
       Check $IA_BASE/downloads/archive/$RES_VERSION by hand."

  RES_URL="${found%% *}"
  RES_SHA256="${found##* }"
  RES_FILENAME="$(basename "$RES_URL")"
  [[ "$RES_URL" == https://* ]] || die "resolved a URL that is not https: $RES_URL"
  if [[ -z "$RES_SHA256" ]]; then
    echo "    warning: IA published no checksum for this release; the download" >&2
    echo "             cannot be verified against the vendor." >&2
  fi
}

# --------------------------------------------------- pick up a local file ----
if [[ -n "$INSTALLER" ]]; then
  [[ -f "$INSTALLER" ]] || die "--installer file not found: $INSTALLER"
  RES_FILENAME="$(basename "$INSTALLER")"
  if [[ -n "$VERSION" ]]; then
    RES_VERSION="$VERSION"
  else
    RES_VERSION="$(sed -nE 's/^ignition-([0-9]+\.[0-9]+\.[0-9]+)-linux.*/\1/p' <<<"$RES_FILENAME")"
    [[ -n "$RES_VERSION" ]] || die "cannot tell the version from '$RES_FILENAME'.
       Pass it explicitly:  --installer $INSTALLER --version 8.1.54"
  fi
  RES_URL="(supplied by hand: $INSTALLER)"
  RES_SHA256="$(sha256sum "$INSTALLER" | cut -d' ' -f1)"
  log "using the installer on disk: $RES_FILENAME ($RES_VERSION)"
else
  resolve_from_ia
fi

if (( RESOLVE_ONLY )); then
  cat <<EOF

  version   : $RES_VERSION
  build id  : ${RES_BUILDID:-n/a}
  file      : $RES_FILENAME
  url       : $RES_URL
  sha256    : ${RES_SHA256:-(none published)}

EOF
  exit 0
fi

# ----------------------------------------------------------- downloading -----
if (( NO_CACHE )); then
  CACHE_DIR="$WORK/cache"
fi
mkdir -p "$CACHE_DIR"
RUN_PATH="$CACHE_DIR/$RES_FILENAME"

verify_sha() {
  local f="$1"
  [[ -n "$RES_SHA256" ]] || return 0
  local got; got="$(sha256sum "$f" | cut -d' ' -f1)"
  [[ "$got" == "$RES_SHA256" ]]
}

# ---------------------------------------------------------- header probe -----
# The CDN that serves the .run is fronted by a bot filter, and it does not
# make the same decisions as the website: the two requests that resolved the
# version can succeed while the download itself is refused with a 403. The
# filter judges by request headers, and which combination it likes changes
# without notice -- a user-agent that worked last quarter is refused this one.
#
# So the headers are not guessed. Ask for ONE byte with each candidate profile
# in turn -- a few hundred bytes of traffic, over in a second -- and use the
# first that the CDN accepts for the real transfer. Discovering the block here
# rather than after 1.4 GB is the entire point.
CURL_HDR=()
PROFILE_NAME=""
set_profile() {
  case "$1" in
    0) CURL_HDR=(-A "$UA" -H 'Accept: */*' -H "Referer: $IA_BASE/downloads/")
       PROFILE_NAME="browser user-agent with a referer" ;;
    1) CURL_HDR=(-A "$UA" -H 'Accept: */*')
       PROFILE_NAME="browser user-agent" ;;
    2) CURL_HDR=(-H 'Accept: */*')
       PROFILE_NAME="curl's own user-agent" ;;
    3) CURL_HDR=(-A '')
       PROFILE_NAME="no user-agent at all" ;;
    *) return 1 ;;
  esac
}

probe_profile() {
  local code
  # -r 0-0 keeps this to a single byte. No -f: the HTTP code is the answer we
  # want, including when it is a 403.
  # No '|| echo 000' here: curl prints its own %{http_code} (000 when it never
  # got a response) and appending a second one produces "000000", which reads
  # like a status code and is not one.
  code="$(curl -sS -L --max-time 30 "${CURL_HDR[@]}" \
               -r 0-0 -o /dev/null -w '%{http_code}' "$RES_URL" 2>/dev/null)" || true
  [[ -n "$code" ]] || code="000"
  case "$code" in
    206|200) return 0 ;;
    *) LAST_CODE="$code"; return 1 ;;
  esac
}

if [[ -n "$INSTALLER" ]]; then
  cp -f "$INSTALLER" "$RUN_PATH"
elif [[ -f "$RUN_PATH" ]] && verify_sha "$RUN_PATH"; then
  log "already in the cache and the checksum matches: $RUN_PATH"
else
  [[ -f "$RUN_PATH" ]] && log "cached copy is stale or corrupt; downloading again"

  LAST_CODE=""
  ACCEPTED=-1
  log "checking how the download host wants to be asked"
  for p in 0 1 2 3; do
    set_profile "$p"
    if probe_profile; then
      ACCEPTED="$p"
      echo "    accepted: $PROFILE_NAME"
      break
    fi
    echo "    refused ($LAST_CODE): $PROFILE_NAME"
  done

  if (( ACCEPTED < 0 )); then
    die "the download host refused every request this script knows how to make
       (last HTTP status: ${LAST_CODE:-none}).
         $RES_URL

       Nothing is wrong with the version lookup -- that part worked, which is
       how we know the file exists and where it is. The CDN is refusing this
       machine or this client.

       Fastest way round it, and the artifact is identical either way:
         1. Open the URL above in a browser and let it download.
         2. Rebuild with:
              --ignition-run /path/to/$RES_FILENAME

       If a browser on this machine is also refused, it is the network (a
       proxy or content filter), not the client -- try from somewhere else.
       Override the user-agent with:  IGNITION_UA='...' $0 ..."
  fi
  set_profile "$ACCEPTED"

  log "downloading $RES_FILENAME (about 1.5 GB -- this is the slow part)"
  # Resume only when there is something to resume. Sending a Range header for
  # a file that does not exist locally yet gives some CDNs one more reason to
  # say no, and buys nothing.
  resume=()
  [[ -s "$RUN_PATH.part" ]] && resume=(--continue-at -)
  curl -fL --retry 3 --retry-delay 5 "${resume[@]+"${resume[@]}"}" \
       "${CURL_HDR[@]}" \
       --progress-bar -o "$RUN_PATH.part" "$RES_URL" \
    || die "download failed after the host had accepted the request: $RES_URL
       A partial file is kept at $RUN_PATH.part and re-running resumes it."
  mv -f "$RUN_PATH.part" "$RUN_PATH"
fi

if [[ -n "$RES_SHA256" ]]; then
  if verify_sha "$RUN_PATH"; then
    if [[ -n "$INSTALLER" ]]; then
      # Self-computed, not vendor-published: it proves the file survives the
      # trip to the target, not that it is the file IA shipped. Say so.
      log "sha256 recorded from the supplied file (NOT verified against IA)"
    else
      log "sha256 matches the checksum Inductive Automation published"
    fi
  else
    rm -f "$RUN_PATH"
    die "sha256 MISMATCH -- the download is corrupt or the file changed.
       expected $RES_SHA256
       The bad copy has been deleted. Run this again."
  fi
fi

# A truncated download that happens to be reported as complete is still the
# most common airgap failure. The installer is a shell-wrapped blob, so a
# valid one starts with a shebang and is enormous.
head -c 2 "$RUN_PATH" | grep -q '#!' \
  || die "$RES_FILENAME does not look like a .run installer (no shebang)"
RUN_BYTES="$(stat -c %s "$RUN_PATH")"
(( RUN_BYTES > 100000000 )) \
  || die "$RES_FILENAME is only $RUN_BYTES bytes -- far too small to be Ignition"

# -------------------------------------------------------------- staging ------
NAME="ignition-${RES_VERSION}-linux-${ARCH_BITS}"
STAGE="$WORK/$NAME"
mkdir -p "$STAGE"
cp -f "$RUN_PATH" "$STAGE/$RES_FILENAME"
chmod +x "$STAGE/$RES_FILENAME"

cat > "$STAGE/IGNITION_INFO" <<EOF
IGNITION_VERSION="${RES_VERSION}"
IGNITION_BUILDID="${RES_BUILDID}"
IGNITION_INSTALLER="${RES_FILENAME}"
IGNITION_SHA256="${RES_SHA256}"
IGNITION_SOURCE_URL="${RES_URL}"
IGNITION_BUILT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

# ------------------------------------------------------- inner install.sh ----
# Same shape as the Docker bundle's install.sh: the artifact carries the thing
# that knows how to install its own payload, so the target-side step stays a
# thin wrapper and the bundle can be handed over and run on its own.
cat > "$STAGE/install.sh" <<'INSTALLER_EOF'
#!/usr/bin/env bash
#
# Installs Ignition from the .run beside this script, unattended.
#
#     sudo bash install.sh                      # installer's default location
#     sudo bash install.sh --location /opt/ignition
#     sudo bash install.sh --user nick --no-autostart
#
# The gateway is installed as a system service and enabled at boot unless
# --no-service is given.
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
. "$HERE/IGNITION_INFO"

# The installer's own default. Stated here rather than left implicit because
# every later step -- the service check, the uninstaller -- needs to know
# where to look, and "wherever the installer felt like" is not an answer.
DEFAULT_LOCATION="/usr/local/bin/ignition"

LOCATION=""
OWNER=""
SERVICE_NAME="Ignition"
AUTOSTART=1
WITH_SERVICE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --location)     LOCATION="${2:-}"; shift 2 ;;
    --user)         OWNER="${2:-}"; shift 2 ;;
    --service-name) SERVICE_NAME="${2:-}"; shift 2 ;;
    --no-autostart) AUTOSTART=0; shift ;;
    --no-service)   WITH_SERVICE=0; shift ;;
    -h|--help)      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

ok()   { printf '   [ ok ] %s\n' "$*"; }
warn() { printf '   [note] %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "must run as root:  sudo bash install.sh"

LOCATION="${LOCATION:-$DEFAULT_LOCATION}"
OWNER="${OWNER:-${SUDO_USER:-root}}"
RUN="$HERE/$IGNITION_INSTALLER"
[[ -f "$RUN" ]] || fail "$IGNITION_INSTALLER is missing from this folder"

if [[ -n "${IGNITION_SHA256:-}" ]]; then
  got="$(sha256sum "$RUN" | cut -d' ' -f1)"
  [[ "$got" == "$IGNITION_SHA256" ]] \
    || fail "checksum mismatch on $IGNITION_INSTALLER - re-copy the folder"
  ok "installer checksum verified"
fi

if [[ -e "$LOCATION/lib/core/common" || -x "$LOCATION/ignition.sh" ]]; then
  fail "Ignition is already installed at $LOCATION.
        This script does not upgrade in place. Remove it first with
        uninstall.sh, or install elsewhere with --location DIR."
fi

chmod +x "$RUN"
mkdir -p "$(dirname "$LOCATION")"

echo "   Installing Ignition $IGNITION_VERSION to $LOCATION"
echo "   (a few minutes, and it is silent on purpose - the log is below)"

# 'unattended=none' is fully silent; the installer writes its own log next to
# itself. autoStart is honoured on clean installs from 8.1.22 onward.
ARGS=("unattended=none" "location=$LOCATION" "serviceName=$SERVICE_NAME")
if [[ "$OWNER" != root ]] && id "$OWNER" >/dev/null 2>&1; then
  ARGS+=("user=$OWNER")
fi
(( AUTOSTART )) && ARGS+=("autoStart=true") || ARGS+=("autoStart=false")

if ! "$RUN" -- "${ARGS[@]}"; then
  # The installer's log is the only useful artifact when this fails.
  for l in /tmp/installbuilder_installer*.log "$LOCATION"/installer*.log; do
    [[ -f "$l" ]] && { echo "--- $l ---"; tail -40 "$l"; }
  done
  fail "the Ignition installer returned an error (log above)"
fi

[[ -x "$LOCATION/ignition.sh" ]] \
  || fail "the installer reported success but $LOCATION/ignition.sh is not there"
ok "Ignition $IGNITION_VERSION installed at $LOCATION"

# Record where it went. The uninstaller reads this rather than guessing, which
# is what makes --location safe to use.
mkdir -p /var/lib/sitesync-airgap
cat > /var/lib/sitesync-airgap/ignition.info <<EOF
IGNITION_VERSION="$IGNITION_VERSION"
IGNITION_LOCATION="$LOCATION"
IGNITION_SERVICE_NAME="$SERVICE_NAME"
IGNITION_OWNER="$OWNER"
IGNITION_INSTALLED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

# ------------------------------------------------------------- service -------
# On Linux the installer does not reliably create the systemd unit -- it has
# shipped broken in more than one 8.1.x -- so the unit is installed here and
# then CHECKED. A gateway that works until the first reboot is worse than one
# that fails now.
if (( WITH_SERVICE )); then
  if [[ -d /run/systemd/system ]]; then
    "$LOCATION/ignition.sh" install >/dev/null 2>&1 || true
    # Everything from here is best-effort reporting. Ignition is already on
    # disk; a systemctl that cannot reach the bus must not turn a completed
    # install into a failed step.
    systemctl daemon-reload >/dev/null 2>&1 || true

    UNIT=""
    for cand in "${SERVICE_NAME}-Gateway.service" "Ignition-Gateway.service" \
                "${SERVICE_NAME}.service" ignition.service; do
      if systemctl list-unit-files "$cand" 2>/dev/null | grep -q "$cand"; then
        UNIT="$cand"; break
      fi
    done

    if [[ -z "$UNIT" ]]; then
      warn "the installer did not create a systemd unit (a known 8.1 defect)."
      warn "Ignition is installed and can be started with:"
      warn "    sudo $LOCATION/ignition.sh start"
      warn "but it will NOT come back after a reboot until a unit exists."
    else
      systemctl enable "$UNIT" >/dev/null 2>&1 \
        && ok "$UNIT enabled at boot" \
        || warn "could not enable $UNIT - it will not start after a reboot"
      echo "IGNITION_SERVICE_UNIT=\"$UNIT\"" >> /var/lib/sitesync-airgap/ignition.info
      if (( AUTOSTART )); then
        systemctl start "$UNIT" >/dev/null 2>&1 || true
      fi
    fi
  else
    warn "no systemd on this machine; skipping the service"
  fi
fi

ok "done"
INSTALLER_EOF
chmod +x "$STAGE/install.sh"

cat > "$STAGE/README.txt" <<EOF
Ignition ${RES_VERSION} -- offline installer bundle
===================================================
Built  : $(date -u +%Y-%m-%dT%H:%M:%SZ)
Source : ${RES_URL}
SHA256 : ${RES_SHA256:-(none published)}

This is the vendor's own Linux installer, unmodified, plus a script that runs
it without asking questions. It installs Ignition on the metal -- not in a
container -- and needs no internet on the target.

    sudo bash install.sh                     # installer's default location
    sudo bash install.sh --location /opt/ignition

Afterwards the gateway is at  http://<this machine>:8088
The commissioning wizard runs on first visit.
EOF

pushd "$STAGE" >/dev/null
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
popd >/dev/null

# ------------------------------------------------------------- packing -------
mkdir -p "$OUTDIR"
ARCHIVE="$OUTDIR/${NAME}.tar.gz"
log "packing $ARCHIVE"
# The .run is already compressed; -1 keeps the tar honest without spending
# minutes to save nothing.
tar -C "$WORK" -c "$NAME" | gzip -1 > "$ARCHIVE"

cat <<EOF

########################################
Ignition bundle ready.
  file    : $ARCHIVE
  size    : $(du -h "$ARCHIVE" | cut -f1)
  version : $RES_VERSION
  sha256  : ${RES_SHA256:-(none published)}
$( [[ "$CACHE_DIR" != "$WORK/cache" ]] && printf '  cached  : %s\n' "$RUN_PATH" )

On the target:
  tar xzf $(basename "$ARCHIVE") && cd $NAME && sudo bash install.sh
EOF
