#!/usr/bin/env bash
{ # The whole file is one group, so bash parses all of it before running any of it: a rewrite in place
  # cannot corrupt a running round (2026-10-21: a cp over this file killed a 75-minute review at line 517).
# await-log.sh — block IN THE CALLER'S OWN TURN until a detached revshell round finishes.
#
# WHY THIS EXISTS (measured 2026-08-16, 08-17, 08-19, 08-19/20):
#   Agents lost whole sessions of finished work by launching a review as a background
#   task / Monitor and then ENDING THEIR TURN to await a notification. For a subagent,
#   ending the turn is finishing: across 42 subagent transcripts on this machine, 11
#   started background tasks and NOT ONE was ever re-entered by a completion
#   notification. The rounds completed; nobody consumed the verdicts.
#
#   The obvious fix ("just run the reviewer in the foreground") is not available: the
#   Bash tool's timeout is 120s by default and 600s at most, and a round runs
#   250-3000s. When that timeout expires the harness does not fail the call, it MOVES
#   THE COMMAND TO THE BACKGROUND — so a naive foreground invocation becomes a
#   background one against the agent's intent.
#
#   So: the round runs detached, and this script is the blocking wait. It is a
#   CONDITION-GUARDED wait (not a bare `sleep`), it lives inside a script rather than
#   in the tool's command string, and it RETURNS TO THE CALLER before the tool ceiling
#   can background it. Re-issue it until it exits 0. Never end your turn instead.
#
# USAGE
#   bash await-log.sh <log-file> [max_seconds] [marker_regex]
#
#   max_seconds defaults to 510 — deliberately BELOW the Bash tool's 600s ceiling, so
#   this call always returns a result to you rather than being backgrounded. Give the
#   Bash call an explicit timeout of 600000 ms so the harness does not cut it at 120s.
#
# EXIT CODES
#   0  verdict marker found — the tail of the log is printed; consume it now.
#   10 not finished yet — RE-ISSUE THIS EXACT COMMAND IN THE SAME TURN. Not an error.
#   12 THE ROUND NEVER STARTED — the launcher exited on its own arguments (e.g.
#      `--plan is required`). Nothing is running; fix the command and relaunch.
#      Distinct from 11: no reviewer ran, so there are no edits to audit.
#   11 the round looks dead (log has not grown for a long time and no verdict) —
#      investigate; reviewer EDITS may already be in your working tree.
#   2  bad usage / log file never appeared.
#
set -uo pipefail

# Deliberately BELOW the Bash tool's 600s ceiling, so this call always returns a
# result to the caller rather than being backgrounded past it.
DEFAULT_MAX_SECONDS=510

LOG=${1:-}
MAX=${2:-$DEFAULT_MAX_SECONDS}
# Match ONLY lines the round wrapper itself emits: the final `VERDICT: ...` line
# and the `==== qwen-review verdict` banner. The round log can also contain the
# review prompt (which quotes the verdict boilerplate) and stream-json dumps of
# it, so any unanchored match on the verdict phrases could report a "verdict"
# that is only quoted text, not this round's outcome. Recall is still guaranteed:
# on success the wrapper's last act is echoing the parsed VERDICT line itself.
MARKER=${3:-'^VERDICT:|==== .*verdict'}

if [ -z "$LOG" ]; then
  echo "await-log.sh: usage: await-log.sh <log-file> [max_seconds] [marker_regex]" >&2
  exit 2
fi

POLL=${REVSHELL_AWAIT_POLL_SECONDS:-10}
# How long the log may stay byte-identical before we call the round dead. Generous:
# a reviewer thinking hard on a large diff can be quiet for minutes.
STALL=${REVSHELL_AWAIT_STALL_SECONDS:-420}

# These feed $(( )) and [ -lt ] tests: anything non-numeric — or with a leading
# zero, which $(( )) reads as octal — is a usage error, not a value to interpret.
for _v in MAX POLL STALL; do
  case ${!_v} in
    ''|0[0-9]*|*[!0-9]*)
      echo "await-log.sh: ${_v} must be a plain non-negative integer, got: '${!_v}'" >&2
      exit 2
      ;;
  esac
done

# An invalid marker regex makes grep exit 2 on every poll, which would masquerade
# as a round that never finishes. Reject it up front instead.
printf '' | grep -qiE "$MARKER" >/dev/null 2>&1
_marker_probe=$?
if [ "$_marker_probe" -gt 1 ]; then
  echo "await-log.sh: invalid marker_regex: $MARKER" >&2
  exit 2
fi

started=$(date +%s)
last_size=-1
last_growth=$started
ever_seen=0

