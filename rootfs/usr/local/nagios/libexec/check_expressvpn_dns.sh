#!/bin/bash
# Nagios check: DNS resolution actually traverses the VPN tunnel.
# Derives the resolver from the container's resolv.conf rather than hardcoding
# it -- ExpressVPN pushes an in-tunnel address (100.64.100.1 here, but other
# setups get 10.72.0.1, and it can change on reconnect). Then confirms that
# resolver egresses a tun interface (catches a DNS leak onto the host network),
# and resolves two independent names so one dead domain cannot page us --
# the lesson from gluetun issue #2993.
# Usage: check_expressvpn_dns.sh [container] [name1] [name2]

CONTAINER="${1:-expressvpn.crunchtools.com}"
NAME1="${2:-cloudflare.com}"
NAME2="${3:-github.com}"
EXEC=/usr/local/nagios/libexec/podman_exec.sh

NS=$("$EXEC" "$CONTAINER" cat /etc/resolv.conf 2>/dev/null \
     | tr -d '\r' | awk '/^nameserver/{print $2; exit}')

if [ -z "$NS" ]; then
    echo "UNKNOWN - No nameserver found in ${CONTAINER}:/etc/resolv.conf"
    exit 3
fi

IFACE=$("$EXEC" "$CONTAINER" ip route get "$NS" 2>/dev/null \
        | tr -d '\r' | grep -oE 'dev [a-zA-Z0-9]+' | head -1 | awk '{print $2}')

if [ -z "$IFACE" ]; then
    echo "CRITICAL - No route to resolver ${NS} from ${CONTAINER} (tunnel down?)"
    exit 2
fi

case "$IFACE" in
    tun*|wg*|utun*) ;;
    *)
        echo "CRITICAL - DNS leak: resolver ${NS} egresses ${IFACE}, not the VPN tunnel"
        exit 2 ;;
esac

FAILED=""
for N in "$NAME1" "$NAME2"; do
    "$EXEC" "$CONTAINER" getent hosts "$N" >/dev/null 2>&1 || FAILED="${FAILED} ${N}"
done

FAILED="${FAILED# }"

if [ "$FAILED" = "${NAME1} ${NAME2}" ]; then
    echo "CRITICAL - In-tunnel DNS ${NS} (${IFACE}) resolved neither ${NAME1} nor ${NAME2}"
    exit 2
fi

if [ -n "$FAILED" ]; then
    echo "WARNING - In-tunnel DNS ${NS} (${IFACE}) up, but failed to resolve: ${FAILED}"
    exit 1
fi

echo "OK - In-tunnel DNS ${NS} via ${IFACE} resolved ${NAME1} and ${NAME2}"
exit 0
