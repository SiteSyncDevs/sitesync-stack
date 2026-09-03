#!/usr/bin/env bash
# =============================================================================
#  First-time setup. Asks a handful of questions and writes the .env file.
#
#  Run it with:   bash setup.sh
#
#  Nothing here is permanent -- every answer ends up in .env as a plain line
#  you can edit later, with a comment above it explaining what it does.
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

b() { printf '\n\033[1m%s\033[0m\n' "$*"; }
p() { printf '%s\n' "$*"; }

ask() {  # ask <prompt> <default> -> answer on stdout
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " reply </dev/tty
    printf '%s' "${reply:-$default}"
  else
    while :; do
      read -r -p "$prompt: " reply </dev/tty
      [[ -n "$reply" ]] && { printf '%s' "$reply"; return; }
      p "  (this one cannot be left blank)"
    done
  fi
}

yesno() {  # yesno <prompt> <default y|n>
  local reply
  read -r -p "$1 [$( [[ ${2:-y} == y ]] && echo 'Y/n' || echo 'y/N' )]: " reply </dev/tty
  reply="${reply:-$2}"
  [[ "${reply,,}" == y* ]]
}

randstr() {  # random password; avoids SIGPIPE under `set -o pipefail`
  local s=""
  while (( ${#s} < ${1:-40} )); do
    s+="$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${s:0:${1:-40}}"
}

set_var() {  # set_var KEY VALUE -- rewrites that line, keeps every comment
  local k="$1" v="$2"
  awk -v k="$k" -v v="$v" '
    index($0, k "=") == 1 { print k "=" v; found=1; next }
    { print }
    END { if (!found) print k "=" v }
  ' .env > .env.tmp && mv .env.tmp .env
}

# -----------------------------------------------------------------------------
clear 2>/dev/null || true
cat <<'TXT'
===============================================================================
  SiteSync ChirpStack -- first-time setup
===============================================================================

  This asks about eight questions and writes a file called .env.

  You can change any answer later by opening .env in a text editor and
  running  ./sitesync apply  -- you never have to run this script again.

  Press Enter to accept the suggestion shown in [brackets].
TXT

if [[ -f .env ]]; then
  b "There is already a .env file here."
  if ! yesno "Start over? Your current settings will be copied to .env.bak first" n; then
    p "Leaving it alone. Edit .env directly, then run ./sitesync apply"
    exit 0
  fi
  cp .env ".env.bak.$(date +%Y%m%d-%H%M%S)"
fi
cp .env.example .env

# --- 1. who -------------------------------------------------------------------
b "1 of 8  --  Who is this site for?"
p "A short name, lowercase, no spaces. It names the containers on this machine."
CUSTOMER="$(ask 'Short name' 'acme')"
CUSTOMER="$(printf '%s' "$CUSTOMER" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
SITE_LABEL="$(ask 'Full name, for reports and backups' "$CUSTOMER")"
set_var CUSTOMER "$CUSTOMER"
set_var SITE_LABEL "\"$SITE_LABEL\""

# --- 2. region ----------------------------------------------------------------
b "2 of 8  --  Which LoRaWAN region?"
p "This one answer configures the network server, both gateway bridges and the"
p "MQTT topics together, so they can never disagree."
p ""
p "  1) us915_0   North America        (channels 0-7, the usual choice)"
p "  2) eu868     Europe"
p "  3) au915_0   Australia"
p "  4) as923     Asia"
p "  5) something else (I will show you the full list)"
case "$(ask 'Choose' '1')" in
  1) REGION=us915_0 ;;
  2) REGION=eu868 ;;
  3) REGION=au915_0 ;;
  4) REGION=as923 ;;
  *) p ""
     ls configuration/chirpstack/region_*.toml | sed 's#.*/region_##;s#\.toml##' | column -c 76 2>/dev/null \
       || ls configuration/chirpstack/region_*.toml | sed 's#.*/region_##;s#\.toml##'
     p ""
     while :; do
       REGION="$(ask 'Region' 'us915_0')"
       [[ -f "configuration/chirpstack/region_${REGION}.toml" ]] && break
       p "  There is no region called '$REGION'. Pick one from the list above."
     done ;;
esac
set_var REGION "$REGION"

