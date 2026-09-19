#!/bin/bash
# Nagios check: VPN exit IP must differ from the host's real public IP.
# Both IPs come from the ExpressVPN daemon (expressvpnctl get vpnip / pubip), so
# there is no dependency on ifconfig.me or any other third-party echo service.
# NOTE: the exit IP rotates within the provider's pool between calls -- never
# pin an exact value, only assert that it differs from the host IP.
# Usage: check_expressvpn_exit_ip.sh [container] [fallback_host_ip]

CONTAINER="${1:-expressvpn.crunchtools.com}"
FALLBACK_HOST_IP="${2:-172.105.105.45}"
EXEC=/usr/local/nagios/libexec/podman_exec.sh
CTL=/opt/expressvpn/bin/expressvpnctl

ctl() {
    # some 'get' types emit a leading blank line via the exec API -- take the
    # first non-empty line, not the first line
    "$EXEC" "$CONTAINER" "$CTL" get "$1" 2>/dev/null | tr -d '\r' | awk 'NF{print $1; exit}'
}

VPNIP=$(ctl vpnip)
PUBIP=$(ctl pubip)
[ -z "$PUBIP" ] && PUBIP="$FALLBACK_HOST_IP"

if [ -z "$VPNIP" ]; then
    echo "CRITICAL - ExpressVPN daemon reports no exit IP (tunnel down or daemon unreachable)"
    exit 2
fi

if [ "$VPNIP" = "$PUBIP" ] || [ "$VPNIP" = "$FALLBACK_HOST_IP" ]; then
    echo "CRITICAL - VPN leak: exit IP ${VPNIP} matches host public IP"
    exit 2
fi

echo "OK - VPN exit IP ${VPNIP}, host ${PUBIP} (distinct)"
exit 0
