#!/usr/bin/env bash
# Checks the settings in .env and the state of the machine, and explains any
# problem in plain language. Run it any time: ./sitesync doctor
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib-regions.sh"

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

# --- radio region and gateway bridges ---------------------------------------
RF_REGION="${RF_REGION:-}"
if [[ -z "$RF_REGION" ]]; then
  bad "RF_REGION is not set in .env."
elif [[ -z "$(region_ids_for "$RF_REGION")" ]]; then
  bad "RF_REGION is '$RF_REGION', which is not a radio region this stack knows."
  out+="            Valid: $(rf_regions | cut -f1 | tr '\n' ' ')"$'\n'
else
  mapfile -t _sb < <(region_ids_for "$RF_REGION")
  if (( ${#_sb[@]} == 1 )); then
    ok "$RF_REGION: 1 frequency plan enabled on the server."
  else
    ok "$RF_REGION: all ${#_sb[@]} frequency plans enabled on the server."
  fi

  # The generated file must actually reflect RF_REGION. If someone edited the
  # template or apply never ran, the server is running a different region set
  # than .env claims -- gateways would connect and uplinks go nowhere.
  if [[ -f configuration/chirpstack/chirpstack.toml ]]; then
    _missing=()
    for _id in "${_sb[@]}"; do
      grep -q "\"$_id\"" configuration/chirpstack/chirpstack.toml || _missing+=("$_id")
    done
    if (( ${#_missing[@]} )); then
      bad "the generated chirpstack.toml does not enable: ${_missing[*]}
            Run ./sitesync apply to regenerate it from RF_REGION."
    fi
  else
    note "configuration/chirpstack/chirpstack.toml has not been generated yet."
    out+="            ./sitesync apply creates it from the template and RF_REGION."$'\n'
  fi

  # Gateway bridges
  if [[ -z "${GATEWAY_BRIDGES:-}" ]]; then
    bad "GATEWAY_BRIDGES is empty, so no gateway bridge runs and NO GATEWAY can
            reach this site. Set it in .env, for example:
                GATEWAY_BRIDGES=\"${_sb[0]}:1700\""
  else
    _nb=0; _bad=0
    declare -A _ports=()
    for _e in ${GATEWAY_BRIDGES}; do
      _s="${_e%%:*}"; _p="${_e##*:}"
      if [[ "$_s" == "$_e" || -z "$_p" ]]; then
        bad "GATEWAY_BRIDGES entry '$_e' is malformed. Use sub-band:port, e.g. ${_sb[0]}:1700"
        _bad=1; continue
      fi
      if [[ -z "$(rf_of_region_id "$_s")" ]]; then
        bad "GATEWAY_BRIDGES names '$_s', which is not a known frequency plan."
        _bad=1; continue
      fi
      if [[ "$(rf_of_region_id "$_s")" != "$RF_REGION" ]]; then
        bad "GATEWAY_BRIDGES names '$_s', which belongs to $(rf_of_region_id "$_s"), not $RF_REGION.
            Gateways on that plan would connect and their uplinks would go nowhere."
        _bad=1; continue
      fi
      if [[ ! "$_p" =~ ^[0-9]+$ ]]; then
        bad "GATEWAY_BRIDGES: '$_p' is not a port number (entry '$_e')."; _bad=1; continue
      fi
      if [[ -n "${_ports[$_p]:-}" ]]; then
        bad "GATEWAY_BRIDGES uses port $_p for both ${_ports[$_p]} and $_s. Each needs its own."
        _bad=1; continue
      fi
      _ports[$_p]="$_s"
      _nb=$((_nb+1))
    done
    if (( _bad == 0 )); then
      _list=""
      for k in $(printf '%s\n' "${!_ports[@]}" | sort -n); do
        _list+="${_list:+, }${_ports[$k]} on UDP $k"
      done
      if (( _nb == 1 )); then ok "1 gateway bridge: $_list"; else ok "$_nb gateway bridges: $_list"; fi
    fi
  fi

  # The generated compose file has to exist, or compose will not even start.
  if [[ ! -f compose/gateways.yml ]]; then
    note "compose/gateways.yml has not been generated yet; ./sitesync apply creates it."
  fi
  case "${COMPOSE_FILE:-}" in
    *compose/gateways.yml*) ;;
    "") bad "COMPOSE_FILE is not set in .env. It must be:
                COMPOSE_FILE=docker-compose.yml:compose/gateways.yml
            Without it Docker ignores the gateway bridges entirely." ;;
    *)  bad "COMPOSE_FILE does not include compose/gateways.yml, so the gateway
            bridges are ignored. It should be:
                COMPOSE_FILE=docker-compose.yml:compose/gateways.yml" ;;
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
    if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      note "SITE_DOMAIN is an IP address. That works, but a DNS name is better:"
      out+="            an IP cannot get a publicly trusted certificate, so you are stuck"$'\n'
      out+="            with self-signed, and the certificate breaks if the address changes."$'\n'
    fi
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

# --- can a browser actually complete a TLS handshake? -----------------------
# Everything above checks configuration. This checks the thing the user sees.
# A certificate can exist, be valid, and still be unservable: browsers send no
# SNI for a bare IP address, and without default_sni Caddy then matches no site
# and aborts the handshake. That failure is invisible to every other check here.
if [[ "${TLS_MODE:-}" != "off" ]] && command -v openssl >/dev/null 2>&1 \
   && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  _hp="${HTTPS_PORT:-443}"
  if timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$_hp" 2>/dev/null; then
    _named=0 _bare=0
    timeout 8 openssl s_client -connect "127.0.0.1:$_hp" -servername "$DOMAIN" \
      </dev/null 2>/dev/null | grep -q 'BEGIN CERTIFICATE\|Certificate chain' && _named=1
    timeout 8 openssl s_client -connect "127.0.0.1:$_hp" \
      </dev/null 2>/dev/null | grep -q 'BEGIN CERTIFICATE\|Certificate chain' && _bare=1

    if (( _named && _bare )); then
      ok "the web server completes a TLS handshake the way a browser does."
    elif (( _named && ! _bare )); then
      bad "the certificate works only when the client sends a server name, and
            browsers do NOT send one for a bare IP address. Every browser will
            show an SSL protocol error.
        Fix: configuration/caddy/Caddyfile needs this in its global block:
                default_sni {\$SITE_DOMAIN}
        then run ./sitesync apply"
    elif (( ! _named && ! _bare )); then
      bad "the web server is listening on port $_hp but will not complete a TLS
            handshake at all. See what it says:  ./sitesync logs caddy"
    fi
  else
    note "nothing is listening on port $_hp yet, so TLS was not tested. Start the site first."
  fi
fi

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
  printf 'POSTGRES_PASSWORD=x\nCHIRPSTACK_API_SECRET=x\nRF_REGION=%s\n' "${RF_REGION:-EU868}" > "$_envf"
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

# --- does the database actually accept the password in .env? ----------------
# POSTGRES_PASSWORD is applied ONLY when the database volume is first created.
# If the volume outlives a change to .env -- a reinstall that did not remove
# volumes, or someone editing the password -- postgres keeps the old one and
# ChirpStack cannot log in. The symptom is an endless
# "password authentication failed for user chirpstack" and a stack that never
# comes up, with nothing obviously wrong in any config file.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker compose ps --services --status running 2>/dev/null | grep -qx postgres; then
    if docker compose exec -T -e PGPASSWORD="${POSTGRES_PASSWORD:-}" postgres \
         psql -h 127.0.0.1 -U chirpstack -d chirpstack -c 'select 1' >/dev/null 2>&1; then
      ok "the database accepts the password in .env."
    else
      bad "the database is running but rejects the password in .env.
            The database was created with a different POSTGRES_PASSWORD and keeps
            it: that password is only ever applied when the volume is first made.
        Either KEEP the data and change the password to match .env:
            docker compose exec -T postgres psql -U chirpstack -d postgres \\
              -c \"ALTER USER chirpstack WITH PASSWORD '\$POSTGRES_PASSWORD';\"
        or DISCARD the database and start clean (destroys all device data):
            docker compose down -v && ./sitesync start"
    fi
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
