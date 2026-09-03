#!/usr/bin/env bash
# Checks the settings in .env and the state of the machine, and explains any
# problem in plain language. Run it any time: ./sitesync doctor
set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet-on-success" ]] && QUIET=1

PROBLEMS=0
NOTES=0
out=""
ok()   { out+="  [ ok ]    $*"$'\n'; }
note() { out+="  [ note ]  $*"$'\n'; NOTES=$((NOTES+1)); }
bad()  { out+="  [ FIX ]   $*"$'\n'; PROBLEMS=$((PROBLEMS+1)); }

# --- the machine ------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  bad "Docker is not installed. Install Docker Engine, then run this again."
elif ! docker info >/dev/null 2>&1; then
  bad "Docker is installed but not running. Start it with: sudo systemctl start docker"
elif ! docker compose version >/dev/null 2>&1; then
  bad "The Docker Compose plugin is missing. Install the docker-compose-plugin package."
else
  ok "Docker is installed and running."
fi

FREE_KB=$(df -Pk . 2>/dev/null | awk 'NR==2{print $4}')
if [[ -n "${FREE_KB:-}" ]]; then
  FREE_GB=$((FREE_KB/1024/1024))
  if   (( FREE_GB < 2 )); then bad "Only ${FREE_GB} GB of disk space left. The database will stop accepting data. Free some space."
  elif (( FREE_GB < 10 )); then note "${FREE_GB} GB of disk space left. Fine for now, worth watching."
  else ok "Disk space: ${FREE_GB} GB free."; fi
fi

# --- secrets ----------------------------------------------------------------
SECRET_PROBLEMS=$PROBLEMS
[[ -n "${CHIRPSTACK_API_SECRET:-}" ]] || bad "CHIRPSTACK_API_SECRET in .env is empty. Run ./setup.sh to generate one."
[[ "${CHIRPSTACK_API_SECRET:-}" != "you-must-replace-this" ]] || bad "CHIRPSTACK_API_SECRET is still the example value. Run ./setup.sh."
[[ -n "${POSTGRES_PASSWORD:-}" ]] || bad "POSTGRES_PASSWORD in .env is empty. Run ./setup.sh to generate one."
[[ "${POSTGRES_PASSWORD:-}" != "chirpstack" ]] || bad "POSTGRES_PASSWORD is still the default 'chirpstack'. Run ./setup.sh."
(( PROBLEMS == SECRET_PROBLEMS )) && ok "Secrets are set and are not the defaults."

# --- region -----------------------------------------------------------------
REGION="${REGION:-}"
if [[ -z "$REGION" ]]; then
  bad "REGION is not set in .env."
elif [[ ! -f "configuration/chirpstack/region_${REGION}.toml" ]]; then
  bad "REGION is '$REGION', but there is no configuration/chirpstack/region_${REGION}.toml."
  out+="            Valid values are: $(ls configuration/chirpstack/region_*.toml | sed 's#.*/region_##;s#\.toml##' | tr '\n' ' ')"$'\n'
else
  ok "Region '$REGION' is valid."
  case ",${COMPOSE_PROFILES:-}," in *,basicstation,*)
    if [[ ! -f "configuration/chirpstack-gateway-bridge/chirpstack-gateway-bridge-basicstation-${REGION}.toml" ]]; then
      bad "Basics Station is switched on, but there is no config file for region '$REGION'."
      out+="            Either pick another region, or remove 'basicstation' from COMPOSE_PROFILES in .env."
    fi ;;
  esac
fi

