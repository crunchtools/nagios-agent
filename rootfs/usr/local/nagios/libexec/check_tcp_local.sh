#!/bin/bash
# Check a TCP port on 127.0.0.1 — for services bound to localhost only
PORT=$1
/usr/lib64/nagios/plugins/check_tcp -H 127.0.0.1 -p "${PORT}" -t 10
