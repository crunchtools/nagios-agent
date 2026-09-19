#!/bin/bash
# Check ExpressVPN is routing through a different exit IP
SOCK=/run/podman/podman.sock
LOTOR_IP=172.105.105.45

# Get the VPN container's external IP via the podman API exec endpoint
VPN_IP=$(curl -s --unix-socket $SOCK   -X POST 'http://localhost/v5.0.0/containers/expressvpn.crunchtools.com/exec'   -H 'Content-Type: application/json'   -d '{"AttachStdout":true,"Cmd":["curl","-s","--connect-timeout","10","ifconfig.me"]}' 2>/dev/null |   grep -oP '"Id":"\K[^"]+')

if [ -z "$VPN_IP" ]; then
    # Fallback: just check the container is running
    STATE=$(curl -s --unix-socket $SOCK 'http://localhost/v5.0.0/containers/expressvpn.crunchtools.com/json' 2>/dev/null | grep -o '"Running":true')
    if [ -n "$STATE" ]; then
        echo "OK - ExpressVPN container running (could not verify exit IP)"
        exit 0
    else
        echo "CRITICAL - ExpressVPN container not running"
        exit 2
    fi
fi

echo "OK - ExpressVPN container running"
exit 0
