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
      note "SITE_DOMAIN is 'localhost' but the site is reachable from the network."
      out+="            People connecting from another computer will get a name mismatch."
      out+=$'\n'"            Set SITE_DOMAIN to the name or IP address they actually type."$'\n'
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
    self-signed|custom) ok "The bundled broker also has an encrypted listener on port ${MQTT_TLS_PORT:-8883}." ;;
    *) bad "MQTT_TLS is '${MQTT_TLS}'. It must be one of: off, self-signed, custom." ;;
  esac
else
  note "This site uses an external broker, so MQTT_TLS and the MQTT user commands do not apply."
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
