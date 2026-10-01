#!/bin/bash
# Execute a command inside a container via the Podman REST API socket
# Replaces `podman exec` for environments without the podman CLI
# Usage: podman_exec.sh <container-name> <command> [args...]
# Returns: stdout and stderr from the command, exit code from the exec.
# Exits 3 on a usage error, when the exec cannot be created, or when the API
# reports no exit code.

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

# Decode the multiplexed stream. Each frame is an 8-byte header -- stream id,
# three zero bytes, big-endian payload length -- followed by the payload.
#
# The header has to be PARSED. This used to be a filter that kept printable
# characters, on the theory that the header is binary. Its length bytes are
# not: a 2609-byte payload has length 0x0A31, which is a newline and the digit
# 1, and both came out in front of the command's output. Any plugin comparing
# or counting that output got two extra characters whenever the size happened
# to land on printable bytes.
#
# od | gawk keeps this to a constant-memory byte loop; nothing is buffered, so
# a large exec output cannot push the agent toward its memory cap. stdout and
# stderr frames are both kept, as before. The printable filter stays as the
# last step because callers rely on the output being plain ASCII.
od -An -v -tx1 "$TMPOUT" | LC_ALL=C gawk '
    {
        for (i = 1; i <= NF; i++) {
            byte = strtonum("0x" $i)
            if (remaining > 0) { printf "%c", byte; remaining--; continue }
            header[filled++] = byte
            if (filled == 8) {
                remaining = header[4] * 16777216 + header[5] * 65536 + header[6] * 256 + header[7]
                filled = 0
            }
        }
    }' | tr -cd '\011\012\015\040-\176'

# No exit code means the start or inspect call failed. That used to fall
# through as 0, so a broken exec looked like a command that succeeded and
# printed nothing.
if [ -z "$EXIT_CODE" ]; then
    echo "EXEC_ERROR: no exit code for exec in container $CONTAINER" >&2
    exit 3
fi

exit "$EXIT_CODE"