# --- web interface / TLS ----------------------------------------------------
DOMAIN="${SITE_DOMAIN:-}"
case "${TLS_MODE:-}" in
  off)
    ok "TLS_MODE=off. The web interface is NOT encrypted -- only do this on a trusted network."
    ;;
  self-signed)
    ok "TLS_MODE=self-signed. Browsers will warn once; that is expected."
    if [[ "$DOMAIN" == "localhost" && "${BIND_ADDRESS:-0.0.0.0}" == "0.0.0.0" ]]; then
      _ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
      note "SITE_DOMAIN is 'localhost', so ONLY this machine can open the web interface."
      out+="            Anyone connecting from another computer gets a refused connection,"$'\n'
      out+="            because the certificate and the web server are both bound to that"$'\n'
      out+="            exact name. Set SITE_DOMAIN to what people actually type:"$'\n'
      out+="                SITE_DOMAIN=${_ip:-<the address of this machine>}"$'\n'
      out+="            then run ./sitesync apply"$'\n'
    fi
    ;;
  letsencrypt)
    if [[ -z "$DOMAIN" || "$DOMAIN" == "localhost" ]]; then
      bad "TLS_MODE=letsencrypt needs a real domain name, but SITE_DOMAIN is '${DOMAIN:-empty}'."
      out+="            Use TLS_MODE=self-signed if this site has no public domain name."$'\n'
    elif [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      bad "TLS_MODE=letsencrypt cannot issue a certificate for an IP address ($DOMAIN)."
      out+="            Use TLS_MODE=self-signed instead."$'\n'
    else
      ok "SITE_DOMAIN '$DOMAIN' looks like a real domain name."
      if command -v getent >/dev/null 2>&1; then
        getent hosts "$DOMAIN" >/dev/null 2>&1 \
          && ok "'$DOMAIN' resolves in DNS." \
          || bad "'$DOMAIN' does not resolve in DNS, so Let's Encrypt cannot issue a certificate for it."
      fi
    fi
    [[ -n "${TLS_EMAIL:-}" ]] || bad "TLS_MODE=letsencrypt requires TLS_EMAIL to be filled in."
    [[ "${HTTP_PORT:-80}"  == "80"  ]] || bad "TLS_MODE=letsencrypt requires HTTP_PORT=80 (currently ${HTTP_PORT})."
    [[ "${HTTPS_PORT:-443}" == "443" ]] || bad "TLS_MODE=letsencrypt requires HTTPS_PORT=443 (currently ${HTTPS_PORT})."
    ;;
  custom)
    for f in "${TLS_CERT_FILE:-cert.pem}" "${TLS_KEY_FILE:-key.pem}"; do
      [[ -f "certs/$f" ]] && ok "Found certs/$f" || bad "TLS_MODE=custom but certs/$f is missing."
    done
    ;;
  *)
    bad "TLS_MODE is '${TLS_MODE:-empty}'. It must be one of: off, self-signed, letsencrypt, custom."
    ;;
esac

# --- MQTT -------------------------------------------------------------------
if [[ "${MQTT_AUTH_ENABLED:-true}" == "true" ]]; then
  if [[ -z "${MQTT_USERNAME:-}" || -z "${MQTT_PASSWORD:-}" ]]; then
    bad "MQTT_AUTH_ENABLED=true but the username or password is empty. Run ./setup.sh, or set MQTT_AUTH_ENABLED=false."
  else
    ok "MQTT requires a login."
  fi
else
  note "MQTT_AUTH_ENABLED=false -- anything that can reach port ${MQTT_PORT:-1883} can publish and subscribe."
fi
if [[ "${MQTT_AUTH_ENABLED:-true}" == "true" && -f mqtt-users.conf ]]; then
  BADROLE=0; NOPW=0; COUNT=0
  while read -r u r _; do
    [[ -z "${u:-}" || "${u:0:1}" == "#" ]] && continue
    COUNT=$((COUNT+1))
    case "$r" in
      integration|integration-rw|gateway|admin) ;;
      gateway:?*) ;;
      *) bad "mqtt-users.conf: '$u' has role '$r', which is not a role."
         out+="            Valid roles: integration, integration-rw, gateway, gateway:EUI"$'\n'
         BADROLE=1 ;;
    esac
    grep -q "^$u:" configuration/mosquitto/config/passwd 2>/dev/null || NOPW=$((NOPW+1))
  done < mqtt-users.conf
  if (( BADROLE == 0 )); then
    if (( NOPW > 0 )); then
      note "$COUNT MQTT user(s) listed; $NOPW have no password yet."
      out+="            ./sitesync apply will create one and show it once."$'\n'
    else
      ok "$COUNT MQTT user(s) configured, all with a password set."
    fi
  fi
