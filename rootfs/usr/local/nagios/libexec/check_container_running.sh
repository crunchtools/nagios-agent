#!/bin/bash
# Check if a podman container is running via API socket (pure bash)
# Usage: check_container_running.sh <container-name>

NAME="$1"
SOCK="/run/podman/podman.sock"

RAW=$(curl -s --unix-socket "$SOCK" "http://localhost/v5.0.0/containers/${NAME}/json" 2>/dev/null)

if echo "$RAW" | grep -q '"cause"'; then
    echo "CRITICAL - Container $NAME not found"
    exit 2
fi

if echo "$RAW" | grep -q '"Running":true'; then
    echo "OK - Container $NAME is running"
    exit 0
else
    STATUS=$(echo "$RAW" | grep -o '"Status":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "CRITICAL - Container $NAME is ${STATUS:-unknown}"
    exit 2
fi
