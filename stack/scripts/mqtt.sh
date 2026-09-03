#!/usr/bin/env bash
# Manage the people and systems allowed to connect to MQTT.
# Reached through: ./sitesync mqtt <command>
set -euo pipefail

USERS=mqtt-users.conf
PASSWD=configuration/mosquitto/config/passwd
MOSQ_IMAGE="eclipse-mosquitto:${MOSQUITTO_VERSION:-2}"

b() { printf '\n\033[1m%s\033[0m\n' "$*"; }
p() { printf '%s\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n\n' "$*" >&2; exit 1; }

randpw() {  # random password; avoids SIGPIPE under `set -o pipefail`
  local s=""
  while (( ${#s} < ${1:-24} )); do
    s+="$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${s:0:${1:-24}}"
}

valid_role() {
  case "$1" in
    integration|integration-rw|gateway|admin) return 0 ;;
    gateway:*) [[ -n "${1#gateway:}" ]] && return 0 || return 1 ;;
    *) return 1 ;;
  esac
}

roles_help() {
  p "  integration      read application data only          (most common)"
  p "  integration-rw   read application data, send downlinks"
  p "  gateway          a gateway running its own bridge"
  p "  gateway:EUI      the same, locked to one gateway ID"
}

ensure_files() {
  [[ "${MQTT_AUTH_ENABLED:-true}" == "true" ]] \
    || die "MQTT_AUTH_ENABLED is false in .env, so there are no MQTT users to manage."
  [[ -f "$USERS" ]] || cp mqtt-users.conf.example "$USERS"
}

user_exists() { grep -qE "^[[:space:]]*$1[[:space:]]" "$USERS" 2>/dev/null; }

# Write the password into the hashed file inside the broker image, and leave it
# owned by the user the broker actually runs as. Skipping that ownership step
# produces "Unable to open pwfile" and a broker that restarts forever.
set_password() {
  local user="$1" pass="$2" flag=""
  [[ -f "$PASSWD" ]] || flag="-c"
  docker run --rm -v "$PWD/configuration/mosquitto/config:/mosquitto/config" \
    "$MOSQ_IMAGE" sh -euc '
      mosquitto_passwd -b $0 /mosquitto/config/passwd "$1" "$2" >/dev/null
      chown mosquitto:mosquitto /mosquitto/config/passwd 2>/dev/null \
        || chown 1883:1883 /mosquitto/config/passwd
      chmod 640 /mosquitto/config/passwd
    ' "$flag" "$user" "$pass"
}

reload_broker() {
  # Mosquitto rereads its users and permissions on SIGHUP. Nothing disconnects.
  docker compose kill -s HUP mosquitto >/dev/null 2>&1 \
    && p "  Broker reloaded. No connections were dropped." \
    || p "  (broker is not running -- the change takes effect at next start)"
}

handoff() {  # handoff <user> <role> [password]
  local user="$1" role="$2" pass="${3:-}"
  local host="${SITE_DOMAIN:-this host}"
  b "MQTT connection details for '$user'"
  p "  ---------------------------------------------------------------"
  p "  Host        $host"
  if [[ "${MQTT_TLS:-off}" != "off" ]]; then
    p "  Port        ${MQTT_TLS_PORT:-8883}   (encrypted -- use this one)"
    p "  Port        ${MQTT_PORT:-1883}   (unencrypted)"
    p "  CA file     certs/mqtt-ca.pem must be copied to the client"
  else
    p "  Port        ${MQTT_PORT:-1883}"
  fi
  p "  Username    $user"
  [[ -n "$pass" ]] && p "  Password    $pass"
  p "  Role        $role"
  case "$role" in
    integration|integration-rw)
      p "  Subscribe   application/+/device/+/event/up" ;;
    gateway*)
      p "  Topics      ${REGION:-<region>}/gateway/..." ;;
  esac
  p "  ---------------------------------------------------------------"
  if [[ -n "$pass" ]]; then
    p
    p "  Copy the password NOW. It is stored hashed and cannot be shown again."
    p "  If it is lost, anyone can run:  ./sitesync mqtt reset $user"
  fi
}