fi

BURL="${MQTT_BROKER_URL:-tcp://mosquitto:1883}"
case "$BURL" in
  tcp://*|ws://*)
    [[ -z "${MQTT_CA_CERT:-}" ]] || note "MQTT_CA_CERT is set but MQTT_BROKER_URL is '$BURL', which is not encrypted. The certificate is ignored." ;;
  ssl://*|wss://*)
    ok "ChirpStack connects to the broker over an encrypted connection."
    if [[ -n "${MQTT_CA_CERT:-}" ]]; then
      LOCAL="certs/${MQTT_CA_CERT##*/}"
      [[ -f "$LOCAL" ]] && ok "Found the broker CA file $LOCAL" \
        || bad "MQTT_CA_CERT is '$MQTT_CA_CERT' but there is no $LOCAL. Put the CA file in certs/."
    else
      note "MQTT_BROKER_URL uses $BURL with no MQTT_CA_CERT. That only works if the broker's certificate comes from a public authority."
    fi
    if [[ "$BURL" == *mosquitto:8883* && "${MQTT_TLS:-off}" == "off" ]]; then
      bad "MQTT_BROKER_URL points at the bundled broker's encrypted port, but MQTT_TLS=off so that port is not listening."
    fi ;;
  *)
    bad "MQTT_BROKER_URL is '$BURL'. It must start with tcp://, ssl://, ws:// or wss://." ;;
esac

# MQTT_TLS describes the bundled broker's own listener, which only matters if
# this stack is actually using the bundled broker.
if [[ "$BURL" == *mosquitto* ]]; then
  case "${MQTT_TLS:-off}" in
    off) note "The bundled broker accepts unencrypted connections only. Fine on a LAN or VPN; not over the public internet." ;;
    self-signed)
      if command -v openssl >/dev/null 2>&1; then
        ok "The bundled broker also has an encrypted listener on port ${MQTT_TLS_PORT:-8883}."
      else
        bad "MQTT_TLS=self-signed needs the 'openssl' command, which is not installed on this machine.
            Install it with:  sudo apt-get install -y openssl
            (this machine may have no internet, so do it before you need it)"
      fi ;;
    custom) ok "The bundled broker also has an encrypted listener on port ${MQTT_TLS_PORT:-8883}." ;;
    *) bad "MQTT_TLS is '${MQTT_TLS}'. It must be one of: off, self-signed, custom." ;;
  esac
else
  note "This site uses an external broker, so MQTT_TLS and the MQTT user commands do not apply."
fi

# --- certificate expiry -----------------------------------------------------
# Nothing here should ever expire unnoticed. Warn months ahead, not on the day.
if command -v openssl >/dev/null 2>&1; then
  check_expiry() {  # check_expiry <file> <friendly name> <what to do>
    [[ -f "$1" ]] || return 0
    local end days
    end="$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2)" || return 0
    [[ -n "$end" ]] || return 0
    days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if   (( days < 0 ));  then bad "$2 EXPIRED $(( -days )) days ago. $3"
    elif (( days < 90 )); then bad "$2 expires in $days days. $3"
    elif (( days < 365 )); then note "$2 expires in $days days (about $(( days / 30 )) months). $3"
    else ok "$2 is valid for another $(( days / 365 )) year(s)."; fi
  }
  case "${MQTT_TLS:-off}" in
    self-signed) check_expiry certs/mqtt-cert.pem "The MQTT certificate" \
        "Delete certs/mqtt-cert.pem and certs/mqtt-key.pem, then run ./sitesync apply to make a new one." ;;
    custom) check_expiry certs/mqtt-cert.pem "The MQTT certificate" "Replace it with a new one from whoever issued it." ;;
  esac
  if [[ "${TLS_MODE:-}" == "custom" ]]; then
    check_expiry "certs/${TLS_CERT_FILE:-cert.pem}" "The web interface certificate" \
      "Replace it with a new one from whoever issued it."
  fi
  check_expiry certs/sitesync-root-ca.crt "The exported root certificate" \
    "Run ./sitesync ca again to export a fresh copy."
