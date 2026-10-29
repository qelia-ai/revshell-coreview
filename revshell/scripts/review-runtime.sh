#!/usr/bin/env bash
# Shared runtime for revshell reviewer drivers. Source this file; do not execute it.

# Keep progress on stderr so each driver's stdout remains the reviewer response plus
# its parseable terminal VERDICT line.
REVSHELL_HEARTBEAT_SECONDS_DEFAULT=30
REVSHELL_TERM_GRACE_SECONDS_DEFAULT=2
# LIVENESS, not wall clock (2026-08-17). A reviewer is killed for going SILENT,
# never for merely taking a long time: a large diff legitimately runs 10-20 min,
# and a hard ceiling killed three real rounds over one 325 KB diff, landing it
# unreviewed. This requires a STREAMING backend (qwen: `--output-format
# stream-json`) so growth of the capture file is the sign of life. Set the
# absolute ceiling to 0 for "no ceiling — silence is the only stop condition".
REVSHELL_IDLE_TIMEOUT_SECONDS_DEFAULT=300
REVSHELL_IDLE_POLL_SECONDS_DEFAULT=10
REVSHELL_INVOCATION_COUNTER=0
REVSHELL_CURRENT_INVOCATION_ID=""

revshell_log() {
  printf '[revshell:%s] %s\n' "$1" "$2" >&2
}

revshell_is_nonnegative_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# A code review of an EMPTY diff is never a pass. 2026-10-29 (a product repo round 2): a --base that was a
# CHILD of HEAD resolved to HEAD itself as the fork point, the diff was empty, and four rounds still launched
# and returned verdicts on nothing. Called right after the code diff is computed, before any reviewer starts;
# exit 2 is these scripts' usage-error code. An unresolvable --base (git diff fails) lands here too.
revshell_require_code_diff() {
  local script="$1" base="$2" repo="$3" diff="$4"
  [ -n "$diff" ] && return 0
  echo "$script: nothing to review: 'git diff $base' in $repo is empty. The --base (or its fork point with HEAD) already contains every change; a review of nothing is never a pass. Pass a --base that is an ancestor of the reviewed commit." >&2
  exit 2
}

# Set REVSHELL_CURRENT_INVOCATION_ID instead of printing it so repeated calls in one
# shell can increment the counter without losing state through command substitution.
revshell_make_invocation_id() {
  local backend="$1"
  local phase="$2"
  local label="${REVSHELL_INVOCATION_LABEL:-${backend}-${phase}}"
  local timestamp

  REVSHELL_INVOCATION_COUNTER=$((REVSHELL_INVOCATION_COUNTER + 1))
  label="$(LC_ALL=C printf '%s' "$label" | tr -c '[:alnum:]_.-' '-')"
  [ -n "$label" ] || label="review"
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  REVSHELL_CURRENT_INVOCATION_ID="${label}-${timestamp}-$$-${REVSHELL_INVOCATION_COUNTER}"
}

revshell_process_group_alive() {
  local pid="$1"
  [ "$pid" -gt 1 ] 2>/dev/null || return 1
  kill -0 -- "-$pid" 2>/dev/null
}

revshell_kill_process_group() {
  local pid="$1"
  local signal_name="$2"
  [ "$pid" -gt 1 ] 2>/dev/null || return 0
  kill "-$signal_name" -- "-$pid" 2>/dev/null || true
}

revshell_restore_trap() {
  local saved_trap="$1"
  local signal_name="$2"
  if [ -n "$saved_trap" ]; then
    eval "$saved_trap"
  else
    trap - "$signal_name"
  fi
}

# Interruption handler body. TERM goes out twice, a beat apart: a child forked an instant
# before the signal can still hold the trap text it inherited and shrug off the first TERM
# (measured 2026-10-22, ~1 in 100 immediate interrupts under load: the reviewer then ran on
# until the ceiling). The post-wait sweep escalates to KILL for anything still alive.
revshell_interrupt_groups() {
  local pid
  for pid in "$@"; do revshell_kill_process_group "$pid" TERM; done
  sleep 0.3
  for pid in "$@"; do revshell_kill_process_group "$pid" TERM; done
}

