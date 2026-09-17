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

  This asks eight questions and writes a file called .env.

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

# --- 3. which sub-bands -------------------------------------------------------
# Sub-bands are chosen in full here, and only then does the next question ask
# how gateways reach them. The two used to be interleaved -- the transport
# question came first, above the menu -- so by the time the tech had scrolled
# through twenty us915_* rows the answer they had just given was off the top of
# the screen, and they were picking sub-bands without remembering what they had
# said. One list, one decision, then the next decision.
b "3 of 8  --  Which sub-bands does this site serve?"
p "Only the sub-bands you list here are enabled on the server."
p ""

CHOSEN=()
if (( ${#SUBBANDS[@]} == 1 )); then
  CHOSEN=("${SUBBANDS[0]}")
  p "$RF_REGION has a single frequency plan, so there is nothing to choose:"
  p "${SUBBANDS[0]} it is."
else
  p "Most sites serve exactly one sub-band. Add more only if different"
  p "gateways use different channel plans."
  p ""
  region_menu "${SUBBANDS[@]}"
  p ""
  p "If you are unsure, the first one in the list is the usual choice."
  p ""
  while :; do
    _sb="$(ask "Sub-band $(( ${#CHOSEN[@]} + 1 ))" "${SUBBANDS[0]}")"
    if [[ "$(rf_of_region_id "$_sb")" != "$RF_REGION" ]]; then
      p "  '$_sb' is not a sub-band of $RF_REGION. Pick one from the list above."
      continue
    fi
    if [[ " ${CHOSEN[*]-} " == *" $_sb "* ]]; then
      p "  $_sb is already in the list. Pick a different sub-band."
      continue
    fi
    CHOSEN+=("$_sb")
    p "  added: $_sb"
    p ""
    yesno "Serve another sub-band" n || break
  done
fi
p ""
p "Sub-bands: ${CHOSEN[*]}"

# --- 4. how gateways connect --------------------------------------------------
# One question, three answers. It used to be two separate yes/no prompts in two
# different sections -- one here and one at the old step 7 -- which meant
# "both" was reachable by accident: answering no here and yes there produced
# forwarder-mode SERVED_REGIONS with UDP bridge containers also running, and
# nothing said a word about it. Making "both" an explicit third choice is the
# whole fix.
b "4 of 8  --  How do the gateways reach this server?"
p "  1) Semtech UDP packet forwarder"
p "       This machine listens on a UDP port and the gateway sends packets"
p "       at it. This is what almost every gateway ships set up for, and it"
p "       is the right answer unless you know otherwise.   RECOMMENDED"
p ""
p "  2) ChirpStack MQTT Forwarder"
p "       The gateway runs ChirpStack's own forwarder and publishes straight"
p "       to our broker. Nothing listens here, and no bridge containers are"
p "       created. Those gateways need an MQTT login, which you make later"
p "       with  ./sitesync mqtt add"
p ""
p "  3) Both"
p "       Only if this site genuinely has some of each. It runs the bridge"
p "       containers as well, so it costs more than picking one."
p ""
case "$(ask 'Choose' '1')" in
  2) TRANSPORT=forwarder ;;
  3) TRANSPORT=both ;;
  *) TRANSPORT=udp ;;
esac

PROFILES=()
SERVED=""
case "$TRANSPORT" in
  forwarder)
    for _sb in "${CHOSEN[@]}"; do SERVED="${SERVED:+$SERVED }$_sb:forwarder"; done
    p ""
    p "Noted -- no bridge containers will be created."
    ;;
  *)
    # UDP, or both. Ports are asked for now that the sub-band list is settled,
    # so the tech is answering "which port for THIS one" against a list they
    # have already seen rather than building both at once.
    #
    # "Both" needs nothing extra here. A gateway running the MQTT Forwarder
    # publishes straight onto the same region topics the bridges use, so the
    # bridge containers serve the UDP gateways and the forwarder gateways just
    # arrive. The only difference is that those gateways need an MQTT login.
    PROFILES+=(udp)
    _port=1700
    if (( ${#CHOSEN[@]} == 1 )); then
      SERVED="${CHOSEN[0]}:1700"
      p ""
      p "One sub-band, so one gateway connection on the standard port:"
      p "${CHOSEN[0]} on UDP 1700."
    else
      p ""
      p "Each sub-band needs its own UDP port. 1700 is the standard one; the"
      p "rest just have to be free and reachable from the gateways."
      p ""
      for _sb in "${CHOSEN[@]}"; do
        while :; do
          _p="$(ask "  UDP port for $_sb" "$_port")"
          [[ "$_p" =~ ^[0-9]+$ ]] || { p "  '$_p' is not a port number."; continue; }
          if [[ " $SERVED " == *":$_p "* ]]; then
            p "  port $_p is already used by another connection."
            continue
          fi
          break
        done
        SERVED="${SERVED:+$SERVED }$_sb:$_p"
        p "  $_sb on UDP port $_p"
        _port=$(( _p + 1 ))
      done
    fi
    ;;
esac

# The REST API is not offered as a choice: other SiteSync components call it,
# so a site without it is a broken site, not a leaner one. It is still a
# profile rather than a plain service, because that is how it was shipped and
# existing .env files name it.
PROFILES+=(rest-api)

set_var SERVED_REGIONS "\"$SERVED\""
set_var COMPOSE_PROFILES "$(IFS=,; echo "${PROFILES[*]}")"
p ""
p "Regions served: $SERVED"
p "The REST API is always installed -- other SiteSync components rely on it."
if [[ "$TRANSPORT" == both ]]; then
  p ""
  p "Gateways running the MQTT Forwarder publish onto these same sub-bands, so"
  p "there is nothing more to set up for them here -- but each one needs an MQTT"
  p "login. Make them with:  ./sitesync mqtt add"
fi

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

# RFC1918, plus CGNAT (100.64/10) and link-local. A machine behind NAT -- which
# is every cloud VM -- can only ever see this side of the translation, so the
# address we detect is not the address anyone types. That is the single biggest
# source of wrong answers here, and it is worth saying out loud rather than
# presenting the private IP as though it were the answer.
is_private_addr() {
  case "$1" in
    10.*|192.168.*|169.254.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}

# A fully-qualified hostname, if the machine has been given one, is a better
# answer than any IP -- it survives the address changing. Only offer it when it
# is actually qualified: the bare short hostname resolves nowhere useful.
FQDN="$(hostname -f 2>/dev/null || true)"
[[ "$FQDN" == *.* && "$FQDN" != *.local ]] || FQDN=""

b "5 of 8  --  What address will people type in their browser?"
p "This has to be EXACTLY what they type -- a DNS name (chirpstack.acme.local)"
p "or an IP address (192.168.1.50). It is not just a label:"
p ""
p "  * the security certificate is issued for this exact value, and"
p "  * the web server only answers to this exact value."
p ""
p "Get it wrong and the site refuses connections from other machines, or shows"
p "a certificate warning that never goes away no matter what you click."
p ""
if [[ "$DEFAULT_ADDR" == localhost ]]; then
  p "I could not work out this machine's network address automatically."
else
  p "This machine sees itself at $DEFAULT_ADDR."
fi

if [[ -n "$FQDN" ]]; then
  p ""
  p "It also has the hostname $FQDN. If that name resolves to this machine"
  p "for the people who will use the site, it is the better answer -- a name"
  p "survives the IP changing."
fi

if is_private_addr "$DEFAULT_ADDR"; then
  p ""
  p "  NOTE: $DEFAULT_ADDR is a private address, and it may not be the address"
  p "  you reached this machine on. On a cloud VM (Azure, AWS) or behind any"
  p "  NAT or load balancer, the machine cannot see its own public address --"
  p "  it only ever sees this side of the translation."
  p ""
  p "  So do not just press Enter here. Look at what you typed to get in:"
  p "  the name or IP in your SSH command, or in your browser's address bar."
  p "  If that is not $DEFAULT_ADDR, type it in below instead."
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    p ""
    p "  (You are connected over SSH from $(awk '{print $1}' <<<"$SSH_CONNECTION").)"
  fi
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
p "Noted:"
p "  the certificate will be issued for   $SITE_DOMAIN"
p "  the web server will answer only to   $SITE_DOMAIN"
p ""
p "Anything else -- a different IP, a different name -- will be refused or will"
p "warn. If that turns out to be wrong, it is one line: edit SITE_DOMAIN in .env"
p "and run ./sitesync apply."

# --- 4. TLS -------------------------------------------------------------------
b "6 of 8  --  How should the web interface be secured?"
p "  1) self-signed  HTTPS straight away, nothing to obtain or renew."
p "                  Browsers show a one-time warning you click past."
p "                  RECOMMENDED unless you already have a certificate."
p "  2) off          Plain HTTP. Only for a trusted, private network."
p "  3) letsencrypt  Real trusted HTTPS, free and automatic -- but needs a public"
p "                  domain name pointing here, and ports 80 and 443 reachable"
p "                  from the internet so the certificate can be renewed."
p "  4) custom       You already have a certificate file to use."
p ""
p "This does not change the address. The site is on port 8080 in every case;"
p "only http:// or https:// changes."
p "You can switch between these later by changing one word in .env."
case "$(ask 'Choose' '1')" in
  2) TLS_MODE=off ;;
  3) TLS_MODE=letsencrypt ;;
  4) TLS_MODE=custom ;;
  *) TLS_MODE=self-signed ;;