fi

if [[ "${TLS_MODE:-}" == "self-signed" ]]; then
  note "Caddy renews the web certificate by itself (it lasts 12 hours and is reissued continuously)."
  out+="            Its root authority lasts 10 years and is what you install on browsers."$'\n'
  out+="            That authority lives in the caddydata volume -- ./sitesync backup now saves it,"$'\n'
  out+="            so a rebuilt machine keeps the same one and browsers stay happy."$'\n'
fi

# --- ports ------------------------------------------------------------------
if command -v ss >/dev/null 2>&1; then
  RUNNING_PORTS="$(docker compose ps -q 2>/dev/null | wc -l)"
  if [[ "$RUNNING_PORTS" == "0" ]]; then
    for p in "${HTTP_PORT:-80}" "${HTTPS_PORT:-443}" "${MQTT_PORT:-1883}"; do
      ss -ltnH "sport = :$p" 2>/dev/null | grep -q . \
        && bad "Port $p is already used by something else on this machine. Pick a different port in .env." \
        || true
    done
  fi
fi

# --- are the container images actually on this machine? ---------------------
# This is what catches an image that was left out of the airgap artifact. The
# symptom otherwise is a container that will not start, or one that quietly
# reaches out to a registry that may not be there.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  _envf="$(mktemp)"
  printf 'POSTGRES_PASSWORD=x\nCHIRPSTACK_API_SECRET=x\nREGION=%s\n' "${REGION:-eu868}" > "$_envf"
  _prof="$(docker compose --profiles 2>/dev/null | paste -sd, - || true)"
  _absent=()
  while read -r img; do
    [[ -z "$img" ]] && continue
    docker image inspect "$img" >/dev/null 2>&1 || _absent+=("$img")
  done < <(COMPOSE_PROFILES="${COMPOSE_PROFILES:-$_prof}" docker compose config --images 2>/dev/null | sed '/^$/d')
  rm -f "$_envf"
  if (( ${#_absent[@]} )); then
    if [[ "${PULL_POLICY:-missing}" == never ]]; then
      bad "these images are not on this machine, and PULL_POLICY=never:
            ${_absent[*]}
        They were left out of the install artifact. Load them with the image
        bundle's load.sh, or rebuild the artifact with:
            os-provisioning/build/prepare-airgap.sh --latest"
    else
      note "these images are not on this machine yet: ${_absent[*]}"
      out+="            Docker will fetch them on first start, which needs internet."$'\n'
    fi
  else
    ok "every container image this stack needs is already on this machine."
  fi
fi

# --- compose file itself ----------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if ERR="$(docker compose config -q 2>&1)"; then
    ok "docker-compose.yml and .env fit together."
  else
    bad "Docker rejected the configuration:"
    out+="            ${ERR}"$'\n'
  fi

  # Anything stuck in a restart loop?
  while read -r line; do
    [[ -z "$line" ]] && continue
    bad "Service '$line' keeps restarting. See what it says with: ./sitesync logs $line"
  done < <(docker compose ps --format '{{.Service}} {{.Status}}' 2>/dev/null | awk '/Restarting/{print $1}')
fi

# --- report -----------------------------------------------------------------
if (( PROBLEMS == 0 && QUIET == 1 )); then exit 0; fi

echo
echo "  Checking this site's settings"
echo "  -----------------------------"
printf '%s' "$out"
echo
if (( PROBLEMS > 0 )); then
  echo "  $PROBLEMS thing(s) need fixing. Fix the file named in each line above,"
  echo "  then run ./sitesync doctor again."
  echo
  exit 1
fi
echo "  Everything checks out.${NOTES:+ ($NOTES note(s) above are informational.)}"
echo
exit 0
