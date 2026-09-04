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

_region_field() {  # _region_field <file> <field>
  sed -n "s/^[[:space:]]*$2=\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

# Every region file as "RF_REGION<TAB>region_id<TAB>description"
region_table() {
  local f cn id de
  for f in "$REGION_DIR"/region_*.toml; do
    [[ -f "$f" ]] || continue
    cn="$(_region_field "$f" common_name)"
    id="$(_region_field "$f" id)"
    de="$(_region_field "$f" description)"
    [[ -n "$cn" && -n "$id" ]] || continue
    printf '%s\t%s\t%s\n' "$(sed 's/_[0-9]\+$//' <<<"$cn")" "$id" "$de"
  done | sort
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