# -----------------------------------------------------------------------------
cmd_add() {
  ensure_files
  local user="${1:-}" role="${2:-}"
  if [[ -z "$user" ]]; then
    read -r -p "Username (no spaces): " user </dev/tty
  fi
  [[ -n "$user" ]] || die "A username is required."
  [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || die "Use only letters, numbers, dots, dashes and underscores in a username."
  user_exists "$user" && die "'$user' already exists. To give them a new password: ./sitesync mqtt reset $user"

  if [[ -z "$role" ]]; then
    b "What should '$user' be allowed to do?"
    roles_help
    read -r -p "Role [integration]: " role </dev/tty
    role="${role:-integration}"
  fi
  valid_role "$role" || { b "'$role' is not a role. Choose one of:"; roles_help; exit 1; }

  local pass; pass="$(randpw)"
  printf '%-22s %s\n' "$user" "$role" >> "$USERS"
  set_password "$user" "$pass"
  bash scripts/render.sh >/dev/null
  reload_broker
  handoff "$user" "$role" "$pass"
}

cmd_reset() {
  ensure_files
  local user="${1:-}"
  [[ -n "$user" ]] || die "Which user? Try: ./sitesync mqtt list"
  user_exists "$user" || die "There is no MQTT user called '$user'. See ./sitesync mqtt list"
  local role; role="$(awk -v u="$user" '$1==u{print $2}' "$USERS" | head -1)"
  local pass; pass="$(randpw)"
  set_password "$user" "$pass"
  reload_broker
  handoff "$user" "$role" "$pass"
}

cmd_remove() {
  ensure_files
  local user="${1:-}"
  [[ -n "$user" ]] || die "Which user? Try: ./sitesync mqtt list"
  user_exists "$user" || die "There is no MQTT user called '$user'."
  read -r -p "Remove '$user' and stop it connecting? [y/N]: " a </dev/tty
  [[ "${a,,}" == y* ]] || { p "Nothing was changed."; exit 0; }
  grep -vE "^[[:space:]]*$user[[:space:]]" "$USERS" > "$USERS.tmp" && mv "$USERS.tmp" "$USERS"
  docker run --rm -v "$PWD/configuration/mosquitto/config:/mosquitto/config" \
    "$MOSQ_IMAGE" sh -euc '
      mosquitto_passwd -D /mosquitto/config/passwd "$1" >/dev/null 2>&1 || true
      chown mosquitto:mosquitto /mosquitto/config/passwd 2>/dev/null \
        || chown 1883:1883 /mosquitto/config/passwd
      chmod 640 /mosquitto/config/passwd
    ' _ "$user" || true
  bash scripts/render.sh >/dev/null
  reload_broker
  p "Removed '$user'."
}

cmd_list() {
  ensure_files
  b "MQTT users for ${SITE_LABEL:-this site}"
  printf '  %-22s %-16s %s\n' "USERNAME" "ROLE" "CAN CONNECT"
  local any=0
  while read -r user role _; do
    [[ -z "${user:-}" || "${user:0:1}" == "#" ]] && continue
    any=1
    local state="no password set"
    grep -q "^$user:" "$PASSWD" 2>/dev/null && state="yes"
    printf '  %-22s %-16s %s\n' "$user" "$role" "$state"
  done < "$USERS"
  (( any )) || p "  (none yet -- add one with: ./sitesync mqtt add NAME integration)"
  p
  p "  Passwords are stored hashed and cannot be displayed."
  p "  To give someone a new one:  ./sitesync mqtt reset NAME"
  p
  p "  ChirpStack's own internal login is separate and lives in .env."
}

cmd_show() {
  ensure_files
  local user="${1:-}"
  [[ -n "$user" ]] || die "Which user? Try: ./sitesync mqtt list"
  user_exists "$user" || die "There is no MQTT user called '$user'."
  handoff "$user" "$(awk -v u="$user" '$1==u{print $2}' "$USERS" | head -1)" ""
  p
  p "  The password is not shown because it is stored hashed."
  p "  If they do not have it: ./sitesync mqtt reset $user"
}

case "${1:-list}" in
  add)     shift; cmd_add "$@" ;;
  reset|passwd) shift; cmd_reset "$@" ;;
  remove|rm|delete) shift; cmd_remove "$@" ;;
  list|ls) cmd_list ;;
  show|handoff) shift; cmd_show "$@" ;;
  roles)   b "Available roles"; roles_help ;;
  *) die "Unknown: ./sitesync mqtt $1  (try: add, list, show, reset, remove, roles)" ;;
esac
