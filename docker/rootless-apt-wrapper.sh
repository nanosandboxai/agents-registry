#!/bin/sh
# Rootless apt-get/apt wrapper for nanosandbox code agents.
#
# Uses user namespace remapping (like Sysbox/Podman rootless) to give
# apt-get a full UID/GID range. Inside the namespace the process is root
# with all 65536 UIDs mapped, so apt's privilege-dropping to _apt works.
# Outside the namespace the real UID is still 1000 (developer).
#
# Requires: uidmap package (newuidmap/newgidmap with suid),
#           /etc/subuid and /etc/subgid configured for developer.
#
# This wrapper is placed at /usr/local/bin/apt-get and /usr/local/bin/apt,
# taking PATH precedence over /usr/bin/apt-get and /usr/bin/apt.

# Resolve the real binary name (apt-get or apt) based on how we were invoked
REAL_BIN="/usr/bin/$(basename "$0")"

exec unshare --user --map-user=0 --map-group=0 \
    --map-users=auto --map-groups=auto -- \
    "$REAL_BIN" "$@"
