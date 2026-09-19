#!/bin/bash
# Check that every systemd unit pulls crunchtools-owned images from quay.io,
# never ghcr.io. Quay is the canonical pull/run source for the fleet; GHCR is
# a mirror only (dual-push for redundancy + OCI auto-linking). Third-party
# images (e.g. ghcr.io/redhatinsights/...) are not ours to police and are
# ignored. Filed per RT #1468.
#
# Reads host unit files via nsenter into PID 1's mount namespace, since this
# container does not bind-mount /etc/systemd/system directly.

VIOLATIONS=$(nsenter -t 1 -m -- grep -lE 'ghcr\.io/crunchtools/' /etc/systemd/system/*.service 2>/dev/null)

if [ -n "$VIOLATIONS" ]; then
    UNITS=$(echo "$VIOLATIONS" | xargs -n1 basename | tr '\n' ' ')
    echo "CRITICAL - units pulling crunchtools images from ghcr.io instead of quay.io: ${UNITS}"
    exit 2
else
    echo "OK - all crunchtools-owned units pull from quay.io"
    exit 0
fi
