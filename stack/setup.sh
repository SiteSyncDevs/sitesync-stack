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
. scripts/lib-regions.sh

b() { printf '\n\033[1m%s\033[0m\n' "$*"; }
p() { printf '%s\n' "$*"; }

# Every prompt reads from the terminal. If there is no terminal -- piped output,
# an automated run -- read fails immediately, and a loop around it would spin
# forever with the installer looking frozen. So a failed read is fatal, loudly.
no_tty() {
  printf '\n%s\n' "setup.sh needs a terminal to ask its questions, and there is none here." >&2
  printf '%s\n' "Run it directly on the console:  sudo bash setup.sh" >&2
  exit 1
}

ask() {  # ask <prompt> <default> -> answer on stdout
  local prompt="$1" default="${2:-}" reply tries=0
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " reply </dev/tty || no_tty
    printf '%s' "${reply:-$default}"
  else
    while (( tries++ < 20 )); do
      read -r -p "$prompt: " reply </dev/tty || no_tty
      [[ -n "$reply" ]] && { printf '%s' "$reply"; return; }
      p "  (this one cannot be left blank)"
    done
    printf '\n%s\n' "No answer after 20 tries; stopping." >&2; exit 1
  fi
}

yesno() {  # yesno <prompt> <default y|n>
  local reply
  read -r -p "$1 [$( [[ ${2:-y} == y ]] && echo 'Y/n' || echo 'y/N' )]: " reply </dev/tty || no_tty
  reply="${reply:-$2}"
  [[ "${reply,,}" == y* ]]
}

