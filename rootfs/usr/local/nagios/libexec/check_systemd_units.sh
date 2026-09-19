#!/bin/bash
# Check for failed systemd units on the host

FAILED=$(systemctl --state=failed --no-legend --no-pager 2>/dev/null | grep -c "failed")

if [ "$FAILED" -gt 0 ]; then
    UNITS=$(systemctl --state=failed --no-legend --no-pager 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    echo "CRITICAL - ${FAILED} failed units: ${UNITS}"
    exit 2
else
    echo "OK - No failed systemd units"
    exit 0
fi
