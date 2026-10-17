#!/usr/bin/env python3
"""Hermes live context-window occupancy.

WHAT IT MEASURES -- and the trap that makes this non-obvious

state.db keeps every message a session ever had, but only rows with active=1
are still sent to the model. When Hermes compresses, it summarises a span and
marks those rows compacted/active=0; they stay on disk forever and are NOT in
the context any more. Summing the whole transcript measures history, not
occupancy. Measured on this host: one session held 1551 rows totalling ~613k
estimated tokens, of which 61 rows / ~13.9k tokens were active. Only active=1
answers the question. sessions.message_count is the ACTIVE count.

WHAT IT IS FOR

Compression working normally keeps occupancy low and flat. This is a
"compression has stopped keeping up" detector: if occupancy climbs, turns will
start stalling on the 10s turn-hold budget, and nothing else sees that. It only
reports; clearing an agent's working memory is a decision for a person, so the
remediation is named in the output instead.

ACCURACY

token_count is NULL on every row in this Hermes version, so tokens are
estimated at ~4 chars each, plus a fixed floor the transcript cannot see
(system prompt and tool schemas, ~25k tokens here) as OVERHEAD_TOKENS.

HOW IT RUNS: inside the Hermes container via check_hermes_exec.sh and the
podman exec socket, so state.db never leaves its 0700 dir; the database is
opened read-only through a URI so the check never takes a lock on the live
agent's database. A query that fails is UNKNOWN, never OK. (It replaced a
bash script run as root on the host by hermes-probe.timer, in which a failed
query read as "no session", which is OK.)

Usage: check_hermes_context.py [data_dir] [warn_pct] [crit_pct] [active_hours]
                               [overhead_tokens] [context_fallback]
  data_dir          Hermes home inside the container (default /app/.hermes)
  warn_pct          WARNING at this % of the context window (default 70)
  crit_pct          CRITICAL at this % (default 90)
  active_hours      only sessions with a message in this many hours (default 168)
  overhead_tokens   prompt + tool schema floor added to the estimate (default 25000)
  context_fallback  window size when config.yaml has no context_length (default 500000)

Exit: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
"""

import re
import sqlite3
import sys
import time
from pathlib import Path
from typing import NamedTuple

OK, WARNING, CRITICAL, UNKNOWN = 0, 1, 2, 3
CHARS_PER_TOKEN = 4  # token_count is NULL in this Hermes version, so estimate

# Selecting the session needs BOTH conditions; either alone picks wrong.
# ended_at IS NULL alone surfaces sessions abandoned months ago and never
# closed; recency alone ranks a closed session above the live one. Ranked by
# ACTIVE bytes, since that is what occupies the window.
SESSION_SQL = """
    -- Messages are kept forever, so read only what occupies the window: open
    -- sessions with a recent message (one lookup each on messages(session_id,
    -- timestamp)), and of those only their active rows, through
    -- messages(session_id, active, timestamp). History is counted, never read.
    WITH candidates AS (
        SELECT s.id FROM sessions s
        WHERE s.ended_at IS NULL
          AND (SELECT MAX(timestamp) FROM messages WHERE session_id = s.id) >= ?
    )
    SELECT m.session_id,
           COUNT(*),
           SUM(LENGTH(m.content)),
           (SELECT COUNT(*) FROM messages WHERE session_id = m.session_id),
           CAST((julianday('now') - julianday(MAX(m.timestamp), 'unixepoch')) AS INT)
    FROM messages m
    WHERE m.session_id IN (SELECT id FROM candidates) AND m.active = 1
    GROUP BY m.session_id
    ORDER BY SUM(LENGTH(m.content)) DESC
    LIMIT 1
"""
# Share of the LIVE context that is tool output. When it dominates, the
# durable fix is gateway-side tool-output compression, not clearing the session.
TOOL_SQL = """
    SELECT CAST(COALESCE(SUM(CASE WHEN role='tool' THEN LENGTH(content) END), 0)
                * 100 / NULLIF(SUM(LENGTH(content)), 0) AS INT)
    FROM messages WHERE session_id=? AND active=1
"""
CONTEXT_LENGTH = re.compile(r"^\s*context_length:\s*(\d+)", re.M)


def context_window(data_dir, fallback):
    """(tokens, source): from config.yaml, so this cannot drift from what Hermes uses."""
    path = Path(data_dir) / "config.yaml"
    if not path.exists():
        return fallback, "fallback"
    try:
        found = CONTEXT_LENGTH.search(path.read_text())
    except OSError as e:
        return fallback, f"fallback, config unreadable: {e.strerror}"
    return (int(found[1]), "config") if found else (fallback, "fallback")


