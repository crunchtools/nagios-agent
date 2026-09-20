#!/bin/bash
# Execute a command inside a container via the Podman REST API socket
# Replaces `podman exec` for environments without the podman CLI
# Usage: podman_exec.sh <container-name> <command> [args...]
# Returns: stdout from the command, exit code from the exec

CONTAINER="$1"
shift
SOCK="/run/podman/podman.sock"
TMPOUT=$(mktemp /tmp/podman_exec.XXXXXX)
trap "rm -f $TMPOUT" EXIT

if [ -z "$CONTAINER" ] || [ $# -eq 0 ]; then
    echo "Usage: podman_exec.sh <container> <command> [args...]" >&2
    exit 3
fi

CMD_JSON=""
for arg in "$@"; do
    arg=$(echo "$arg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    CMD_JSON="${CMD_JSON}\"${arg}\","
done
CMD_JSON="${CMD_JSON%,}"

EXEC_RESPONSE=$(curl -s --unix-socket "$SOCK" \
    -X POST "http://localhost/v5.0.0/containers/${CONTAINER}/exec" \
    -H "Content-Type: application/json" \
    -d "{\"Cmd\":[${CMD_JSON}],\"AttachStdout\":true,\"AttachStderr\":true}" 2>/dev/null)

EXEC_ID=$(echo "$EXEC_RESPONSE" | grep -oP '"Id"\s*:\s*"\K[^"]+')

if [ -z "$EXEC_ID" ]; then
    echo "EXEC_ERROR: Cannot create exec in container $CONTAINER" >&2
    exit 3
fi

curl -s --unix-socket "$SOCK" \
    -X POST "http://localhost/v5.0.0/exec/${EXEC_ID}/start" \
    -H "Content-Type: application/json" \
    -d '{"Detach":false}' -o "$TMPOUT" 2>/dev/null

INSPECT=$(curl -s --unix-socket "$SOCK" \
    "http://localhost/v5.0.0/exec/${EXEC_ID}/json" 2>/dev/null)
EXIT_CODE=$(echo "$INSPECT" | grep -oP '"ExitCode"\s*:\s*\K[0-9]+')

# Strip Docker multiplexed stream frame headers (8-byte binary frames)
# Keep only printable ASCII, tabs, newlines — remove all other bytes
tr -cd '\011\012\015\040-\176' < "$TMPOUT"

exit ${EXIT_CODE:-0}
