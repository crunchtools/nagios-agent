#!/bin/bash
# Nagios check: ExpressVPN daemon connection state.
# Asks the ExpressVPN daemon itself via expressvpnctl instead of probing a third
# party. Authoritative, ~0.3s, zero network egress, no rate limits.
# Usage: check_expressvpn_state.sh [container]

CONTAINER="${1:-expressvpn.crunchtools.com}"
EXEC=/usr/local/nagios/libexec/podman_exec.sh
CTL=/opt/expressvpn/bin/expressvpnctl

ctl() {
    # some 'get' types emit a leading blank line via the exec API -- take the
    # first non-empty line, not the first line
    "$EXEC" "$CONTAINER" "$CTL" get "$1" 2>/dev/null | tr -d '\r' | awk 'NF{print $1; exit}'
}

STATE=$(ctl connectionstate)

if [ -z "$STATE" ]; then
    echo "UNKNOWN - ExpressVPN daemon not answering in ${CONTAINER} (expressvpnctl returned nothing)"
    exit 3
fi

REGION=$(ctl smart)
PROTO=$(ctl protocol)
DETAIL=""
[ -n "$REGION" ] && DETAIL=" [${REGION}/${PROTO}]"

case "$STATE" in
    Connected)
        echo "OK - ExpressVPN Connected${DETAIL} | vpn_state=1"
        exit 0 ;;
    Connecting|Reconnecting|DisconnectingToReconnect)
        echo "WARNING - ExpressVPN ${STATE}${DETAIL} | vpn_state=0"
        exit 1 ;;
    Interrupted|Disconnected|Disconnecting)
        echo "CRITICAL - ExpressVPN ${STATE}${DETAIL} | vpn_state=0"
        exit 2 ;;
    *)
        echo "UNKNOWN - ExpressVPN unrecognized state '${STATE}'${DETAIL}"
        exit 3 ;;
esac