DEFAULT_WARN_PCT = 70
DEFAULT_CRIT_PCT = 90
DEFAULT_ACTIVE_HOURS = 168  # a week
DEFAULT_OVERHEAD_TOKENS = 25000  # measured system prompt + tool schemas on this deployment
DEFAULT_CONTEXT_TOKENS = 500000


class Limits(NamedTuple):
    """The plugin's positional arguments after data_dir, in order."""

    warn_pct: int = DEFAULT_WARN_PCT  # WARNING at or above this % of the context window
    crit_pct: int = DEFAULT_CRIT_PCT  # CRITICAL at or above this %
    active_hours: int = DEFAULT_ACTIVE_HOURS  # only open sessions with a message this recent count
    overhead: int = DEFAULT_OVERHEAD_TOKENS  # tokens added to the transcript estimate
    fallback: int = DEFAULT_CONTEXT_TOKENS  # window size when config.yaml sets no context_length


def check(data_dir, limits=None, now=None):
    """Judge the live context of the busiest recent open session.

    data_dir  Hermes home holding state.db and config.yaml
    limits    thresholds and estimates, see Limits (defaults when None)
    now       epoch seconds for the recency cutoff (defaults to the clock)

    Returns (exit_code, message): 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN, and
    one Nagios status line with perfdata.
    """
    now = time.time() if now is None else now
    warn_pct, crit_pct, active_hours, overhead, fallback = limits or Limits()
    db = Path(data_dir) / "state.db"
    if not db.is_file():
        return UNKNOWN, f"UNKNOWN - cannot read {db}"

    ctx_len, ctx_src = context_window(data_dir, fallback)

    try:
        with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as conn:
            row = conn.execute(SESSION_SQL, (int(now - active_hours * 3600),)).fetchone()
            tool_pct = conn.execute(TOOL_SQL, (row[0],)).fetchone()[0] if row else 0
    except sqlite3.Error as e:
        return UNKNOWN, f"UNKNOWN - cannot query {db}: {e}"

    if row is None:
        perf = f"ctx_pct=0%;{warn_pct};{crit_pct};0;100 est_tokens=0 active_msgs=0"
        return OK, f"OK - no open Hermes session active in the last {active_hours}h | {perf}"

    session, act_msgs, act_chars, all_rows, idle_days = row
    inactive = all_rows - act_msgs
    est = (act_chars or 0) // CHARS_PER_TOKEN + overhead
    pct = est * 100 // ctx_len
    tool_pct = tool_pct or 0
    perf = (
        f"ctx_pct={pct}%;{warn_pct};{crit_pct};0;100 est_tokens={est};;;0;{ctx_len} "
        f"active_msgs={act_msgs} tool_pct={tool_pct}% inactive={inactive} idle_days={idle_days}"
    )
    detail = (
        f"open session {session}: ~{est} tokens live ({pct}% of {ctx_len}, source={ctx_src}, "
        f"incl ~{overhead} prompt+tools), {act_msgs} active of {all_rows} rows, "
        f"{tool_pct}% tool output, idle {idle_days}d"
    )

    if pct >= crit_pct:
        return CRITICAL, (
            f"CRITICAL - Hermes live context saturated: {detail}. Compression is not keeping up, so turns will "
            "stall on the 10s turn-hold and answer uncompressed. Send /compress here 15 to shrink now, or /new "
            f"for a fresh session. High tool_pct means the durable fix is gateway tool-output compression. | {perf}"
        )
    if pct >= warn_pct:
        return WARNING, (
            f"WARNING - Hermes live context filling: {detail}. Occupancy should stay flat while compression "
            f"is working; a steady climb means it is falling behind. | {perf}"
        )
    return OK, f"OK - {detail} | {perf}"


def main(argv):
    args = argv[1:]
    data_dir = args[0] if args else "/app/.hermes"
    try:
        nums = [int(a) for a in args[1:6]]
    except ValueError:
        print("UNKNOWN - thresholds must be integers")
        return UNKNOWN
    code, message = check(data_dir, Limits(*nums))
    print(message)
    return code


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # a crashed probe must page, not read as WARNING (exit 1)
        print(f"CRITICAL - check_hermes_context.py crashed: {type(e).__name__}: {e}")
        sys.exit(CRITICAL)
