#!/usr/bin/env bash
# Shared handling of the Mosquitto password file, sourced by render.sh, mqtt.sh
# and doctor.sh so the three can never disagree about who may read it.
#
# The file is awkward on purpose. It holds password hashes, the broker drops to
# uid 1883 and must be able to read it, and the operators are a group that may
# have several people in it. So: owner 1883, group the operators' group, 0640.
#
# The rule that matters: NOTHING should read this file from the host. A host
# read fails for reasons that are not faults --
#
#   * the operator was added to the 'sitesync' group by the installer, but
#     group membership only reaches a shell at the next login, so the first
#     apply after an install runs without it;
#   * the site was installed before the group existed;
#   * someone ran one command with sudo and the next without.
#
# Every one of those used to surface as "delete the password file and re-run",
# which throws away every MQTT login on the site to fix a permission bit. Read
# it through the container instead, where we are root and it always works.

MOSQ_CONFIG_DIR="${MOSQ_CONFIG_DIR:-configuration/mosquitto/config}"
MOSQ_PASSWD="${MOSQ_PASSWD:-$MOSQ_CONFIG_DIR/passwd}"

# The group that should own the file. On an installed stack that is 'sitesync',
# so every admin in it can be given access without a recursive chown. Falling
# back to the caller's own primary group would quietly re-lock the file to one
# person the next time anyone ran mqtt add.
mqtt_gid() {
  if getent group sitesync >/dev/null 2>&1; then
    getent group sitesync | cut -d: -f3
  else
    id -g
  fi
}

# Every username that currently has a password, one per line.
mqtt_passwd_users() {  # mqtt_passwd_users <mosquitto image>
  [[ -f "$MOSQ_PASSWD" ]] || return 0
  docker run --rm -v "$PWD/$MOSQ_CONFIG_DIR:/mosquitto/config" \
    "$1" sh -c 'cut -d: -f1 /mosquitto/config/passwd 2>/dev/null || true'
}