# --- 3. address ---------------------------------------------------------------
b "3 of 8  --  What will people type in their browser?"
p "A DNS name (chirpstack.acme.local) or an IP address (192.168.1.50)."
p "If you are not sure, an IP address is a safe answer and can be changed later."
SITE_DOMAIN="$(ask 'Address' 'localhost')"
set_var SITE_DOMAIN "$SITE_DOMAIN"

# --- 4. TLS -------------------------------------------------------------------
b "4 of 8  --  How should the web interface be secured?"
p "  1) self-signed  HTTPS straight away, nothing to obtain or renew."
p "                  Browsers show a one-time warning you click past."
p "                  RECOMMENDED unless you already have a certificate."
p "  2) off          Plain HTTP. Only for a trusted, private network."
p "  3) letsencrypt  Real trusted HTTPS, free and automatic -- but needs a public"
p "                  domain name pointing here and ports 80 and 443 open."
p "  4) custom       You already have a certificate file to use."
p ""
p "You can switch between these later by changing one word in .env."
case "$(ask 'Choose' '1')" in
  2) TLS_MODE=off ;;
  3) TLS_MODE=letsencrypt ;;
  4) TLS_MODE=custom ;;
  *) TLS_MODE=self-signed ;;
esac
set_var TLS_MODE "$TLS_MODE"

if [[ "$TLS_MODE" == letsencrypt ]]; then
  p ""
  p "Let's Encrypt emails this address if a renewal ever fails."
  set_var TLS_EMAIL "$(ask 'Email address' '')"
elif [[ "$TLS_MODE" == custom ]]; then
  p ""
  p "Put your certificate in certs/cert.pem and your private key in certs/key.pem"
  p "before starting the site. ./sitesync doctor will tell you if they are missing."
fi

# --- 5. MQTT login ------------------------------------------------------------
b "5 of 8  --  Should MQTT require a login?"
p "Gateways and any integration would need a username and password."
if yesno "Require a login" y; then
  set_var MQTT_AUTH_ENABLED true
  MQTT_USERNAME="$(ask 'MQTT username' 'chirpstack')"
  MQTT_PASSWORD="$(randstr 32)"
  set_var MQTT_USERNAME "$MQTT_USERNAME"
  set_var MQTT_PASSWORD "$MQTT_PASSWORD"
  p "  A password was generated for you. See it any time with: ./sitesync mqtt-info"
else
  set_var MQTT_AUTH_ENABLED false
  p "  MQTT is open to anything that can reach the port. Make sure the network is closed."
fi

# --- 6. MQTT encryption -------------------------------------------------------
b "6 of 8  --  Should MQTT traffic be encrypted?"
p "Say no if gateways are on the same network or a VPN. Say yes if they cross"
p "the public internet. The unencrypted port stays open either way, so you can"
p "move gateways over one at a time."
if yesno "Encrypt MQTT" n; then
  set_var MQTT_TLS self-signed
  p "  A certificate will be created on first start, and written to certs/mqtt-ca.pem"
  p "  for you to copy onto each gateway."
else
  set_var MQTT_TLS off
fi

# --- 7. optional pieces -------------------------------------------------------
b "7 of 8  --  Which gateway protocols does this site use?"
PROFILES=()
yesno "Semtech UDP packet forwarder (the common one)" y && PROFILES+=(udp)
yesno "Basics Station" y && PROFILES+=(basicstation)
yesno "REST / Swagger API" y && PROFILES+=(rest-api)
set_var COMPOSE_PROFILES "$(IFS=,; echo "${PROFILES[*]}")"

# --- 8. secrets ---------------------------------------------------------------
b "8 of 8  --  Generating secrets"
set_var CHIRPSTACK_API_SECRET "$(randstr 48)"
set_var POSTGRES_PASSWORD "$(randstr 32)"
p "Done. These are unique to this site and live only in .env."

chmod 600 .env 2>/dev/null || true

# -----------------------------------------------------------------------------
b "Setup complete."
p "Your settings are in .env. Every line there has a comment explaining it."
p ""
bash scripts/doctor.sh || true
p ""
if yesno "Start the site now" y; then
  ./sitesync start
else
  p "When you are ready:  ./sitesync start"
fi