# setup.sh is normally run through sudo, so everything it creates -- .env above
# all -- comes out owned by root and mode 600, and the person who ran it then
# cannot read their own configuration ("./sitesync: ./.env: Permission denied").
# Hand it all back at the end.
hand_back_ownership() {
  local u="${SUDO_USER:-}" g
  [[ -n "$u" && "$u" != root ]] || return 0
  id "$u" >/dev/null 2>&1 || return 0

  # An installed stack is owned root:sitesync so that any admin in that group
  # can use it. Where that group exists, keep the model: fix the group and the
  # bits, and leave root owning the files. Chowning everything to one person
  # here would undo it and lock the next admin out.
  if getent group sitesync >/dev/null 2>&1; then
    chgrp -R sitesync . 2>/dev/null || true
    find . -type d -exec chmod 2775 {} + 2>/dev/null || true
    find . -path ./configuration/mosquitto/config/passwd -prune -o -type f -exec chmod g+r {} + 2>/dev/null || true
    [[ -f .env ]] && chmod 640 .env 2>/dev/null
    if [[ -f configuration/mosquitto/config/passwd ]]; then
      chown 1883:sitesync configuration/mosquitto/config/passwd 2>/dev/null || true
      chmod 640 configuration/mosquitto/config/passwd 2>/dev/null || true
    fi
    return 0
  fi

  # No group -- this is a copy run straight from a tarball rather than an
  # installed one. Fall back to handing it to the person who ran sudo.
  g="$(id -gn "$u" 2>/dev/null)" || return 0
  # The MQTT password file is the one exception: it must stay owned by uid 1883,
  # the user the broker drops to, or mosquitto cannot read it and restarts
  # forever. Everything else belongs to the operator.
  find . -path ./configuration/mosquitto/config/passwd -prune -o -print0 2>/dev/null \
    | xargs -0 --no-run-if-empty chown "$u":"$g" 2>/dev/null || true
  [[ -f .env ]] && chmod 600 .env 2>/dev/null
  return 0
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

# --- 2. radio -----------------------------------------------------------------
b "2 of 8  --  Which radio region?"
p "Pick the region your gateways are certified for. It is the name printed on"
p "the gateway's datasheet."
p ""
rf_regions | while IFS=$'\t' read -r rf n; do
  if (( n > 1 )); then
    printf '  %-9s %2d frequency plans\n' "$rf" "$n"
  else
    printf '  %-9s single frequency plan\n' "$rf"
  fi
done
p ""
p "The next question asks which of its sub-bands this site actually serves;"
p "only those are enabled on the server. You can add more later at any time"
p "with  ./sitesync region add"
p ""
while :; do
  RF_REGION="$(ask 'Radio region' 'US915')"
  RF_REGION="${RF_REGION^^}"
  [[ -n "$(region_ids_for "$RF_REGION")" ]] && break
  p "  '$RF_REGION' is not one of the regions listed above."
done
set_var RF_REGION "$RF_REGION"

mapfile -t SUBBANDS < <(region_ids_for "$RF_REGION")
p ""
p "$RF_REGION selected: ${#SUBBANDS[@]} frequency plan(s) enabled on the server."

# --- 2b. served regions -------------------------------------------------------
b "2b of 8  --  Which sub-bands does this site serve?"
p "Only the sub-bands you list here are enabled on the server. Each one is"
p "served in one of two ways:"
p ""
p "  a gateway bridge  this machine listens on a UDP port and the gateway"
p "                    sends the Semtech packet-forwarder protocol at it."
p "                    This is what almost every gateway ships set up for."
p ""
p "  MQTT Forwarder    the gateway runs ChirpStack's own forwarder and"
p "                    publishes straight to our broker. Nothing to listen"
p "                    on here. Those gateways need an MQTT login, which"
p "                    you make later with  ./sitesync mqtt add"
p ""

# Ask once, up front, rather than per sub-band: a site almost never mixes the
# two, and asking every time would be three questions to describe one gateway.
if yesno "Do your gateways use the plain UDP packet forwarder (the common one)" y; then
  DEFAULT_HOW=port
else
  DEFAULT_HOW=forwarder
  p ""
  p "  Noted -- no bridge containers will be created."
fi

SERVED=""
if (( ${#SUBBANDS[@]} == 1 )); then
  # Nothing to choose: one plan.
  if [[ "$DEFAULT_HOW" == port ]]; then
    SERVED="${SUBBANDS[0]}:1700"
    p ""
    p "$RF_REGION has a single frequency plan, so there is one gateway"
    p "connection on the standard port: ${SUBBANDS[0]} on UDP 1700."
  else
    SERVED="${SUBBANDS[0]}:forwarder"
    p ""
    p "$RF_REGION has a single frequency plan: ${SUBBANDS[0]}, served by the"
    p "gateways' own MQTT Forwarder."
  fi
else
  p ""
  p "Most sites serve exactly one sub-band. Add more only if different"
  p "gateways use different channel plans."
  p ""
  region_menu "${SUBBANDS[@]}"
  p ""
  p "If you are unsure, the first one in the list is the usual choice."
  p ""
  _port=1700
  while :; do
    _sb="$(ask "Sub-band $(( $(wc -w <<<"$SERVED") + 1 ))" "${SUBBANDS[0]}")"
    if [[ -z "$(rf_of_region_id "$_sb")" ]] || [[ "$(rf_of_region_id "$_sb")" != "$RF_REGION" ]]; then
      p "  '$_sb' is not a sub-band of $RF_REGION. Pick one from the list above."
      continue
    fi
    if [[ " $SERVED " == *" $_sb:"* ]]; then
      p "  $_sb is already in the list. Pick a different sub-band."
      continue
    fi
    if [[ "$DEFAULT_HOW" == forwarder ]]; then
      SERVED="${SERVED:+$SERVED }$_sb:forwarder"
      p "  added: $_sb, served by the gateways' MQTT Forwarder"
    else
      _p="$(ask "  UDP port for $_sb" "$_port")"
      [[ "$_p" =~ ^[0-9]+$ ]] || { p "  '$_p' is not a port number."; continue; }
      if [[ " $SERVED " == *":$_p "* ]]; then
        p "  port $_p is already used by another connection."
        continue
      fi
      SERVED="${SERVED:+$SERVED }$_sb:$_p"
      p "  added: $_sb on UDP port $_p"
      _port=$(( _p + 1 ))
    fi
    p ""
    yesno "Serve another sub-band" n || break
  done
fi
set_var SERVED_REGIONS "\"$SERVED\""
p ""
p "Regions served: $SERVED"

# --- 3. address ---------------------------------------------------------------
# This machine's own address on the network, offered as the default. Guessing
# "localhost" here is almost always wrong for a server other people connect to.
guess_address() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${ip:-localhost}"
}
DEFAULT_ADDR="$(guess_address)"

b "3 of 8  --  What address will people type in their browser?"
p "This has to be EXACTLY what they type -- a DNS name (chirpstack.acme.local)"
p "or an IP address (192.168.1.50). It is not just a label:"
p ""
p "  * the security certificate is issued for this exact value, and"
p "  * the web server only answers to this exact value."
p ""
p "Get it wrong and the site refuses connections from other machines, or shows"
p "a certificate warning that never goes away no matter what you click."
p ""
if [[ "$DEFAULT_ADDR" != localhost ]]; then
  p "This machine appears to be at $DEFAULT_ADDR on the network."
  p "Use that unless you have a DNS name pointing here, which is better because"
  p "it survives the IP changing."
else
  p "I could not work out this machine's network address automatically."
fi
p ""
p "Only answer 'localhost' if you will use ChirpStack from this machine and"
p "nowhere else -- nobody on the network will be able to reach it."
p ""
_tries=0
while (( _tries++ < 10 )); do
  SITE_DOMAIN="$(ask 'Address' "$DEFAULT_ADDR")"
  # People paste a whole URL. Take the hostname out of it rather than issuing a
  # certificate for "https://1.2.3.4/".
  SITE_DOMAIN="${SITE_DOMAIN#http://}"; SITE_DOMAIN="${SITE_DOMAIN#https://}"
  SITE_DOMAIN="${SITE_DOMAIN%%/*}"; SITE_DOMAIN="${SITE_DOMAIN%%:*}"
  [[ -n "$SITE_DOMAIN" ]] || continue
  if [[ "$SITE_DOMAIN" == localhost ]]; then
    p ""
    p "  Just so it is not a surprise: with 'localhost', opening ChirpStack from"
    p "  any other computer will fail. Only this machine will be able to use it."
    yesno "  Really use localhost" n || { p ""; continue; }
  fi
  break
done
set_var SITE_DOMAIN "$SITE_DOMAIN"
p ""
p "Noted. People will reach this site at $SITE_DOMAIN"
p "If that ever changes, edit SITE_DOMAIN in .env and run ./sitesync apply."

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

# The REST API is not offered as a choice: other SiteSync components call it,
# so a site without it is a broken site, not a leaner one. It is still a
# profile rather than a plain service, because that is how it was shipped and
# existing .env files name it.
PROFILES+=(rest-api)
p "The REST API is always installed -- other SiteSync components rely on it."

set_var COMPOSE_PROFILES "$(IFS=,; echo "${PROFILES[*]}")"

# --- 8. secrets ---------------------------------------------------------------
b "8 of 8  --  Generating secrets"
set_var CHIRPSTACK_API_SECRET "$(randstr 48)"
set_var POSTGRES_PASSWORD "$(randstr 32)"
p "Done. These are unique to this site and live only in .env."

# An artifact install has every image loaded locally and usually no route to a
# registry, so forbid pulling outright. A missing image then fails immediately
# instead of hanging on an unreachable registry.
if [[ "${SITESYNC_AIRGAP:-0}" == 1 ]]; then
  set_var PULL_POLICY never
  p "This is an offline install, so Docker is set never to contact a registry."
fi

chmod 600 .env 2>/dev/null || true
hand_back_ownership

# -----------------------------------------------------------------------------
b "Setup complete."
p "Your settings are in .env. Every line there has a comment explaining it."
p ""
bash scripts/doctor.sh || true
p ""
if yesno "Start the site now" y; then
  ./sitesync start
  # Starting generates more files (broker config, certificates) as root.
  hand_back_ownership
else
  p "When you are ready:  ./sitesync start"
fi

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
  p ""
  if getent group sitesync >/dev/null 2>&1; then
    p "These files belong to the 'sitesync' group, so ./sitesync works without"
    p "sudo once you have logged out and back in to pick up that group."
    p "To give someone else the same access:"
    p "    sudo usermod -aG sitesync,docker THEIR_NAME"
  else
    p "These files now belong to ${SUDO_USER}, so ./sitesync works without sudo"
    p "once you have logged out and back in to pick up the docker group."
  fi
fi
