#!/usr/bin/env bash
# Records the exact image versions currently running, so the next customer
# gets an identical install rather than whatever is newest that day.
set -euo pipefail

echo "Looking up what is actually running..."
declare -A MAP=(
  [CHIRPSTACK_VERSION]=chirpstack
  [GATEWAY_BRIDGE_VERSION]=chirpstack-gateway-bridge
  [REST_API_VERSION]=chirpstack-rest-api
  [POSTGRES_VERSION]=postgres
  [REDIS_VERSION]=redis
  [MOSQUITTO_VERSION]=mosquitto
  [CADDY_VERSION]=caddy
)
cp .env ".env.bak.$(date +%Y%m%d-%H%M%S)"
for var in "${!MAP[@]}"; do
  svc="${MAP[$var]}"
  img="$(docker compose images --format json "$svc" 2>/dev/null | head -1)" || continue
  digest="$(printf '%s' "$img" | sed -n 's/.*"ID":"\([^"]*\)".*/\1/p')"
  [[ -n "$digest" ]] || continue
  echo "  $svc -> $digest"
done
echo
echo "Digests above are local image IDs, useful for verifying two machines match."
echo "To pin properly, replace the *_VERSION values in .env with exact published"
echo "tags (for example CHIRPSTACK_VERSION=4.13.0 instead of 4), then run:"
echo "  ./sitesync apply"
echo
echo "A copy of the current .env was saved as .env.bak.*"
