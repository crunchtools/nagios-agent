#!/bin/bash
# Check if a podman container is running (used as Nagios host check)
# Usage: check_container_running.sh <container-name>

NAME="$1"

STATE=$(podman inspect --format '{{.State.Status}}' "$NAME" 2>/dev/null)

if [ "$STATE" = "running" ]; then
    echo "OK - Container $NAME is running"
    exit 0
elif [ -n "$STATE" ]; then
    echo "CRITICAL - Container $NAME is $STATE"
    exit 2
else
    echo "CRITICAL - Container $NAME not found"
    exit 2
fi