# Run one reviewer command with an isolated output file and process group.
#
# The call blocks only its own caller. It creates no shared lock or shared filename,
# so other shells and agents can run review rounds concurrently. Start/heartbeat/end
# status goes to stderr; captured reviewer output is emitted unchanged on stdout after
# the command exits. Return 124 on timeout, or the reviewer's own status otherwise.
revshell_run_with_timeout() {
  local invocation_id="$1"
  local secs="$2"
  shift 2

  local heartbeat_seconds="${REVSHELL_HEARTBEAT_SECONDS:-$REVSHELL_HEARTBEAT_SECONDS_DEFAULT}"
  local term_grace_seconds="${REVSHELL_TERM_GRACE_SECONDS:-$REVSHELL_TERM_GRACE_SECONDS_DEFAULT}"
  local idle_timeout_seconds="${REVSHELL_IDLE_TIMEOUT_SECONDS:-$REVSHELL_IDLE_TIMEOUT_SECONDS_DEFAULT}"
  local idle_poll_seconds="${REVSHELL_IDLE_POLL_SECONDS:-$REVSHELL_IDLE_POLL_SECONDS_DEFAULT}"
  local out_capture timeout_marker
  local restore_monitor=0
  local cmd_pid=0 watchdog_pid=0 heartbeat_pid=0
  local rc=0 signal_rc=0
  local started_at finished_at elapsed
  local previous_int previous_term previous_hup

  # 0 is now MEANINGFUL: "no absolute ceiling — silence is the only stop condition".
  if ! revshell_is_nonnegative_integer "$secs"; then
    revshell_log "$invocation_id" "invalid timeout '${secs}'; expected 0 (no ceiling) or a positive integer"
    return 125
  fi
  if ! revshell_is_nonnegative_integer "$idle_timeout_seconds"; then
    revshell_log "$invocation_id" "invalid REVSHELL_IDLE_TIMEOUT_SECONDS '${idle_timeout_seconds}'; expected 0 or a positive integer"
    return 125
  fi
  if ! revshell_is_nonnegative_integer "$idle_poll_seconds" || [ "$idle_poll_seconds" -eq 0 ]; then
    revshell_log "$invocation_id" "invalid REVSHELL_IDLE_POLL_SECONDS '${idle_poll_seconds}'; expected a positive integer"
    return 125
  fi
  if [ "$secs" -eq 0 ] && [ "$idle_timeout_seconds" -eq 0 ]; then
    revshell_log "$invocation_id" "refusing to run unbounded: timeout=0 AND idle timeout=0 leaves no stop condition"
    return 125
  fi
  if ! revshell_is_nonnegative_integer "$heartbeat_seconds"; then
    revshell_log "$invocation_id" "invalid REVSHELL_HEARTBEAT_SECONDS '${heartbeat_seconds}'; expected 0 or a positive integer"
    return 125
  fi
  if ! revshell_is_nonnegative_integer "$term_grace_seconds"; then
    revshell_log "$invocation_id" "invalid REVSHELL_TERM_GRACE_SECONDS '${term_grace_seconds}'; expected 0 or a positive integer"
    return 125
  fi

  out_capture="$(mktemp -t revshell-review-out.XXXXXX)"
  timeout_marker="${out_capture}.timeout"
  started_at="$(date '+%s')"

  revshell_log "$invocation_id" "reviewer started (idle-timeout=${idle_timeout_seconds}s, ceiling=${secs}s$([ "$secs" -eq 0 ] && printf ' [none]'), heartbeat=${heartbeat_seconds}s); stopped only on SILENCE, not elapsed time; this caller waits while other invocations remain concurrent; output buffered safely"

  # Preserve any caller traps. On interruption, signal only this invocation's groups;
  # concurrent revshell processes have distinct IDs, temp files, and process groups.
  # Installed BEFORE anything is launched (2026-10-22): installed after the launch, a TERM in
  # between killed this shell with the default action, so nothing was logged and the reviewer
  # ran on unowned (6 of 40 immediate interrupts, measured). A PID still 0 is ignored by
  # revshell_kill_process_group.
  previous_int="$(trap -p INT || true)"
  previous_term="$(trap -p TERM || true)"
  previous_hup="$(trap -p HUP || true)"
  trap 'signal_rc=130; revshell_interrupt_groups "$cmd_pid" "$watchdog_pid" "$heartbeat_pid"' INT
  trap 'signal_rc=143; revshell_interrupt_groups "$cmd_pid" "$watchdog_pid" "$heartbeat_pid"' TERM
  trap 'signal_rc=129; revshell_interrupt_groups "$cmd_pid" "$watchdog_pid" "$heartbeat_pid"' HUP

  case "$-" in
    *m*) : ;;
    *) restore_monitor=1; set -m ;;
  esac

  # A private regular file prevents an escaped descendant from holding the caller's
  # stdout pipe open. Job control gives this command its own process group.
  # Nothing is launched once interrupted, and a signal caught between the fork and
  # `cmd_pid=$!` (when the trap still saw 0) is delivered to the new group here.
  if [ "$signal_rc" -eq 0 ]; then
    # The subshell drops the caller-visible interrupt traps installed above: a shell-function
    # reviewer would otherwise run the helper's trap text on TERM instead of dying (an exec'd
    # command resets traps itself).
    ( trap - INT TERM HUP; "$@" ) <&0 >"$out_capture" 2>&1 &
    cmd_pid=$!
    [ "$signal_rc" -eq 0 ] || revshell_kill_process_group "$cmd_pid" TERM
  fi

  # The watchdog owns no caller output descriptors. TERM allows graceful cleanup;
  # KILL bounds it even when a reviewer or tool child ignores TERM.
  #
  # It stops the reviewer for SILENCE, not for elapsed time: growth of
  # "$out_capture" is the sign of life, so a reviewer that is still streaming is
  # never interrupted no matter how long the diff takes. "$secs" survives only as
  # an absolute backstop against a pathological infinite-output loop, and 0
  # disables even that.
  (
    idle_elapsed=0
    last_size=-1
    while :; do
      sleep "$idle_poll_seconds"
      revshell_process_group_alive "$cmd_pid" || exit 0

      current_size="$(command wc -c < "$out_capture" 2>/dev/null | tr -d '[:space:]')"
      [ -n "$current_size" ] || current_size=0
      if [ "$current_size" != "$last_size" ]; then
        last_size="$current_size"
        idle_elapsed=0
      else
        idle_elapsed=$((idle_elapsed + idle_poll_seconds))
      fi

      if [ "$idle_timeout_seconds" -gt 0 ] && [ "$idle_elapsed" -ge "$idle_timeout_seconds" ]; then
        printf 'idle\n' > "$timeout_marker"
        break
      fi

      if [ "$secs" -gt 0 ]; then
        now_epoch="$(date '+%s')"
        if [ $((now_epoch - started_at)) -ge "$secs" ]; then
          printf 'ceiling\n' > "$timeout_marker"
          break
        fi
      fi
    done
    revshell_kill_process_group "$cmd_pid" TERM
    if [ "$term_grace_seconds" -gt 0 ]; then sleep "$term_grace_seconds"; fi
    revshell_kill_process_group "$cmd_pid" KILL
  ) </dev/null >/dev/null 2>&1 &
  watchdog_pid=$!

  if [ "$heartbeat_seconds" -gt 0 ]; then
    (
      while :; do
        sleep "$heartbeat_seconds" || exit 0
        revshell_process_group_alive "$cmd_pid" || exit 0
        finished_at="$(date '+%s')"
        elapsed=$((finished_at - started_at))
        # Report streamed bytes: a rising count is the sign of life the watchdog
        # is judging on, so a stall is visible in the log rather than inferred.
        streamed="$(command wc -c < "$out_capture" 2>/dev/null | tr -d '[:space:]')"
        [ -n "$streamed" ] || streamed=0
        revshell_log "$invocation_id" "reviewer still running (elapsed=${elapsed}s, streamed=${streamed}B; output buffered safely)"
      done
    ) </dev/null >/dev/null &
    heartbeat_pid=$!
  fi

  # POLL, then reap; never block in `wait` on a live reviewer (2026-10-22). bash 3.2 can hold a
  # trapped signal that lands as `wait` begins until the waited job ends on its own: one
  # launch-race interrupt in ~100 sat the full 20 s ceiling (rc 124, the watchdog's marker).
  # A signal during `sleep` runs its trap when the sleep ends, so an interrupt is acted on
  # within POLL; `wait` then only collects the status of a reviewer that has already exited.
  # Once interrupted, nothing is waited for: the sweep below sends TERM, then KILL, to the group.
  if [ "$cmd_pid" -gt 1 ]; then
    while [ "$signal_rc" -eq 0 ] && kill -0 "$cmd_pid" 2>/dev/null; do sleep 0.5; done
    [ "$signal_rc" -ne 0 ] || wait "$cmd_pid" 2>/dev/null || rc=$?
  fi
  [ "$signal_rc" -ne 0 ] && rc="$signal_rc"

  # KILL, not TERM: a helper forked just before a signal can still hold the trap text it
  # inherited and shrug off TERM (measured ~1 in 100), which blocked the wait below until the
  # ceiling and then wrote a bogus "ceiling" marker (rc 124). They own nothing to clean up.
  revshell_kill_process_group "$watchdog_pid" KILL
  revshell_kill_process_group "$heartbeat_pid" KILL
  wait "$watchdog_pid" 2>/dev/null || true
  if [ "$heartbeat_pid" -gt 1 ]; then wait "$heartbeat_pid" 2>/dev/null || true; fi

  # Sweep descendants the reviewer failed to reap. Escalate only if its process group
  # remains alive, so cleanup stays scoped to this invocation.
  if revshell_process_group_alive "$cmd_pid"; then
    revshell_kill_process_group "$cmd_pid" TERM
    if [ "$term_grace_seconds" -gt 0 ]; then sleep "$term_grace_seconds"; fi
    revshell_kill_process_group "$cmd_pid" KILL
  fi

  revshell_restore_trap "$previous_int" INT
  revshell_restore_trap "$previous_term" TERM
  revshell_restore_trap "$previous_hup" HUP
  [ "$restore_monitor" -eq 1 ] && set +m

  local stop_reason=""
  if [ -f "$timeout_marker" ]; then
    stop_reason="$(command cat "$timeout_marker" 2>/dev/null | tr -d '[:space:]')"
    rc=124
  fi
  finished_at="$(date '+%s')"
  elapsed=$((finished_at - started_at))
  case "$rc" in
    0)   revshell_log "$invocation_id" "reviewer finished (elapsed=${elapsed}s, exit=0); emitting captured output" ;;
    124)
      if [ "$stop_reason" = "ceiling" ]; then
        revshell_log "$invocation_id" "reviewer hit the ABSOLUTE CEILING while still streaming (elapsed=${elapsed}s, ceiling=${secs}s) — it was alive, so raise --timeout or set it to 0; emitting captured output"
      else
        revshell_log "$invocation_id" "reviewer went SILENT for ${idle_timeout_seconds}s (elapsed=${elapsed}s) — stopped as unresponsive, not for being slow; emitting captured output"
      fi
      ;;
    *)   revshell_log "$invocation_id" "reviewer failed (elapsed=${elapsed}s, exit=${rc}); emitting captured output" ;;
  esac

  command cat "$out_capture" 2>/dev/null || true
  rm -f "$out_capture" "$timeout_marker"
  return "$rc"
}
