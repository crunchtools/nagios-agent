#!/bin/bash
# check_sqlite_rows.sh — a SQLite table holds at least N rows (RT #1542)
# Usage: check_sqlite_rows.sh <db-path> <table> [min-rows]
#
# Written for mcp-trove's index, /var/srv/mcp-trove.crunchtools.com/data/trove.db.
# An index that silently comes back empty looks healthy from every other angle:
# the container runs, the port answers, the nightly timer exits 0. Searches just
# return nothing. So:
#
#   CRITICAL  database missing, table missing, or fewer than min-rows (default 1)
#   UNKNOWN   sqlite3 absent, database unreadable, or the query failed otherwise
#
# READ-ONLY, AND AS NRPE. The file is opened with a mode=ro URI through the
# read-only /var/srv mount, so this can never create, lock for write or
# checkpoint the database. Trove keeps it in WAL mode; SQLite reads a WAL
# database read-only when the -wal and -shm files already exist, which they do
# while trove runs. Measured on lotor as uid nrpe through that mount: 104 rows,
# rc 0. No root escalation, because the file is 0644 in 0755 directories.

set -uo pipefail

DB="${1:-}"
TABLE="${2:-}"
MIN="${3:-1}"
TMO=${SQLITE_TIMEOUT:-10}

if [ -z "$DB" ] || [ -z "$TABLE" ]; then
    echo "SQLITE UNKNOWN - usage: check_sqlite_rows.sh <db-path> <table> [min-rows]"
    exit 3
fi
# The path goes into a file: URI unescaped, so ?, # and % are refused rather
# than encoded. The table is interpolated into SQL, so it must be a bare name.
if ! [[ "$DB" =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ "$DB" == *..* ]]; then
    echo "SQLITE UNKNOWN - invalid database path"
    exit 3
fi
if ! [[ "$TABLE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "SQLITE UNKNOWN - invalid table name"
    exit 3
fi
if ! [[ "$MIN" =~ ^[0-9]+$ ]]; then
    echo "SQLITE UNKNOWN - min-rows must be a non-negative integer"
    exit 3
fi

command -v sqlite3 >/dev/null || { echo "SQLITE UNKNOWN - sqlite3 not installed in the agent image"; exit 3; }
[ -e "$DB" ] || { echo "SQLITE CRITICAL - $DB does not exist | rows=0;;$MIN:;0"; exit 2; }
[ -r "$DB" ] || { echo "SQLITE UNKNOWN - $DB is not readable by $(id -un)"; exit 3; }

# .timeout rides out a writer's brief lock; timeout bounds the whole call well
# inside the fast pool's 15s command_timeout.
out=$(timeout "$TMO" sqlite3 -batch -noheader -cmd ".timeout 3000" \
    "file:${DB}?mode=ro" "SELECT count(*) FROM \"${TABLE}\";" 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then
    if [[ "$out" == *"no such table"* ]]; then
        echo "SQLITE CRITICAL - table ${TABLE} missing from $DB | rows=0;;$MIN:;0"
        exit 2
    fi
    [ "$rc" -eq 124 ] && out="query timed out after ${TMO}s"
    echo "SQLITE UNKNOWN - $(printf '%s' "$out" | head -n1)"
    exit 3
fi
if ! [[ "$out" =~ ^[0-9]+$ ]]; then
    echo "SQLITE UNKNOWN - unexpected sqlite3 output: $(printf '%s' "$out" | head -n1)"
    exit 3
fi

perf="rows=${out};;$MIN:;0"
if [ "$out" -lt "$MIN" ]; then
    echo "SQLITE CRITICAL - ${TABLE} has $out rows (min $MIN) in $DB | $perf"
    exit 2
fi
echo "SQLITE OK - ${TABLE} has $out rows in $DB | $perf"
exit 0
