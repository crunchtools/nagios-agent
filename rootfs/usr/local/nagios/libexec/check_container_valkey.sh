#!/bin/bash
# Check Valkey/Redis health inside a container via valkey-cli/redis-cli
# Standard approach from check_redis pattern — PING + memory + clients
# Usage: check_container_valkey.sh <container> [warn_mem_mb] [crit_mem_mb]

CONTAINER="$1"
WARN_MEM="${2:-200}"
CRIT_MEM="${3:-400}"

if [ -z "$CONTAINER" ]; then
    echo "UNKNOWN - Usage: $0 <container> [warn_mem_mb] [crit_mem_mb]"
    exit 3
fi

CLI=""
if /usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" which valkey-cli >/dev/null 2>&1; then
    CLI="valkey-cli"
elif /usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" which redis-cli >/dev/null 2>&1; then
    CLI="redis-cli"
else
    echo "UNKNOWN - No valkey-cli or redis-cli found in $CONTAINER"
    exit 3
fi

PONG=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" $CLI PING 2>&1)
if [ "$PONG" != "PONG" ]; then
    echo "CRITICAL - Valkey in $CONTAINER not responding to PING: $PONG"
    exit 2
fi

INFO=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" $CLI INFO memory 2>/dev/null)
MEM_BYTES=$(echo "$INFO" | grep -oP 'used_memory:\K\d+')
MEM_RSS=$(echo "$INFO" | grep -oP 'used_memory_rss:\K\d+')
MEM_MB=$((${MEM_BYTES:-0} / 1048576))
MEM_RSS_MB=$((${MEM_RSS:-0} / 1048576))

CLIENTS_INFO=$(/usr/local/nagios/libexec/podman_exec.sh "$CONTAINER" $CLI INFO clients 2>/dev/null)
CLIENTS=$(echo "$CLIENTS_INFO" | grep -oP 'connected_clients:\K\d+')

PERFDATA="memory_mb=${MEM_MB};${WARN_MEM};${CRIT_MEM};0; rss_mb=${MEM_RSS_MB};;;0; clients=${CLIENTS:-0};;;0;"

if [ "$MEM_MB" -ge "$CRIT_MEM" ]; then
    echo "CRITICAL - Valkey in $CONTAINER: ${MEM_MB}MB used, ${CLIENTS:-0} clients | $PERFDATA"
    exit 2
elif [ "$MEM_MB" -ge "$WARN_MEM" ]; then
    echo "WARNING - Valkey in $CONTAINER: ${MEM_MB}MB used, ${CLIENTS:-0} clients | $PERFDATA"
    exit 1
else
    echo "OK - Valkey in $CONTAINER: ${MEM_MB}MB used, ${CLIENTS:-0} clients | $PERFDATA"
    exit 0
fi