while :; do
  now=$(date +%s)
  elapsed=$(( now - started ))

  if [ -f "$LOG" ]; then
    ever_seen=1
    if grep -qiE "$MARKER" "$LOG" 2>/dev/null; then
      echo "await-log.sh: VERDICT PRESENT after ${elapsed}s of waiting — log=$LOG"
      echo "---------------- tail of the round ----------------"
      tail -n 120 "$LOG"
      echo "---------------------------------------------------"
      echo "await-log.sh: consume this verdict NOW; audit 'git status'/'git diff' for reviewer edits."
      exit 0
    fi
    # FAST-FAIL ON A LAUNCH THAT NEVER STARTED (added 2026-08-20, after a round
    # blocked ~7min on a 36-byte log whose entire contents were
    # "codex-review.sh: --plan is required"). The stall detector below would
    # eventually catch it, but only after STALL seconds -- it cannot tell a
    # reviewer thinking hard from a launcher that exited on argument parsing.
    # A launch failure is recognisable in one poll: the log is tiny AND says so.
    if [ "$elapsed" -ge 20 ]; then
      _size_now=$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]'); _size_now=${_size_now:-0}
      if [ "$_size_now" -lt 4096 ] && grep -qiE 'is required|usage:|unknown option|no such file|command not found|invalid (option|argument)' "$LOG" 2>/dev/null; then
        echo "await-log.sh: THE ROUND NEVER STARTED -- the launcher failed on its own arguments." >&2
        echo "await-log.sh: log=$LOG (${_size_now} bytes after ${elapsed}s, no reviewer process behind it)" >&2
        echo "await-log.sh: Fix the launch command and start the round again. Do NOT keep waiting;" >&2
        echo "await-log.sh: nothing is running, so no verdict and no reviewer edits are coming." >&2
        echo "---------------- what the log actually says ----------------" >&2
        cat "$LOG" >&2 2>/dev/null || true
        exit 12
      fi
    fi
    size=$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]')
    size=${size:-0}
    if [ "$size" != "$last_size" ]; then
      last_size=$size
      last_growth=$now
    fi
  else
    size=0
  fi

  quiet=$(( now - last_growth ))
  if [ "$quiet" -ge "$STALL" ]; then
    if [ "$ever_seen" -eq 0 ]; then
      echo "await-log.sh: log file NEVER APPEARED (${elapsed}s waited): log=$LOG" >&2
      echo "await-log.sh: The round did not start, or it is writing somewhere else." >&2
      echo "await-log.sh: Check the launch command and the log path, then start the round again." >&2
      exit 2
    fi
    echo "await-log.sh: NO GROWTH for ${quiet}s and no verdict — the round looks dead." >&2
    echo "await-log.sh: log=$LOG (${last_size} bytes, ${elapsed}s waited)" >&2
    echo "await-log.sh: A DEAD ROUND DOES NOT MEAN NOTHING HAPPENED — this backend edits by" >&2
    echo "await-log.sh: default. Audit 'git status' / 'git diff' / 'git log' before assuming" >&2
    echo "await-log.sh: a clean slate, then either re-run the round or COMMIT ANYWAY and say" >&2
    echo "await-log.sh: plainly in your report that the branch landed unreviewed." >&2
    echo "---------------- tail of the round ----------------" >&2
    tail -n 60 "$LOG" >&2 2>/dev/null || true
    exit 11
  fi

  if [ "$elapsed" -ge "$MAX" ]; then
    echo "await-log.sh: STILL RUNNING after ${elapsed}s (log=$LOG, ${last_size} bytes, last grew ${quiet}s ago)."
    echo "await-log.sh: THIS IS NOT A FAILURE AND NOT A REASON TO END YOUR TURN."
    echo "await-log.sh: RE-ISSUE THIS EXACT COMMAND NOW, in this same turn:"
    echo "await-log.sh:     bash $0 $LOG"
    echo "await-log.sh: Do NOT hand this off to Monitor or run_in_background and wait to be"
    echo "await-log.sh: notified — a completion notification will not wake you, and everything"
    echo "await-log.sh: you have built stays uncommitted."
    echo "---------------- tail so far ----------------"
    tail -n 25 "$LOG" 2>/dev/null || true
    exit 10
  fi

  # Never sleep past MAX: this call must RETURN to the caller, not be backgrounded
  # by the harness for overrunning the tool ceiling.
  remaining=$(( MAX - elapsed ))
  nap=$POLL
  [ "$remaining" -lt "$nap" ] && nap=$remaining
  [ "$nap" -lt 1 ] && nap=1
  sleep "$nap"
done
exit
}
