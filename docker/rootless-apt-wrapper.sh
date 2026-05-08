#!/bin/sh
# Rootless apt-get/apt wrapper for nanosandbox code agents.
# Uses user namespace (unshare --user) to satisfy dpkg UID checks.
# All state and installed files go to /home/developer/.local/.
#
# This wrapper is placed at /usr/local/bin/apt-get and /usr/local/bin/apt,
# taking PATH precedence over /usr/bin/apt-get and /usr/bin/apt.

PREFIX="/home/developer/.local"

# Audit log
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $(basename "$0") $*" \
    >> "$PREFIX/var/log/pkg-install.log" 2>/dev/null

# Resolve the real binary name (apt-get or apt) based on how we were invoked
REAL_BIN="/usr/bin/$(basename "$0")"

exec unshare --user --map-root-user -- \
    "$REAL_BIN" \
    -o Dir::State="$PREFIX/var/lib/apt" \
    -o Dir::Cache="$PREFIX/cache/apt" \
    -o Dir::Etc="$PREFIX/etc/apt" \
    -o Dir::Log="$PREFIX/var/log" \
    -o DPkg::Options::="--instdir=$PREFIX/usr" \
    -o DPkg::Options::="--admindir=$PREFIX/var/lib/dpkg" \
    "$@"