esac
set_var TLS_MODE "$TLS_MODE"

# Only letsencrypt publishes ports 80 and 443, and only because ACME has to
# answer there to issue and renew. Every other mode leaves them unbound, so
# this is rewritten both ways -- a site switched away from letsencrypt later
# must not keep binding them.
if [[ "$TLS_MODE" == letsencrypt ]]; then
  set_var COMPOSE_FILE "docker-compose.yml:compose/gateways.yml:compose/acme.yml"
else
  set_var COMPOSE_FILE "docker-compose.yml:compose/gateways.yml"
fi

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
b "7 of 8  --  Should MQTT require a login?"
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
b "8 of 8  --  Should MQTT traffic be encrypted?"
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

# Basics Station is deliberately not asked about. It was a question every tech
# had to answer and no site we run actually uses, sitting immediately after a
# near-identical UDP question -- two prompts describing the same decision, which
# is exactly what made the old step 7 confusing. The profile and its
# configuration/chirpstack-gateway-bridge/*-basicstation-*.toml files are still
# in the tree: a site that needs it adds `basicstation` to COMPOSE_PROFILES in
# .env and runs ./sitesync apply.

# --- 7. secrets ---------------------------------------------------------------
b "Generating secrets"
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
# Through ./sitesync, not `bash scripts/doctor.sh`. doctor.sh reads its settings
# from the environment and does not load .env itself -- ./sitesync does that for
# it. Run directly, it saw no variables at all and ended a perfectly good setup
# with six bogus "[ FIX ]" lines: RF_REGION not set, TLS_MODE empty, secrets
# empty. All of them had just been written to .env one screen earlier.
./sitesync doctor || true
p ""
if yesno "Start the site now" y; then
  ./sitesync start
  # Starting generates more files (broker config, certificates) as root.
  hand_back_ownership
else
  p "When you are ready:  ./sitesync start"
fi

# Hand over the connection details explicitly. Without this the install ends
# with a running site and no statement of how to reach it, and the tech goes
# looking -- for the web port, for the MQTT port, for the password. Every one
# of those is already known here, so say them.
p ""
./sitesync info || true

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
