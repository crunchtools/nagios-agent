#!/bin/bash
# Check VPN tunnel health by verifying container exit IP differs from host IP
# Usage: check_container_vpn.sh <container> <host_public_ip>

CONTAINER="$1"
HOST_IP="${2:-172.105.105.45}"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container> <host_public_ip>"
    exit 3
fi

EXIT_IP=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" curl -s --connect-timeout 10 --max-time 15 http://ifconfig.me 2>/dev/null)

if [ -z "$EXIT_IP" ]; then
    echo "CRITICAL - Cannot determine exit IP from $CONTAINER (curl failed or timed out)"
    exit 2
fi

if [ "$EXIT_IP" = "$HOST_IP" ]; then
    echo "CRITICAL - VPN tunnel leak: exit IP ${EXIT_IP} matches host IP"
    exit 2
fi

echo "OK - VPN tunnel active, exit IP ${EXIT_IP} (host ${HOST_IP}) | exit_ip=${EXIT_IP};;;;"
exit 0
