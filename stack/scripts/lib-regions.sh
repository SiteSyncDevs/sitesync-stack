#!/usr/bin/env bash
# Shared knowledge about the ChirpStack region files. Sourced by render.sh,
# setup.sh and doctor.sh so the three can never disagree about what a region is.
#
# Vocabulary, because ChirpStack overloads the word "region":
#   RF REGION   what the radio actually is -- US915, EU868, AU915. This is what
#               an operator knows and what they pick during setup.
#   REGION ID   one frequency-plan file: us915_0, us915_12, us915_64ch. A single
#               RF region can have many. Picking US915 enables all 16 of them.
#   SUB-BAND    a region id used as a gateway's channel plan, e.g. us915_0.
#
# The RF region is the file's common_name with any trailing _<digits> removed,
# so the four AS923 plans (AS923, AS923_2, AS923_3, AS923_4) group under AS923.

REGION_DIR="${REGION_DIR:-configuration/chirpstack}"

# Every region file as "RF_REGION<TAB>region_id<TAB>description"
#
# One awk pass over every file, not four sed invocations and a subshell per
# file. There are 30-odd region files, and the old shape cost roughly 120
# processes per call -- with region_description called once per sub-band, that
# was thousands of processes to print a 16-line menu, and it showed.
#
# Written for mawk (Ubuntu's default awk), so no ENDFILE and no gensub: the
# end of a file is detected by FNR==1 on the next one.
_region_table_build() {
  local f found=0
  for f in "$REGION_DIR"/region_*.toml; do [[ -f "$f" ]] && { found=1; break; }; done
  (( found )) || return 0

  awk '
    function val(s) {
      if (match(s, /"[^"]*"/)) return substr(s, RSTART + 1, RLENGTH - 2)
      return ""
    }
    function emit(   rf) {
      if (cn != "" && id != "") {
        rf = cn
        sub(/_[0-9]+$/, "", rf)
        printf "%s\t%s\t%s\n", rf, id, de
      }
    }
    FNR == 1 { if (NR > 1) emit(); cn = ""; id = ""; de = "" }
    cn == "" && /^[[:space:]]*common_name[[:space:]]*=/  { cn = val($0) }
    id == "" && /^[[:space:]]*id[[:space:]]*=/           { id = val($0) }
    de == "" && /^[[:space:]]*description[[:space:]]*=/  { de = val($0) }
    END { emit() }
  ' "$REGION_DIR"/region_*.toml | sort
}

# Built once per process. Every caller below goes through this, and several of
# them are called in a loop, so the difference is the whole cost of the menu.
_REGION_TABLE_CACHE=""
region_table() {
  if [[ -z "$_REGION_TABLE_CACHE" ]]; then
    _REGION_TABLE_CACHE="$(_region_table_build)"
  fi
  [[ -n "$_REGION_TABLE_CACHE" ]] && printf '%s\n' "$_REGION_TABLE_CACHE"
  return 0
}

# Distinct RF regions, with how many region files each has.
rf_regions() { region_table | cut -f1 | uniq -c | awk '{print $2"\t"$1}'; }

# Every region id belonging to one RF region, ordered so plain sub-bands come
# before the wider variants -- that is the order an operator expects to read.
region_ids_for() {  # region_ids_for US915
  region_table | awk -F'\t' -v r="$1" '$1==r {print $2}' \
    | awk '{ print length($0), $0 }' | sort -n -k1,1 -k2,2 | cut -d' ' -f2-
}

# Which RF region does a region id belong to? Empty if it does not exist.
rf_of_region_id() {  # rf_of_region_id us915_12
  region_table | awk -F'\t' -v i="$1" '$2==i {print $1; exit}'
}

region_description() {  # region_description us915_12
  region_table | awk -F'\t' -v i="$1" '$2==i {print $3; exit}'
}

region_id_exists() { [[ -n "$(rf_of_region_id "$1")" ]]; }

# Print "  <id>  <description>" for each id given, in the order given, using a
# single pass over the table. The obvious loop calling region_description per
# row spawns a subshell and an awk for every line of the menu.
region_menu() {  # region_menu us915_0 us915_1 ...
  (( $# )) || return 0
  region_table | awk -F'\t' -v want="$*" '
    BEGIN { n = split(want, a, " ") }
    { desc[$2] = $3 }
    END { for (i = 1; i <= n; i++) printf "  %-11s %s\n", a[i], desc[a[i]] }
  '
}

# ----------------------------------------------------------- SERVED_REGIONS --
# The sub-bands this site serves, and how each one reaches the server:
#
#     us915_0:1700        a gateway bridge container, listening on UDP 1700
#     us915_1:forwarder   no container -- the gateway runs ChirpStack's own
#                         MQTT Forwarder and publishes to the broker directly
#
# Both kinds enable their region in chirpstack.toml. That is the whole point of
# the list: a region is enabled because something is actually serving it, never
# because it happens to belong to RF_REGION. A forwarder site would otherwise
# have no way to enable a region at all, since it runs no bridge.
#
# Until 2026-09 this was GATEWAY_BRIDGES and held only the port form.

# Declared here so that sourcing this file is enough to make them safe to read
# under `set -u`, whether or not served_load has run yet.
SERVED_VALUE=""
SERVED_FROM_LEGACY=0

# Read the list out of the environment into SERVED_VALUE, falling back to the
# legacy variable and setting SERVED_FROM_LEGACY=1 when it does, so callers can
# offer to migrate.
#
# This sets globals rather than printing, deliberately: a caller writing
# v="$(served_value)" would run it in a subshell and the legacy flag would be
# thrown away with that subshell, leaving the caller reading a stale 0 -- or,
# under `set -u`, aborting on an unset variable.
served_load() {
  SERVED_FROM_LEGACY=0
  SERVED_VALUE="${SERVED_REGIONS:-}"
  if [[ -z "$SERVED_VALUE" && -n "${GATEWAY_BRIDGES:-}" ]]; then
    SERVED_VALUE="$GATEWAY_BRIDGES"
    SERVED_FROM_LEGACY=1
  fi
}

SERVED_ERROR=""
_served_fail() { SERVED_ERROR="$1"; }

# Parse and validate. On success sets:
#   SERVED_IDS[]      region ids, in the order given
#   SERVED_HOW[id]    the UDP port, or the word "forwarder"
#   SERVED_BRIDGES    how many of them are bridge containers
# On the first bad entry it returns 1 and leaves the reason in SERVED_ERROR.
# Every caller reports the same wording for the same mistake because they all
# land here.
#
# The reason goes in a variable rather than to stderr so that a caller can
# format it -- doctor.sh indents it under a heading, sitesync dies with it. A
# caller doing why="$(served_parse ...)" to capture stderr would run the whole
# parse in a subshell and get empty SERVED_IDS back, which is a bug that looks
# exactly like a correctly-parsed empty list. Call it directly; read the two
# globals after.
served_parse() {  # served_parse <value> [<variable name to blame>]
  local value="$1" var="${2:-SERVED_REGIONS}" entry id how rf
  local -a ids=()
  declare -gA SERVED_HOW=()
  declare -ga SERVED_IDS=()
  SERVED_BRIDGES=0
  local -A seen_port=()
  SERVED_ERROR=""

  for entry in $value; do
    [[ -n "$entry" ]] || continue
    id="${entry%%:*}"
    how="${entry##*:}"

    if [[ "$id" == "$entry" || -z "$how" ]]; then
      _served_fail "$var entry '$entry' is malformed. Use sub-band:port or sub-band:forwarder,
for example  us915_0:1700  or  us915_0:forwarder"
      return 1
    fi
    if [[ -n "${SERVED_HOW[$id]:-}" ]]; then
      _served_fail "$var names '$id' twice. Each sub-band belongs in the list once."
      return 1
    fi
    rf="$(rf_of_region_id "$id")"
    if [[ -z "$rf" ]]; then
      _served_fail "$var names sub-band '$id', which is not a frequency plan this stack knows about."
      return 1
    fi
    if [[ -n "${RF_REGION:-}" && "$rf" != "$RF_REGION" ]]; then
      _served_fail "$var names sub-band '$id', which belongs to $rf, not $RF_REGION.
Gateways on that plan would connect and their uplinks would go nowhere."
      return 1
    fi

    if [[ "$how" == forwarder ]]; then
      : # nothing to bind; the gateway publishes to MQTT itself
    elif [[ "$how" =~ ^[0-9]+$ ]]; then
      if (( how < 1 || how > 65535 )); then
        _served_fail "$var: '$how' is not a usable port number (entry '$entry')."
        return 1
      fi
      if [[ -n "${seen_port[$how]:-}" ]]; then
        _served_fail "$var uses port $how for both ${seen_port[$how]} and $id.
Each gateway bridge needs its own port."
        return 1
      fi
      seen_port[$how]="$id"
      SERVED_BRIDGES=$(( SERVED_BRIDGES + 1 ))
    else
      _served_fail "$var entry '$entry': '$how' is neither a port number nor the word 'forwarder'."
      return 1
    fi

    SERVED_HOW[$id]="$how"
    ids+=("$id")
  done

  SERVED_IDS=("${ids[@]+"${ids[@]}"}")
  return 0
}

# "us915_0 on UDP 1700, us915_1 via MQTT Forwarder" -- for status and doctor.
served_describe() {
  local id out=""
  for id in "${SERVED_IDS[@]+"${SERVED_IDS[@]}"}"; do
    if [[ "${SERVED_HOW[$id]}" == forwarder ]]; then
      out+="${out:+, }$id via MQTT Forwarder"
    else
      out+="${out:+, }$id on UDP ${SERVED_HOW[$id]}"
    fi
  done
  printf '%s' "$out"
}

# The lowest UDP port not already taken by a bridge, for suggesting a default.
served_next_port() {
  local id port=1700 taken=1
  while (( taken )); do
    taken=0
    for id in "${SERVED_IDS[@]+"${SERVED_IDS[@]}"}"; do
      [[ "${SERVED_HOW[$id]}" == "$port" ]] && { taken=1; port=$(( port + 1 )); break; }
    done
  done
  printf '%s' "$port"
}
