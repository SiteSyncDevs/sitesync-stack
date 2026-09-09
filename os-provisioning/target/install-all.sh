#!/usr/bin/env bash
# Renamed to install.sh in 2026-09, when the installer learned to install only
# some components and "all" stopped being true.
#
# This shim exists because the old name is written down in runbooks, tickets
# and emails, and the person typing it is usually standing at a customer site
# with no way to look anything up. Delete it once those have caught up.
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
echo "note: install-all.sh is now install.sh -- running that instead." >&2
exec bash "$HERE/install.sh" "$@"
