#!/usr/bin/env bash
# Turns .env and mqtt-users.conf into the config files Mosquitto reads.
# Called automatically by ./sitesync start and ./sitesync apply.
# Safe to run repeatedly; it only rewrites files it owns.
set -euo pipefail

# If anything below fails, say so plainly rather than stopping silently.
trap 'echo "" >&2; echo "Could not finish applying the MQTT settings. Nothing was started." >&2; echo "Run ./sitesync doctor, or ask for help with the message above." >&2' ERR

. "$(dirname "${BASH_SOURCE[0]}")/lib-regions.sh"

CONF_D=configuration/mosquitto/conf.d
PASSWD=configuration/mosquitto/config/passwd
ACL=configuration/mosquitto/config/acl
USERS=mqtt-users.conf
MOSQ_IMAGE="eclipse-mosquitto:${MOSQUITTO_VERSION:-2}"

mkdir -p "$CONF_D" certs
rm -f "$CONF_D"/*.conf 2>/dev/null || true

randpw() {  # random password; avoids SIGPIPE under `set -o pipefail`
  local s=""
  while (( ${#s} < ${1:-24} )); do
    s+="$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${s:0:${1:-24}}"
}

# The broker runs as uid 1883 and must read this file; so must the operator
# running ./sitesync, which reads it to see who already has a password. Owner
# 1883 covers the broker, the group covers the operator.
#
# On an installed stack that group is 'sitesync', so every admin in it can read
# the file. Using the caller's own primary group there would quietly re-lock it
# to one person on the next apply.
if getent group sitesync >/dev/null 2>&1; then
  HOST_GID="$(getent group sitesync | cut -d: -f3)"
else
  HOST_GID="$(id -g)"
fi

# Repair a passwd file left unreadable by an earlier version (owner 1883,
# group 1883, which locked out the very user running this). Only a root
# container can change it back, and we already have one to hand.
fix_passwd_perms() {
  [[ -f "$PASSWD" ]] || return 0
  [[ -r "$PASSWD" ]] && return 0
  echo "  repairing permissions on $PASSWD ..."
  docker run --rm -v "$PWD/configuration/mosquitto/config:/mosquitto/config" \
    "$MOSQ_IMAGE" sh -euc '
      chown 1883:"$1" /mosquitto/config/passwd
      chmod 640 /mosquitto/config/passwd
    ' _ "$HOST_GID" \
    || { echo "Could not repair $PASSWD. Delete it and re-run: rm $PASSWD" >&2; return 1; }
  [[ -r "$PASSWD" ]] || { echo "$PASSWD is still not readable by $(id -un). Delete it and re-run." >&2; return 1; }
}

set_password() {  # set_password <user> <plaintext>
  local flag=""
  [[ -f "$PASSWD" ]] || flag="-c"
  # mosquitto_passwd runs as root inside the container and creates the file
  # 0600 root:root. The broker then drops to the 'mosquitto' user and cannot
  # read it -- "Unable to open pwfile" and the container restarts forever. So
  # hand it to that user in the same step, while we are still root.
  docker run --rm -v "$PWD/configuration/mosquitto/config:/mosquitto/config" \
    "$MOSQ_IMAGE" sh -euc '
      mosquitto_passwd -b $0 /mosquitto/config/passwd "$1" "$2" >/dev/null
      chown 1883:"$3" /mosquitto/config/passwd
      chmod 640 /mosquitto/config/passwd
    ' "$flag" "$1" "$2" "$HOST_GID"
}

# Turn a role name into Mosquitto permission lines. This is the whole point of
# roles: nobody should ever have to write these by hand.
acl_for_role() {  # acl_for_role <role>
  local role="$1" region="+"   # any sub-band of this site's RF region
  case "$role" in
    admin)
      echo "topic readwrite #" ;;
    integration)
      echo "topic read application/#" ;;
    integration-rw)
      echo "topic read application/#"
      echo "topic write application/+/device/+/command/#" ;;
    gateway)
      echo "topic write $region/gateway/+/event/#"
      echo "topic write $region/gateway/+/state/#"
      echo "topic read  $region/gateway/+/command/#" ;;
    gateway:*)
      local eui="${role#gateway:}"
      echo "topic write $region/gateway/$eui/event/#"
      echo "topic write $region/gateway/$eui/state/#"
      echo "topic read  $region/gateway/$eui/command/#" ;;
    *)
      return 1 ;;
  esac
}

# ------------------------------------------------------- chirpstack.toml -----
# RF_REGION is the fence: every served sub-band must belong to it. It no longer
# decides on its own what is enabled -- SERVED_REGIONS does that, below.
RF_REGION="${RF_REGION:-}"
if [[ -z "$RF_REGION" ]]; then
  echo "RF_REGION is not set in .env. Valid values:" >&2
  rf_regions | awk -F'\t' '{printf "  %-9s (%d frequency plan%s)\n",$1,$2,($2==1?"":"s")}' >&2
  exit 1
fi

mapfile -t _ids < <(region_ids_for "$RF_REGION")
if (( ${#_ids[@]} == 0 )); then
  echo "RF_REGION is '$RF_REGION', which is not a region this stack knows about." >&2
  echo "Valid values:" >&2
  rf_regions | awk -F'\t' '{printf "  %-9s (%d frequency plan%s)\n",$1,$2,($2==1?"":"s")}' >&2
  exit 1
fi

# ------------------------------------------------------- served regions ------
# One list drives both what ChirpStack enables and what containers exist. A
# region is enabled because something serves it -- a bridge container, or a
# gateway running ChirpStack's MQTT Forwarder straight into the broker.
served_load
_served="$SERVED_VALUE"
if (( SERVED_FROM_LEGACY )); then
  echo "  note: .env still uses GATEWAY_BRIDGES; migrating it to SERVED_REGIONS"
  if [[ -f .env ]] && grep -q '^GATEWAY_BRIDGES=' .env; then
    # Keep the old line, commented, so nothing is silently rewritten out from
    # under someone who goes looking for it.
    awk -v v="$_served" '
      /^GATEWAY_BRIDGES=/ && !done {
        print "# Renamed to SERVED_REGIONS on " strftime("%Y-%m-%d") ". The old line is kept here"
        print "# for reference only -- SERVED_REGIONS below is what takes effect."
        print "#" $0
        print "SERVED_REGIONS=\"" v "\""
        done = 1
        next
      }
      { print }
    ' .env > .env.tmp && mv .env.tmp .env
    chmod 600 .env 2>/dev/null || true
    echo "  .env updated: SERVED_REGIONS=\"$_served\""
  fi
fi

if [[ -z "$_served" ]]; then
  echo "SERVED_REGIONS is empty, so no region would be enabled and this site would" >&2
  echo "serve no gateway at all. Set it in .env, for example:" >&2
  echo "    SERVED_REGIONS=\"${_ids[0]}:1700\"        a gateway bridge on UDP 1700" >&2
  echo "    SERVED_REGIONS=\"${_ids[0]}:forwarder\"   gateways run the MQTT Forwarder" >&2
  echo "or add one interactively with:  ./sitesync region add" >&2
  exit 1
fi

served_parse "$_served" SERVED_REGIONS || { printf '%s\n' "$SERVED_ERROR" >&2; exit 1; }

_quoted=""
for _id in "${SERVED_IDS[@]}"; do _quoted+="${_quoted:+, }\"$_id\""; done
sed "s|__ENABLED_REGIONS__|$_quoted|" \
  configuration/chirpstack/chirpstack.toml.template \
  > configuration/chirpstack/chirpstack.toml
echo "  $RF_REGION: ${#SERVED_IDS[@]} region(s) enabled -- $(served_describe)"

# ------------------------------------------------- gateway bridge instances ---
# One gateway bridge per SERVED_REGIONS entry that names a port. Compose cannot
# loop, so the services are generated into a second compose file that .env
# points COMPOSE_FILE at. That makes the number of bridges unlimited -- a site
# can serve an 8-channel sub-band and a 16-channel one side by side.
#
# Entries marked "forwarder" deliberately produce nothing here: their gateways
# publish to the broker themselves, so a bridge would be a port bound to
# nothing. The region is still enabled, which is what makes them work.
mkdir -p compose
GW_FILE=compose/gateways.yml
{
  echo "# Generated by ./sitesync apply from SERVED_REGIONS in .env."
  echo "# Do not edit. Change SERVED_REGIONS and run ./sitesync apply."
  echo "services:"
} > "$GW_FILE"

_n=0
for _sub in "${SERVED_IDS[@]}"; do
  _port="${SERVED_HOW[$_sub]}"
  if [[ "$_port" == forwarder ]]; then
    echo "  $_sub: enabled, served by the gateway's own MQTT Forwarder (no bridge)"
    continue
  fi
  _n=$((_n+1))
  _svc="gateway-bridge-${_sub//_/-}"

  cat >> "$GW_FILE" <<YML

  ${_svc}:
    image: chirpstack/chirpstack-gateway-bridge:\${GATEWAY_BRIDGE_VERSION:-4}
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "\${LOG_MAX_SIZE:-10m}"
        max-file: "\${LOG_MAX_FILES:-3}"
    ports:
      - "\${BIND_ADDRESS:-0.0.0.0}:${_port}:1700/udp"
    volumes:
      - ./configuration/chirpstack-gateway-bridge:/etc/chirpstack-gateway-bridge:ro
      - ./certs:/certs:ro
    environment:
      - TZ=\${TZ:-UTC}
      - INTEGRATION__MQTT__EVENT_TOPIC_TEMPLATE=${_sub}/gateway/{{ .GatewayID }}/event/{{ .EventType }}
      - INTEGRATION__MQTT__STATE_TOPIC_TEMPLATE=${_sub}/gateway/{{ .GatewayID }}/state/{{ .StateType }}
      - INTEGRATION__MQTT__COMMAND_TOPIC_TEMPLATE=${_sub}/gateway/{{ .GatewayID }}/command/#
      - INTEGRATION__MQTT__AUTH__GENERIC__SERVERS=\${MQTT_BROKER_URL:-tcp://mosquitto:1883}
      - INTEGRATION__MQTT__AUTH__GENERIC__CA_CERT=\${MQTT_CA_CERT:-}
      - INTEGRATION__MQTT__AUTH__GENERIC__USERNAME=\${MQTT_USERNAME:-}
      - INTEGRATION__MQTT__AUTH__GENERIC__PASSWORD=\${MQTT_PASSWORD:-}
    depends_on:
      - mosquitto
YML
  echo "  gateway bridge: $_sub on UDP port $_port"
done

# No bridges is a valid site now, not a broken one: every gateway may be
# running the MQTT Forwarder. Compose still needs a syntactically whole file.
if (( _n == 0 )); then
  {
    echo "# Generated by ./sitesync apply from SERVED_REGIONS in .env."
    echo "# Every served region uses the gateway's own MQTT Forwarder, so there"
    echo "# is no bridge container to run. This empty file is expected."
    echo "services: {}"
  } > "$GW_FILE"
  echo "  no bridge containers needed -- every region is served by MQTT Forwarder"
fi

# ---------------------------------------------------------------- login ------
if [[ "${MQTT_AUTH_ENABLED:-true}" == "true" ]]; then
  if [[ -z "${MQTT_USERNAME:-}" || -z "${MQTT_PASSWORD:-}" ]]; then
    echo "MQTT_AUTH_ENABLED is true but MQTT_USERNAME or MQTT_PASSWORD is empty in .env." >&2
    echo "Either fill both in, or set MQTT_AUTH_ENABLED=false." >&2
    exit 1
  fi

  cat > "$CONF_D/10-auth.conf" <<'EOF'
# Generated from .env by ./sitesync apply -- edits here are overwritten.
allow_anonymous false
password_file /mosquitto/config/passwd
acl_file /mosquitto/config/acl
EOF

  fix_passwd_perms || exit 1

  [[ -f "$USERS" ]] || cp mqtt-users.conf.example "$USERS"

  # ChirpStack's own internal login always exists and always has full access.
  set_password "$MQTT_USERNAME" "$MQTT_PASSWORD"

  {
    echo "# Generated by ./sitesync apply from mqtt-users.conf -- do not edit."
    echo "# Change what someone can do by changing their ROLE, then run apply."
    echo
    echo "# ChirpStack itself (username comes from .env)"
    echo "user $MQTT_USERNAME"
    acl_for_role admin
    echo
  } > "$ACL"

  KNOWN=("$MQTT_USERNAME")
  NEW_PASSWORDS=""
  while read -r user role _; do
    [[ -z "${user:-}" || "${user:0:1}" == "#" ]] && continue
    if ! LINES="$(acl_for_role "$role" 2>/dev/null)"; then
      echo "mqtt-users.conf: '$user' has an unknown role '$role'." >&2
      echo "Valid roles: integration, integration-rw, gateway, gateway:EUI" >&2
      exit 1
    fi
    KNOWN+=("$user")
    { echo "user $user"; printf '%s\n' "$LINES"; echo; } >> "$ACL"

    # A user listed here but with no password yet is new. Give them one and
    # show it once -- it is stored hashed and cannot be recovered later.
    if [[ -f "$PASSWD" && ! -r "$PASSWD" ]]; then
      echo "$PASSWD exists but cannot be read by $(id -un)." >&2
      echo "Delete it and run ./sitesync apply again to reissue passwords:  rm $PASSWD" >&2
      exit 1
    fi
    if ! grep -q "^$user:" "$PASSWD" 2>/dev/null; then
      pw="$(randpw)"
      set_password "$user" "$pw"
      NEW_PASSWORDS+="    $user  ($role)  password: $pw"$'\n'
    fi
  done < "$USERS"

  # Anyone whose line was deleted from mqtt-users.conf loses their login.
  if [[ -f "$PASSWD" ]]; then
    while IFS=: read -r existing _; do
      [[ -z "$existing" ]] && continue
      keep=0
      for k in "${KNOWN[@]}"; do [[ "$k" == "$existing" ]] && keep=1 && break; done
      if (( ! keep )); then
        docker run --rm -v "$PWD/configuration/mosquitto/config:/mosquitto/config" \
          "$MOSQ_IMAGE" sh -euc '
            mosquitto_passwd -D /mosquitto/config/passwd "$1" >/dev/null 2>&1 || true
            chown 1883:"$2" /mosquitto/config/passwd
            chmod 640 /mosquitto/config/passwd
          ' _ "$existing" "$HOST_GID" || true
        echo "  Removed MQTT user '$existing' (no longer listed in mqtt-users.conf)."
      fi
    done < "$PASSWD"
  fi

  # The ACL holds usernames and topic patterns, no secrets, and the broker
  # must be able to read it whatever the operator's umask happens to be.
  chmod 644 "$ACL" 2>/dev/null || true

  if [[ -n "$NEW_PASSWORDS" ]]; then
    printf '\n\033[1m  New MQTT passwords -- copy these now, they cannot be shown again\033[0m\n'
    printf '%s' "$NEW_PASSWORDS"
    printf '  If one is lost, anyone can run:  ./sitesync mqtt reset NAME\n\n'
  fi
else
  cat > "$CONF_D/10-auth.conf" <<'EOF'
# Generated from .env by ./sitesync apply -- edits here are overwritten.
# MQTT_AUTH_ENABLED=false: anyone who can reach the port may connect.
allow_anonymous true
EOF
  rm -f "$PASSWD" "$ACL" 2>/dev/null || true
fi

# ------------------------------------------------------------ encryption -----
case "${MQTT_TLS:-off}" in
  off) : ;;
  self-signed)
    if [[ ! -f certs/mqtt-cert.pem || ! -f certs/mqtt-key.pem ]]; then
      echo "Creating a self-signed MQTT certificate for ${SITE_DOMAIN:-localhost} ..."
      # Deliberately no container fallback here. Pulling an image to do this
      # would reach the internet, and these machines often have none -- the
      # failure would appear only at a customer site. openssl ships with
      # Ubuntu Server.
      command -v openssl >/dev/null 2>&1 || {
        echo "MQTT_TLS=self-signed needs the 'openssl' command, which is not installed." >&2
        echo "  Install it:   sudo apt-get install -y openssl" >&2
        echo "  Or set MQTT_TLS=off in .env if you do not need encrypted MQTT." >&2
        exit 1
      }
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout certs/mqtt-key.pem -out certs/mqtt-cert.pem \
        -subj "/CN=${SITE_DOMAIN:-localhost}" \
        -addext "subjectAltName=DNS:${SITE_DOMAIN:-localhost}" 2>/dev/null
      cp certs/mqtt-cert.pem certs/mqtt-ca.pem
      chmod 600 certs/mqtt-key.pem 2>/dev/null || true
      echo "Done. Copy certs/mqtt-ca.pem onto each client so it trusts this broker."
    fi
    ;;
  custom)
    for f in mqtt-cert.pem mqtt-key.pem mqtt-ca.pem; do
      [[ -f "certs/$f" ]] || { echo "MQTT_TLS=custom but certs/$f is missing." >&2; exit 1; }
    done
    ;;
  *)
    echo "MQTT_TLS in .env must be one of: off, self-signed, custom (found '${MQTT_TLS}')." >&2
    exit 1 ;;
esac

if [[ "${MQTT_TLS:-off}" != "off" ]]; then
  cat > "$CONF_D/20-tls.conf" <<'EOF'
# Generated from .env by ./sitesync apply -- edits here are overwritten.
# The plain listener on 1883 stays enabled so clients can be migrated one at a
# time. Remove it from mosquitto.conf once every client uses 8883.
listener 8883
protocol mqtt
cafile   /mosquitto/certs/mqtt-ca.pem
certfile /mosquitto/certs/mqtt-cert.pem
keyfile  /mosquitto/certs/mqtt-key.pem
require_certificate false
EOF
fi
