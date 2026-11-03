#!/bin/bash
# Check the opendkim signing milter inside a mail relay container.
# Usage: check_container_opendkim.sh <container>
#
# The relay runs with milter_default_action = accept, so a dead signer does
# not stop mail — it sends it unsigned. Nothing else reports that: postfix
# logs a successful delivery either way, and the first sign of trouble would
# be our mail landing in spam weeks later. This check is the warning. RT#1548.
#
# Both probes run in one exec. The socket matters as much as the process —
# a signer that is up but not accepting connections fails the same silent
# way — and folding them together halves the Podman API round-trips.

CONTAINER="$1"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container>"
    exit 3
fi

EXEC=${PODMAN_EXEC:-/usr/local/nagios/libexec/podman_exec.sh}

PROBE='kill -0 "$(cat /run/opendkim/opendkim.pid 2>/dev/null)" 2>/dev/null || { echo nopid; exit 0; }; exec 3<>/dev/tcp/127.0.0.1/8891 2>/dev/null || { echo nosocket; exit 0; }; echo ok'

OUT=$("$EXEC" "$CONTAINER" sh -c "$PROBE" 2>&1)
RC=$?

if [ $RC -ne 0 ]; then
    echo "UNKNOWN - cannot reach $CONTAINER: $OUT"
    exit 3
fi

case "$(echo "$OUT" | tr -d '[:space:]')" in
    ok)
        echo "OK - opendkim running and listening in $CONTAINER | opendkim_up=1;;;0;1"
        exit 0
        ;;
    nopid)
        echo "CRITICAL - opendkim not running in $CONTAINER: outbound mail is going out unsigned | opendkim_up=0;;;0;1"
        exit 2
        ;;
    nosocket)
        echo "CRITICAL - opendkim in $CONTAINER is not listening on 127.0.0.1:8891: postfix cannot sign | opendkim_up=0;;;0;1"
        exit 2
        ;;
    *)
        echo "UNKNOWN - unexpected probe result from $CONTAINER: $OUT"
        exit 3
        ;;
esac
