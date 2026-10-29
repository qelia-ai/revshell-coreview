#!/usr/bin/env bash
{ # The whole file is one group, so bash parses all of it before running any of it: a rewrite in place
  # cannot corrupt a running round (2026-10-21: a cp over this file killed a 75-minute review at line 517).
# qwen-review.sh — drive Qwen Code as the in-shell REVIEWER for `revshell` mode.
#
# Parallel to codex-review.sh but uses the regular in-shell `qwen` CLI.
# Inherits the SAME review contract as Backend A (Codex): same prompt structure,
# same verdict sentinels, same reviewer-edit tagging protocol.
#
# Usage:
#   qwen-review.sh --plan <plan-path> --phase <plan|code> --repo <worktree-dir> \
#                  [--base <ref>] [--model <m>] [--context <file>] [--timeout <secs>]
#
#   --plan      the ONE canonical plan file
#   --phase     plan → review the PLAN only; code → review the implemented DIFF
#   --repo      working root (qwen runs from this directory)
#   --base      git ref the diff is measured from (code phase only; default: HEAD~1)
#   --model     optional model override; defaults to QWEN_REVIEW_MODEL if set,
#               otherwise inherits whatever the local `qwen` CLI is already using
#   --context   optional file appended as extra steering for this round
#   --timeout   ABSOLUTE ceiling in seconds; 0 = none (DEFAULT). This backend
#               streams, so silence — not elapsed time — is the stop condition:
#               review-runtime.sh kills it after REVSHELL_IDLE_TIMEOUT_SECONDS
#               (300s) with no new output. Set a ceiling only when you want the
#               round bounded regardless of liveness.
#   --approval-mode  plan|default|auto-edit|auto|yolo (default: auto-edit, so the
#               reviewer can actually apply the fixes the contract mandates)
#   --canonical-recall
#               OPT-IN, DEFAULT OFF (mirrors codex-review.sh's flag). Probed
#               2026-08-29: `--safe-mode` disables MCP servers outright ("SAFE MODE —
#               all customizations disabled (hooks, extensions, skills, MCP servers,
#               QWEN.md)"), so a round run with it has NO `acme-agent-index`
#               recall even though the prompt's recall contract demands it. With this
#               flag the round runs WITHOUT `--safe-mode`; everything else (stream-json,
#               approval mode, model, proxy pin) is unchanged. Two preconditions,
#               both verified 2026-08-29: the server entry in ~/.qwen/settings.json
#               carries `"trust": true` (`qwen mcp add --trust …`) — without it a
#               headless round DECLINES every MCP call ("requires user approval but
#               cannot execute in non-interactive mode") — and the round's cwd is a
#               worktree of the indexed repo (the launcher is inert elsewhere).
#               The round's first stderr line states which mode ran.
#
# EGRESS WARNING: unless the user's own `qwen` configuration is known to stay local,
# assume the configured backend is hosted and that the code phase sends the COMPLETE
# diff off-machine. confidentiality-guard.sh gates this and hard-blocks confidential
# repos; see that file for the roots/remotes it refuses.
#
# Headless stability note (2026-08-14): use --safe-mode. On this machine, plain headless
# qwen runs can sit idle while loading user customizations; safe mode keeps the direct
# shell `qwen` path but disables hooks/extensions/MCP/skills/QWEN.md for a bounded review.
# --safe-mode is NOT what removes the reviewer's shell tool — see the next paragraph for
# what actually does. A 2026-08-16 edit dropped the flag on that mistaken diagnosis and
# has since been reverted; both invocations below carry it again.
#
# NEVER tell a headless qwen reviewer to run a shell command itself (2026-08-16).
# Headless qwen only registers `run_shell_command` under `--approval-mode yolo`; under
# default/auto/auto-edit the tool is dropped from the registry entirely, because a
# confirmation-requiring tool cannot be confirmed with no user attached. Verified:
#   yolo -> 29 tools (has run_shell_command) | auto-edit -> 27 | auto/default -> 24 (none)
# Qwen does not stop at that dead end. Given a prompt ordering it to run
# `git diff --cached`, it tool_searched for a shell 24 times, spawned 5 nested subagents
# that each failed the same way, then reached for its built-in `computer_use__*`
# desktop-automation tools and drove Terminal.app through synthetic ⌘N / type_text /
# press_key to run the command via the GUI — outside the sandbox, outside the approval
# flow, outside this script's audit log. Those tools were auto-accepted while the shell
# was withheld, which is the asymmetry to remember: qwen strips the shell for being
# unconfirmable but leaves strictly more powerful desktop automation on and auto-approved.
# THIS SCRIPT IS SAFE by construction: it embeds the complete unified diff in the prompt
# (see "=== UNIFIED DIFF" below), so the reviewer never needs a shell. Keep it that way —
# do not add "run git yourself" language, and do not switch to --approval-mode yolo.
# Ad hoc `qwen -p "...run git diff --cached yourself..."` calls that bypass this script are
# what triggered the escape; route qwen reviews through here.
# Backstop: tools.computerUse.enabled=false in ~/.qwen/settings.json (set 2026-08-16).
#
# Prints Qwen's full response to stdout, then a final line:  VERDICT: <verdict>
# Exit status: 0 on a clean run; 2 usage; 3 refused before starting (a metered
# tier is active, its status is unreadable, or qwen is missing); 4 timeout or no
# proxy; 5 qwen failed; 6 no parseable result; 7 stopped mid-round by the
# metered kill switch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=review-runtime.sh
. "$SCRIPT_DIR/review-runtime.sh"
# shellcheck source=confidentiality-guard.sh
. "$SCRIPT_DIR/confidentiality-guard.sh"

# ---- constants ---------------------------------------------------------------
# Default to the user's normal shell `qwen` configuration. Only pass --model when
# the caller explicitly overrides it via QWEN_REVIEW_MODEL / --model.
QWEN_MODEL_DEFAULT="${QWEN_REVIEW_MODEL:-}"
# NO ABSOLUTE CEILING BY DEFAULT (2026-08-19). Qwen runs with
# `--output-format stream-json`, so growth of the capture file is a true sign
# of life and `review-runtime.sh` can stop this backend on SILENCE alone (its
# 300s idle timeout) — which is the whole point of the 2026-08-17 liveness
# work. Shipping a wall-clock ceiling anyway re-created exactly the failure
# that work removed: measured 2026-08-19, a round on an 79 KB diff was killed
# at `elapsed=1504s, ceiling=1500s` **while still streaming** — the runtime
# even logged "it was alive, so raise --timeout or set it to 0" — and the
# review was lost after 25 minutes of real work, with the reviewer's edits
# left behind unverdicted. A reviewer that has gone quiet for 5 minutes is
# dead; one still emitting tokens at minute 25 is just thorough.
# Pass --timeout <secs> for a deliberate ceiling; 0 means none.
QWEN_TIMEOUT_DEFAULT="${QWEN_REVIEW_TIMEOUT:-0}"

# With no ceiling, SILENCE is the only stop condition — so it has to be long
# enough to outlast this backend's silent phase. Qwen reads the whole diff and
# thinks before it emits its first real token, and that phase scales with diff
# size: measured 2026-08-19 on a 79 KB diff, the capture file sat at 1,478 B
# from t=30s to t=270s and only grew at t=300s — a hair inside the runtime's
# 300s default, i.e. one slightly larger diff away from killing a perfectly
# healthy round for "silence" it was always going to break. 600s keeps "dead
# means dead" meaningful (ten minutes of nothing) without racing the startup.
# The caller's own REVSHELL_IDLE_TIMEOUT_SECONDS always wins.
# Measured 2026-10-06 (a product repo): a ~230 KB whole-file audit that reads further
# files with its tools sat at 1,824 B for 600s while serving 43 model requests,
# and was killed as silent. Rounds of that size set REVSHELL_IDLE_TIMEOUT_SECONDS=2400.
: "${REVSHELL_IDLE_TIMEOUT_SECONDS:=600}"
export REVSHELL_IDLE_TIMEOUT_SECONDS
QWEN_BASE_DEFAULT="HEAD~1"
QWEN_INLINE_PROMPT_MAX_BYTES="${QWEN_INLINE_PROMPT_MAX_BYTES:-100000}"

# The review contract MANDATES that the reviewer fix what it finds, so it needs write
# access. `auto-edit` auto-approves file edits without auto-approving arbitrary shell
# — the right blast radius for a reviewer. Passed as a CLI flag rather than set in
# settings.json for the same reason as the model pin: settings.json is CLI-managed and
# hand edits there do not survive (a `permissions.allow` block was silently dropped).
QWEN_APPROVAL_MODE_DEFAULT="${QWEN_REVIEW_APPROVAL_MODE:-auto-edit}"

# ---- local failover proxy (THE DEFAULT ROUTE, required unless opted out) -----
# A user may front the Qwen endpoints with a LOCAL proxy that cascades across
# their subscriptions and, as a last resort, a metered pay-per-token endpoint.
# When such a proxy is listening, review rounds go through it, because a round
# must not die just because ONE subscription's window is spent. Measured
# 2026-08-19: a review was refused outright with `insufficient_quota` from the
# first subscription while a second, healthy subscription sat one hop away
# behind the proxy — the round was lost for no reason but the endpoint it
# happened to name.
#
# Owner ruling 2026-08-19 ("use the proxy, it auto-routes to the correct
# registration"; "update revshell skill and code to always use the proxy"): the
# proxy is now the DEFAULT ROUTE, not an opportunistic optimisation. If it is not
# listening, this driver STOPS rather than quietly talking to one fixed upstream —
# a silent single-upstream round is exactly how a spent subscription killed a
# review that a healthy one, one hop away, would have served. Set
# QWEN_FAILOVER_REQUIRED=0 to restore the old best-effort behaviour.
QWEN_FAILOVER_STATUS_URL="${QWEN_FAILOVER_STATUS_URL:-http://127.0.0.1:8787/__failover/status}"
# Only the model id whose configured provider baseUrl points AT the proxy
# routes through the cascade; every other id talks to one fixed upstream and
# dies with it. Override if your provider list names it differently.
QWEN_FAILOVER_MODEL="${QWEN_FAILOVER_MODEL:-qwen3.8-max}"
# Upstream names whose invoicing is PER TOKEN rather than a flat plan. This
# skill's TOP RULE is that internal review work rides subscriptions, and a
# review never runs on one of these: the pre-flight below refuses to START a
# round while one is active (2026-08-27), and the kill switch below STOPS a
# round the moment one is used mid-round (the owner, 2026-09-16: "Qwen, with a
# kill switch"; 2026-09-15: "you never use API for Code review just for live
# production and only when subscriptions are exhausted"). The only way past
# either is the deliberate QWEN_ALLOW_METERED=1.
QWEN_FAILOVER_METERED_TIERS="${QWEN_FAILOVER_METERED_TIERS:-on-demand}"
# 1 = the proxy is mandatory (default). 0 = best-effort, inherit the caller's own
# qwen configuration when the proxy is absent.
QWEN_FAILOVER_REQUIRED="${QWEN_FAILOVER_REQUIRED:-1}"

QWEN_FAILOVER_SEEN=0        # 1 once a probe has answered
QWEN_FAILOVER_REQ_BEFORE="" # requests the cascade had served before this round

# ---- mid-round METERED KILL SWITCH (the owner, 2026-09-16: "Qwen, with a kill switch")
# The pre-flight refusal only sees the tier active when the round STARTS. The
# proxy falls through to a metered tier on its own when the subscription tiers
# run dry, and nothing in it stops that mid-round: measured 2026-09-16, the
# proxy had already served 129 metered requests over five days, and sessions
# were hand-rolling their own watchers (one killed its own round on a zsh
# word-splitting bug; the shared one started rounds it could not guard). The
# guard therefore lives HERE, in the one driver every Qwen round goes through.
# While a round runs it polls the proxy; if the active upstream becomes metered,
# if the metered tiers' request count rises above what it was when the round
# started (proxy-wide: another round billing stops this one too, the safe
# direction), or if the status is unreadable for UNREADABLE_LIMIT polls in a
# row, it stops the round with the runtime's own process-group kill and the
# driver exits 7. Bypassed only by QWEN_ALLOW_METERED=1.
QWEN_METERED_KILL_POLL_SECONDS="${QWEN_METERED_KILL_POLL_SECONDS:-3}"
QWEN_METERED_KILL_UNREADABLE_LIMIT="${QWEN_METERED_KILL_UNREADABLE_LIMIT:-3}"
QWEN_METERED_BEFORE=""      # metered-tier requests served before this round
QWEN_METERED_WATCH_PID=0
QWEN_METERED_KILL_MARKER=""

# Echo "<activeUpstream> <requests served by the metered tiers>" for a status
# payload, or "unreadable -1" when it cannot be read. A readable status with no
# metered tier listed has nothing that can bill, so it reads as 0, not -1.
qwen_failover_metered_summary() {
  [ -n "$1" ] || { echo "unreadable -1"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "unreadable -1"; return 0; }
  printf '%s' "$1" | QWEN_METERED_TIERS="$QWEN_FAILOVER_METERED_TIERS" python3 -c 'import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unreadable -1"); raise SystemExit(0)
if not isinstance(d, dict):
    print("unreadable -1"); raise SystemExit(0)
metered = set((os.environ.get("QWEN_METERED_TIERS") or "").split())
total = 0
for t in d.get("tiers") or []:
    if isinstance(t, dict) and t.get("name") in metered:
        try:
            total += int(t.get("requests") or 0)
        except Exception:
            print("unreadable -1"); raise SystemExit(0)
print(str(d.get("activeUpstream") or "unknown").split()[0] if str(d.get("activeUpstream") or "").strip() else "unknown", total)' 2>/dev/null || echo "unreadable -1"
}

# Stop this driver's reviewer: the round is the child whose command line carries
# qwen's stream-json flag, and the runtime gave it its own process group.
qwen_metered_kill_round() {
  local root="$1" pids pid
  pids="$(pgrep -P "$root" -f 'output-format stream-json' 2>/dev/null || true)"
  for pid in $pids; do revshell_kill_process_group "$pid" TERM; done
  sleep "${REVSHELL_TERM_GRACE_SECONDS:-${REVSHELL_TERM_GRACE_SECONDS_DEFAULT:-2}}"
  for pid in $pids; do revshell_kill_process_group "$pid" KILL; done
}

qwen_metered_watch() {
  local root="$1" before="$2" marker="$3" unread=0 active now
  while :; do
    sleep "$QWEN_METERED_KILL_POLL_SECONDS"
    read -r active now <<EOF
$(qwen_failover_metered_summary "$(qwen_failover_status || true)")
EOF
    if [ "$now" = "-1" ]; then
      unread=$((unread + 1))
      [ "$unread" -ge "$QWEN_METERED_KILL_UNREADABLE_LIMIT" ] || continue
      printf 'the proxy status was unreadable for %s polls in a row, so the metered tier could not be confirmed unused\n' "$unread" > "$marker"
      break
    fi
    unread=0
    case " $QWEN_FAILOVER_METERED_TIERS " in
      *" $active "*)
        printf "the active upstream became '%s', which bills per token\n" "$active" > "$marker"
        break ;;
    esac
    if [ "$now" -gt "$before" ]; then
      printf 'metered-tier requests rose from %s to %s during the round\n' "$before" "$now" > "$marker"
      break
    fi
  done
  qwen_metered_kill_round "$root"
}

# Print the proxy's status JSON, or nothing when it is not listening.
qwen_failover_status() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS -m 5 "$QWEN_FAILOVER_STATUS_URL" 2>/dev/null
}

# Echo "<activeUpstream> <total-requests-served>" for a status payload. Uses
# python3 when available and degrades to "unknown unknown" rather than guessing.
qwen_failover_summary() {
  [ -n "$1" ] || { echo "unknown unknown"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "unknown unknown"; return 0; }
  printf '%s' "$1" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown unknown"); raise SystemExit(0)
tiers = d.get("tiers") or []
total = 0
for t in tiers:
    try:
        total += int(t.get("requests") or 0)
    except Exception:
        pass
print((d.get("activeUpstream") or "unknown"), total)' 2>/dev/null || echo "unknown unknown"
}

# Warn when the model id the CLI will resolve does NOT point at the proxy.
# Silent on success: this speaks only when something is wrong, so it never adds
# noise to a healthy round. Best-effort by construction — an unreadable or
# differently-shaped settings file simply says nothing rather than blocking a
# review over a config it does not recognise.
QWEN_SETTINGS_FILE="${QWEN_SETTINGS_FILE:-$HOME/.qwen/settings.json}"
qwen_failover_assert_route() {
  local model="$1"
  [ -f "$QWEN_SETTINGS_FILE" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$QWEN_SETTINGS_FILE" "$model" "$QWEN_FAILOVER_STATUS_URL" <<'PY' 2>/dev/null || true
import json, sys
from urllib.parse import urlparse

settings_path, model, status_url = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(settings_path) as fh:
        settings = json.load(fh)
except Exception:
    raise SystemExit(0)

providers = []
for group in (settings.get("modelProviders") or {}).values():
    if isinstance(group, list):
        providers.extend(p for p in group if isinstance(p, dict))

matches = [p for p in providers if str(p.get("id") or "") == model]
if not matches:
    print(f"qwen-review.sh: !! model '{model}' is in no provider entry of "
          f"{settings_path}; the CLI will fall back to its own default and this "
          f"round may not use the cascade at all.")
    raise SystemExit(0)

proxy_host = urlparse(status_url).netloc
resolved = urlparse(str(matches[0].get("baseUrl") or "")).netloc
if resolved != proxy_host:
    print(f"qwen-review.sh: !! model '{model}' resolves to '{resolved}', NOT the "
          f"failover proxy at '{proxy_host}'. The CLI takes the FIRST provider "
          f"entry with a matching id, so this round would talk to one fixed "
          f"upstream with no failover — and if that upstream is the pay-per-token "
          f"one, it bills per token. Reorder the provider list, give the entries "
          f"distinct ids, or set QWEN_FAILOVER_MODEL to the id that does point at "
          f"the proxy.")
elif len(matches) > 1:
    others = ", ".join(sorted({urlparse(str(p.get("baseUrl") or "")).netloc
                               for p in matches[1:]}))
    print(f"qwen-review.sh: note — model '{model}' is declared {len(matches)} times "
          f"(also: {others}). The first entry wins and it IS the proxy, so this "
          f"round is routed correctly; be aware that reordering that list would "
          f"silently change where reviews are billed.")
PY
}

VERDICT_PLAN_GO="ready for implementation"
VERDICT_SHIP="ready to ship"
VERDICT_CHANGES="changes requested"

# ---- arg parse ---------------------------------------------------------------
PLAN="" ; PHASE="" ; REPO="" ; BASE="$QWEN_BASE_DEFAULT"
MODEL="$QWEN_MODEL_DEFAULT" ; CONTEXT_FILE="" ; TIMEOUT="$QWEN_TIMEOUT_DEFAULT"
APPROVAL_MODE="$QWEN_APPROVAL_MODE_DEFAULT"
CANONICAL_RECALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --plan)    PLAN="$2";    shift 2 ;;
    --phase)   PHASE="$2";   shift 2 ;;
    --repo)    REPO="$2";    shift 2 ;;
    --base)    BASE="$2";    shift 2 ;;
    --model)   MODEL="$2";   shift 2 ;;
    --context) CONTEXT_FILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --approval-mode) APPROVAL_MODE="$2"; shift 2 ;;
    --canonical-recall) CANONICAL_RECALL=1; shift ;;
    *) echo "qwen-review.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$PLAN" ]  || { echo "qwen-review.sh: --plan is required" >&2; exit 2; }
[ -n "$PHASE" ] || { echo "qwen-review.sh: --phase is required (plan|code)" >&2; exit 2; }
[ -f "$PLAN" ]  || { echo "qwen-review.sh: plan file not found: $PLAN" >&2; exit 2; }
# A --context that names no readable file is refused, never dropped (2026-10-25, a product repo: a review launched
# with the context TEXT as the argument ran without its round context, and nothing said so).
[ -z "$CONTEXT_FILE" ] || [ -f "$CONTEXT_FILE" ] || { echo "qwen-review.sh: context file not found: ${CONTEXT_FILE:0:120}" >&2; exit 2; }
if [ -z "$REPO" ]; then REPO="$(cd "$(dirname "$PLAN")" && pwd)"; fi
[ -d "$REPO" ]  || { echo "qwen-review.sh: repo dir not found: $REPO" >&2; exit 2; }
command -v qwen >/dev/null 2>&1 || { echo "qwen-review.sh: qwen CLI not on PATH" >&2; exit 3; }

# ---- capture the change under review BEFORE anything below writes into $REPO ----
# The failover pin further down rewrites $REPO/.qwen/settings.json for the round. In a repo that TRACKS
# that file (a product repo does), capturing the diff after the pin showed the reviewer a bogus deletion of the
# project's MCP config every round, and reviewers spent the round "restoring" it (measured 2026-09-23).
PRE_PIN_CODE_DIFF=""
if [ "$PHASE" = "code" ]; then
# A --base that is not an ancestor of HEAD (a branch name like `dev` whose tip moved after this branch
# forked) is resolved to the fork point, so the diff is what THIS branch changed. Diffing against the moved
# tip shows every commit landed on that branch since as a deletion here, and a reviewer "restores" them
# (measured 2026-10-08: `--base dev` made other sessions' new ship-ledger rows look deleted). An ancestor
# (HEAD~1, a sha on this branch) resolves to itself, unchanged.
BASE_FORK_POINT="$(git -C "$REPO" merge-base HEAD "$BASE" 2>/dev/null || true)"
if [ -n "$BASE_FORK_POINT" ] && [ "$(git -C "$REPO" rev-parse "$BASE^{commit}" 2>/dev/null)" != "$BASE_FORK_POINT" ]; then
  echo "[revshell] --base $BASE is not an ancestor of HEAD; diffing from its fork point $BASE_FORK_POINT" >&2
  BASE="$BASE_FORK_POINT"
fi
  PRE_PIN_CODE_DIFF="$(git -C "$REPO" diff "$BASE" 2>/dev/null)"
  revshell_require_code_diff qwen-review.sh "$BASE" "$REPO" "$PRE_PIN_CODE_DIFF"
fi

# ---- workspace-scoped, proxy-only provider entry (see the call site below) ----
QWEN_WS_SETTINGS_DIR=""
QWEN_WS_SETTINGS_BACKUP=""
qwen_failover_pin_workspace_route() {
  local model="$1" proxy_base
  proxy_base="${QWEN_FAILOVER_STATUS_URL%/__failover/status}/compatible-mode/v1"
  QWEN_WS_SETTINGS_DIR="$REPO/.qwen"
  mkdir -p "$QWEN_WS_SETTINGS_DIR"
  if [ -f "$QWEN_WS_SETTINGS_DIR/settings.json" ]; then
    QWEN_WS_SETTINGS_BACKUP="$(mktemp -t revshell-qwen-ws-settings.XXXXXX)"
    cp "$QWEN_WS_SETTINGS_DIR/settings.json" "$QWEN_WS_SETTINGS_BACKUP"
  fi
  cat > "$QWEN_WS_SETTINGS_DIR/settings.json" <<EOF
{
  "modelProviders": {
    "openai": [
      {
        "id": "$model",
        "name": "[revshell] failover proxy — the proxy selects the plan with quota",
        "baseUrl": "$proxy_base",
        "envKey": "REVSHELL_PROXY_TOKEN"
      }
    ]
  }
}
EOF
  export REVSHELL_PROXY_TOKEN="revshell-via-proxy"
  echo "qwen-review.sh: workspace provider entry pinned to the proxy ($proxy_base) for this round;" >&2
  echo "qwen-review.sh: the user's own provider list is not consulted (no direct plan link)." >&2
}
qwen_failover_unpin_workspace_route() {
  [ -n "$QWEN_WS_SETTINGS_DIR" ] || return 0
  if [ -n "$QWEN_WS_SETTINGS_BACKUP" ] && [ -f "$QWEN_WS_SETTINGS_BACKUP" ]; then
    cp "$QWEN_WS_SETTINGS_BACKUP" "$QWEN_WS_SETTINGS_DIR/settings.json"; rm -f "$QWEN_WS_SETTINGS_BACKUP"
  else
    rm -f "$QWEN_WS_SETTINGS_DIR/settings.json"; rmdir "$QWEN_WS_SETTINGS_DIR" 2>/dev/null || true
  fi
}

# ---- route through the local failover cascade when one is listening ----------
# Runs after arg parse so an explicit --model / QWEN_REVIEW_MODEL always wins:
# the caller pinning a model is a deliberate choice and is never overridden.
QWEN_FAILOVER_STATUS_JSON="$(qwen_failover_status || true)"
if [ -n "$QWEN_FAILOVER_STATUS_JSON" ]; then
  QWEN_FAILOVER_SEEN=1
  read -r _fo_active _fo_before <<EOF
$(qwen_failover_summary "$QWEN_FAILOVER_STATUS_JSON")
EOF
  QWEN_FAILOVER_REQ_BEFORE="$_fo_before"
  read -r _fo_metered_active QWEN_METERED_BEFORE <<EOF
$(qwen_failover_metered_summary "$QWEN_FAILOVER_STATUS_JSON")
EOF
  if [ "$QWEN_METERED_BEFORE" = "-1" ] && [ "${QWEN_ALLOW_METERED:-0}" != "1" ]; then
    echo "qwen-review.sh: REFUSING TO RUN — the failover proxy answered, but its metered-tier" >&2
    echo "qwen-review.sh: request count cannot be read, so this round could not be stopped if it" >&2
    echo "qwen-review.sh: fell through to a pay-per-token tier. Fix the proxy status, or override" >&2
    echo "qwen-review.sh: deliberately: QWEN_ALLOW_METERED=1 $0 ..." >&2
    exit 3
  fi
  if [ -z "$MODEL" ]; then
    MODEL="$QWEN_FAILOVER_MODEL"
    echo "qwen-review.sh: local failover proxy detected at $QWEN_FAILOVER_STATUS_URL;" >&2
    echo "qwen-review.sh: routing this round through it as model '$MODEL' (active upstream: ${_fo_active:-unknown})." >&2
    # PRE-FLIGHT METERED REFUSAL (2026-08-27). The identical classification
    # already existed, but only in the POST-round audit — it printed "This
    # round cost real money" after the money was gone. Measured that day: the
    # plan was exhausted, the proxy answered 200 on /models (healthy while
    # cascading), a caller's liveness pre-check passed, and a doctrine round
    # burned ~69s of metered thinking before it was killed by hand. A warning
    # a tool prints and then ignores is not a guard.
    #
    # the owner's standing hard rule: API-METERED model access is banned for
    # internal work; subscription-billed shells are the tool. A cascade to
    # 'on-demand' silently crosses that line, so refuse BEFORE spending, and
    # make the override explicit and deliberate.
    case " $QWEN_FAILOVER_METERED_TIERS " in
      *" ${_fo_active:-none} "*)
        if [ "${QWEN_ALLOW_METERED:-0}" != "1" ]; then
          echo "qwen-review.sh: REFUSING TO RUN — active upstream '${_fo_active}' is METERED (bills per token)." >&2
          echo "qwen-review.sh: the subscription tiers ahead of it are exhausted or blocked." >&2
          echo "qwen-review.sh: internal work on a pay-per-token tier is banned (AGENTS.md / ~/.claude/CLAUDE.md," >&2
          echo "qwen-review.sh: 'Model access — drive agents, never call an API yourself')." >&2
          echo "qwen-review.sh: wait for the plan reset, or use a subscription backend (codex / agy)." >&2
          echo "qwen-review.sh: to override deliberately: QWEN_ALLOW_METERED=1 $0 ..." >&2
          exit 3
        fi
        echo "qwen-review.sh: WARNING — proceeding on METERED upstream '${_fo_active}' because QWEN_ALLOW_METERED=1." >&2
        ;;
    esac
    # THE ROUND TALKS TO THE PROXY AND NOTHING ELSE (the owner, 2026-08-25: "it
    # should only be using the proxy that auto selects the plan that has
    # token ... remove direct plan link from revshell"). The user's own
    # ~/.qwen/settings.json may list the same model id more than once and the
    # CLI resolves it to the FIRST match — measured 2026-08-25: the id
    # resolved to the exhausted direct token-plan entry, three rounds died in
    # 10 s each, the proxy served zero requests. This driver therefore no
    # longer depends on that list's order: it installs a WORKSPACE settings
    # file in $REPO naming exactly one provider entry — the proxy — and hands
    # qwen a placeholder client token (the proxy strips the client's
    # Authorization and injects its own upstream key, so the placeholder never
    # reaches a vendor). No credential is written anywhere. The file is removed
    # (or a pre-existing one restored) on exit.
    qwen_failover_pin_workspace_route "$MODEL" >&2
  else
    echo "qwen-review.sh: local failover proxy is up, but --model/QWEN_REVIEW_MODEL pins '$MODEL'." >&2
    echo "qwen-review.sh: an explicitly pinned model is NOT rerouted — it talks to whatever" >&2
    echo "qwen-review.sh: upstream its own provider entry names, with no failover if that one is spent." >&2
  fi
elif [ "$QWEN_FAILOVER_REQUIRED" = "1" ]; then
  # The proxy is the default route; its absence is a setup fault, not a silent
  # downgrade to one fixed upstream.
  echo "qwen-review.sh: local failover proxy is NOT answering at $QWEN_FAILOVER_STATUS_URL." >&2
  echo "qwen-review.sh: it is the required default route for review rounds, so this round is" >&2
  echo "qwen-review.sh: NOT being run against a single fixed upstream. Start the proxy, or set" >&2
  echo "qwen-review.sh: QWEN_FAILOVER_REQUIRED=0 to accept a best-effort single-upstream round." >&2
  exit 4
fi

# ---- coding conventions (shared with codex-review.sh) -----------------------
write_conventions() {
  cat >> "$PROMPT_FILE" <<'EOF'

Project coding conventions to enforce while reviewing:
1. i18n every USER-FACING string (route through the project's t()/translation helper).
   Internal-only strings (console.log, thrown invariant messages, debug labels) are exempt.
2. Tunable values (magic numbers, model names, URLs, retry counts, timeouts, flags) live in
   centralized, scoped constants modules — never inline at call sites. Test assertions exempt.
3. No duplicate logic: reuse/export an existing helper rather than copy-pasting an equivalent.
   But do NOT abstract prematurely — duplication is cheaper than the wrong abstraction.
3b. PROMPT DIFFS (any .md a model receives: principles, rules, seat prompts, shared fragments):
   for every added or changed row or sentence, NAME the existing row that already owns the
   same intent, or state that none does after reading the WHOLE family it sits in. A row
   added without that statement is a finding, not a style note: fold into the owner
   (delete or narrow the other) before adding. Rows accreted one review at a time are how
   the same intent came to live in four places (measured 2026-09-09: the close sequence).
4. Exported helpers used by >=2 modules get their own single-responsibility file + a unit test;
   no utils.ts/helpers.ts dumping grounds. Private one-module helpers may co-locate.
Also: prefer pure functions, validate types at boundaries, never write client names into code.
EOF
}

# Qwen receives edit permission but deliberately has no shell permission in the
# normal auto-edit mode.  Without this instruction it can delegate tests to an
# internal agent, then wait forever for a result the agent cannot produce.
write_execution_constraints() {
  cat >> "$PROMPT_FILE" <<'EOF'

Execution constraints for this Qwen review:
- This is one synchronous review. Do NOT spawn, delegate to, or wait on agents,
  sub-sessions, background jobs, watchers, or polling tools. Do NOT call `agent`,
  `create_sub_session`, `loop_wakeup`, `computer_use`, or any background/delegation tool.
- In `auto-edit` mode you cannot run shell commands. Do NOT attempt, request,
  delegate, poll, or wait for test execution. The host runs tests after you
  return; verify the diff by inspection instead.
- Make any source or plan edits directly, then return the required findings,
  reviewer-edits block, and final verdict promptly. Never wait for an external
  result before finishing your review.
EOF
}

write_canonical_recall_contract() {
  cat >> "$PROMPT_FILE" <<'EOF'

Canonical-index recall contract:
- Before introducing any new constant, threshold, tunable, or mechanism, and before
  asserting that an existing mechanism does not already cover a case: query the project's
  memory/index MCP for prior art (in a product repo: search_specs / search_memory / search_code /
  find_symbol via acme-agent-index).
- No second authority over a fact that already has one: name the existing mechanism that
  already owns that concern and say why it is insufficient. A constant, threshold, timer,
  or mechanism with no named owner is a finding ("changes requested"), not a pass.
- If the MCP is denied or unavailable, say so EXPLICITLY in your reply, then fall back to
  the committed canonical documents named in the project's AGENTS.md — never to recalled
  or paraphrased knowledge.
EOF
}

# ---- build prompt ------------------------------------------------------------
PROMPT_FILE="$(mktemp -t qwen-review-prompt.XXXXXX)"
RESULT_FILE="$(mktemp -t qwen-review-result.XXXXXX)"
trap 'rm -f "$PROMPT_FILE" "$RESULT_FILE"; qwen_failover_unpin_workspace_route' EXIT

if [ "$PHASE" = "plan" ]; then
  cat > "$PROMPT_FILE" <<EOF
You are the REVIEWER in a revshell loop. The IMPLEMENTER wrote the plan at: $PLAN
Read that plan IN FULL. This is PHASE 1 (plan convergence) — review the PLAN ONLY.

Your job, as a tough but fair peer:
- Verify load-bearing claims in the plan (file:line references, named symbols) with read-only
  checks against the repo at $REPO. Flag anything unverifiable or wrong.
- Pressure-test the approach: missing edge cases, wrong abstraction, risky steps, scope gaps.
- MANDATE: directly implement EVERY plan issue you can fix yourself by editing the plan file —
  structural gaps included, not just wording. Never hand back a fixable issue for the implementer
  to apply. Reserve a description-without-a-fix ONLY for genuine judgement calls / design decisions
  the author must make, or user arbitration. A "changes requested" verdict MUST still carry your
  own plan edits for everything that was fixable.
- TAG every edit you make: (1) inline in the plan, append " [reviewer: <reason>]" on or beside
  each changed line; (2) in your reply, list every edit under a block headed exactly:
      REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:
  as "file:line — what changed + why" (write "... : none" if you made no edits).
- Do NOT edit any source code in this phase.
EOF
  write_conventions
  write_execution_constraints
  write_canonical_recall_contract
  cat >> "$PROMPT_FILE" <<EOF

End your reply with EXACTLY ONE of these two lines, on its own line, nothing after it:
VERDICT: $VERDICT_PLAN_GO
VERDICT: $VERDICT_CHANGES
EOF

elif [ "$PHASE" = "code" ]; then
  CODE_DIFF="$PRE_PIN_CODE_DIFF"
  DIFF_BYTES=${#CODE_DIFF}
  if [ "$DIFF_BYTES" -gt 600000 ]; then
    echo "qwen-review.sh: diff is large (${DIFF_BYTES} bytes); consider a tighter --base." >&2
  fi
  cat > "$PROMPT_FILE" <<EOF
You are the REVIEWER in a revshell loop (PHASE 2: implementation review).
Review ONLY the unified diff at the END of this message. It is the COMPLETE change set
(base $BASE -> working tree of $REPO). Plan context: $PLAN

HARD CONSTRAINTS:
- Do NOT broadly explore or grep the repository.
- Do NOT recall or reference past sessions or other repositories.
- You MAY open at most a couple of specific changed files for surrounding context — default to the diff.
- List each finding as: file:line - issue (CRITICAL/HIGH/MEDIUM/LOW).
- MANDATE: directly implement EVERY finding you can fix mechanically yourself by editing source
  in $REPO — structural fixes included, not just one-liners. Never hand back a fixable finding for
  the implementer to apply. Reserve a description-without-a-fix ONLY for items that genuinely need
  architectural judgement the author must make, or user arbitration. A "changes requested" verdict
  MUST still carry your own self-fixes for everything that was mechanically fixable.
- SEVERITY RULE: a LOW or MEDIUM finding is presumed mechanically fixable — it MUST arrive as an
  applied edit, not a description. EVERY finding you return without an edit must carry one line
  "not self-fixed because: <genuine architectural judgement / user arbitration / needs shell>".
  If you can describe the exact change, you can make it — make it.
- TAG every source edit under a block headed exactly:
      REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:
  as "file:line — what changed + why" (write "... : none" if you made no edits).

Find real correctness bugs, regressions, convention violations, or missing tests IN THIS DIFF.
EOF
  write_conventions
  write_execution_constraints
  write_canonical_recall_contract
  cat >> "$PROMPT_FILE" <<EOF

End your reply with EXACTLY ONE line, on its own line, nothing after it:
VERDICT: $VERDICT_SHIP
VERDICT: $VERDICT_CHANGES

=== UNIFIED DIFF (base $BASE) ===
EOF
  printf '%s\n' "$CODE_DIFF" >> "$PROMPT_FILE"

else
  echo "qwen-review.sh: --phase must be 'plan' or 'code' (got '$PHASE')" >&2
  exit 2
fi

if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
  printf '\n--- ROUND CONTEXT FROM THE IMPLEMENTER ---\n' >> "$PROMPT_FILE"
  cat "$CONTEXT_FILE" >> "$PROMPT_FILE"
fi

# ---- test hook: expose the assembled prompt for assertion (no network involved) -
# test-review-drivers.sh asserts on the prompt contents via this path.
if [ -n "${REVSHELL_TEST_QWEN_PROMPT:-}" ]; then
  cp "$PROMPT_FILE" "$REVSHELL_TEST_QWEN_PROMPT"
fi

# ---- confidentiality preflight (HARD GATE — must precede any network egress) -
# This backend uses the user's regular shell `qwen` CLI. Unless that CLI is known to
# be configured purely locally, treat the invocation as an off-machine egress of the
# whole prompt — including the complete diff. Nothing is sent until this passes.
revshell_guard_preflight "qwen" "$REPO" "$PROMPT_FILE"

# ---- run qwen (blocking, non-interactive, streaming JSON) --------------------
MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=(--model "$MODEL")
revshell_make_invocation_id "qwen" "$PHASE"
REVIEW_INVOCATION_ID="$REVSHELL_CURRENT_INVOCATION_ID"

# ---- pre-round tree state (EDITABLE backend — see SKILL.md "Qwen in EDITABLE
# mode"). Qwen writes to the working tree and has been observed committing
# staged work mid-review unasked. Snapshot HEAD + dirty set so the post-round
# audit can prove what the reviewer did, on EVERY exit path including timeout.
PRE_HEAD=""
PRE_DIRTY=""
IS_GIT_REPO=0
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  IS_GIT_REPO=1
  PRE_HEAD="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
  PRE_DIRTY="$(git -C "$REPO" status --porcelain 2>/dev/null | sort || true)"
fi

emit_post_round_audit() {
  [ "$IS_GIT_REPO" -eq 1 ] || return 0
  local post_head post_dirty
  post_head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
  post_dirty="$(git -C "$REPO" status --porcelain 2>/dev/null | sort || true)"
  echo
  echo "==== qwen-review POST-ROUND AUDIT (editable backend) ===="
  if [ -n "$PRE_HEAD" ] && [ -n "$post_head" ] && [ "$post_head" != "$PRE_HEAD" ]; then
    echo "!! HEAD MOVED DURING THE REVIEW: $PRE_HEAD -> $post_head"
    echo "!! The reviewer committed without being asked. Commits it made:"
    git -C "$REPO" log --oneline "$PRE_HEAD..$post_head" 2>/dev/null | sed 's/^/!!   /'
    echo "!! Recover with:  git -C '$REPO' reset --soft $PRE_HEAD"
    echo "!! Then prove no content was lost by comparing, before and after:"
    echo "!!                git -C '$REPO' rev-parse HEAD^{tree}"
    echo "!! NOTE: any memory-recall receipt your repo requires dies with the"
    echo "!! discarded commit and must be re-recorded before you commit again."
  else
    echo "HEAD unchanged (${post_head:-unknown}) — reviewer made no commit."
  fi
  if [ "$post_dirty" != "$PRE_DIRTY" ]; then
    echo "WORKING TREE CHANGED — the reviewer edited files. Audit EVERY edit"
    echo "(git diff) before trusting it, and check for scope bleed outside the"
    echo "files you intended to touch. Mutation-test any regression test it"
    echo "wrote for its own fix: revert ONLY the fix, confirm the test fails."
    git -C "$REPO" status --short 2>/dev/null | sed 's/^/   /'
  else
    echo "Working tree unchanged by the reviewer."
    echo "!! If the verdict above lists ANY finding, the reviewer broke the edit"
    echo "!! mandate (editable backend, auto-edit mode). Do NOT implement its"
    echo "!! findings yourself: re-run ONE round with --context <file> holding the"
    echo "!! unfixed findings plus the line 'apply these yourself as edits now;"
    echo "!! return only what genuinely needs the author's judgement.'"
    echo "!! The host implements ONLY labeled judgement calls. (SKILL.md:"
    echo "!! 'FINDINGS COME BACK AS EDITS', the owner 2026-08-19.)"
  fi
  emit_failover_audit
  echo "=========================================================="
}

# HARDENED 2026-08-20: a post-round audit is INFORMATION, and information must never be
# able to destroy the verdict it precedes. Measured 2026-08-19: this script died inside
# the metered-tier banner (~line 519 of the then-current file) under `set -euo pipefail`,
# one line before the VERDICT was printed, and that round's verdict was lost. A subshell
# with relaxed flags contains any fault here: worst case you lose the banner, never the
# verdict. (Golden rule: a det function may compute and TELL, it may not reject.)
# The subshell is safe: emit_post_round_audit only READS globals, never sets them.
emit_post_round_audit_guarded() {
  ( set +eu; emit_post_round_audit ) || true
}

# Which upstream actually served this round, and did it cost metered money?
# Reported on EVERY exit path (success, findings, timeout, invocation failure)
# for the same reason the working-tree audit is: an effect that outlives the
# round must never be something the caller has to go looking for. Two things
# are worth knowing and neither is guessable from the verdict text:
#   * the cascade fell through to a PER-TOKEN tier -> real money was spent;
#   * the cascade served ZERO requests while it was up -> the round did NOT go
#     through it (a provider list reordered under us, or the pinned model names
#     a fixed upstream), so the next quota exhaustion will kill the round.
emit_failover_audit() {
  [ "$QWEN_FAILOVER_SEEN" -eq 1 ] || return 0
  local json after_active after_total served
  json="$(qwen_failover_status || true)"
  read -r after_active after_total <<EOF
$(qwen_failover_summary "$json")
EOF
  echo "---- failover cascade ----"
  echo "Upstream serving now: ${after_active:-unknown}"
  # Both operands must be plain digits before any arithmetic: a proxy that answers
  # with `null`/`n/a` used to blow up `$(( ))` under `set -e` and take the verdict with it.
  if [ "$after_total" != "unknown" ] && [ "$QWEN_FAILOVER_REQ_BEFORE" != "unknown" ] \
     && [ -n "$after_total" ] && [ -n "$QWEN_FAILOVER_REQ_BEFORE" ] \
     && [ -z "${after_total//[0-9]/}" ] && [ -z "${QWEN_FAILOVER_REQ_BEFORE//[0-9]/}" ]; then
    served=$(( after_total - QWEN_FAILOVER_REQ_BEFORE ))
    echo "Requests this round: $served"
    if [ "$served" -le 0 ]; then
      echo "!! The proxy was up but served NOTHING for this round — it did not route"
      echo "!! through the cascade. Check that model '$MODEL' resolves to the proxy's"
      echo "!! provider entry; until it does, one spent quota still kills a review."
    fi
  fi
  case " $QWEN_FAILOVER_METERED_TIERS " in
    *" ${after_active:-none} "*)
      echo "!! METERED UPSTREAM: '${after_active}' bills PER TOKEN, not against a flat plan."
      echo "!! The subscription tiers ahead of it are exhausted or blocked. This round"
      echo "!! cost real money; say so when reporting it, and consider waiting for the"
      echo "!! next plan reset instead of running more rounds."
      ;;
  esac
}

set +e
PROMPT_BYTES="$(wc -c < "$PROMPT_FILE" | tr -d '[:space:]')"
if [ "$QWEN_FAILOVER_SEEN" -eq 1 ] && [ "${QWEN_ALLOW_METERED:-0}" != "1" ]; then
  QWEN_METERED_KILL_MARKER="$(mktemp -t qwen-metered-kill.XXXXXX)"
  : > "$QWEN_METERED_KILL_MARKER"
  qwen_metered_watch "$$" "$QWEN_METERED_BEFORE" "$QWEN_METERED_KILL_MARKER" </dev/null >/dev/null 2>&1 &
  QWEN_METERED_WATCH_PID=$!
  revshell_log "$REVIEW_INVOCATION_ID" "metered kill switch armed: metered-tier requests before=${QWEN_METERED_BEFORE}, polled every ${QWEN_METERED_KILL_POLL_SECONDS}s"
fi
# --canonical-recall drops `--safe-mode` (which disables MCP servers) so the
# reviewer can query acme-agent-index; the default round keeps it. Four
# explicit branches rather than a spliced flag, so every invocation string is
# fully quoted and readable. The mode is logged first so a transcript shows
# which one ran.
if [ "$CANONICAL_RECALL" -eq 1 ]; then
  revshell_log "$REVIEW_INVOCATION_ID" "canonical-recall: ENABLED — running qwen WITHOUT --safe-mode (MCP servers loaded; needs \"trust\": true on the index server entry and a cwd inside a worktree of the indexed repo)"
else
  revshell_log "$REVIEW_INVOCATION_ID" "canonical-recall: disabled (default) — running qwen --safe-mode; MCP servers are NOT loaded, the reviewer has no index recall"
fi
if [ "$PROMPT_BYTES" -le "$QWEN_INLINE_PROMPT_MAX_BYTES" ]; then
  PROMPT_INLINE="$(cat "$PROMPT_FILE")"
  if [ "$CANONICAL_RECALL" -eq 1 ]; then
    revshell_run_with_timeout "$REVIEW_INVOCATION_ID" "$TIMEOUT" \
      bash -c 'cd "$1" && qwen --output-format stream-json --approval-mode "$4" ${2:+--model "$2"} -p "$5"' \
      _ "$REPO" "$MODEL" "$PROMPT_FILE" "$APPROVAL_MODE" "$PROMPT_INLINE" \
      > "$RESULT_FILE"
  else
    revshell_run_with_timeout "$REVIEW_INVOCATION_ID" "$TIMEOUT" \
      bash -c 'cd "$1" && qwen --safe-mode --output-format stream-json --approval-mode "$4" ${2:+--model "$2"} -p "$5"' \
      _ "$REPO" "$MODEL" "$PROMPT_FILE" "$APPROVAL_MODE" "$PROMPT_INLINE" \
      > "$RESULT_FILE"
  fi
else
  if [ "$CANONICAL_RECALL" -eq 1 ]; then
    revshell_run_with_timeout "$REVIEW_INVOCATION_ID" "$TIMEOUT" \
      bash -c 'cd "$1" && qwen -p "" --output-format stream-json --approval-mode "$4" ${2:+--model "$2"} < "$3"' \
      _ "$REPO" "$MODEL" "$PROMPT_FILE" "$APPROVAL_MODE" \
      > "$RESULT_FILE"
  else
    revshell_run_with_timeout "$REVIEW_INVOCATION_ID" "$TIMEOUT" \
      bash -c 'cd "$1" && qwen --safe-mode -p "" --output-format stream-json --approval-mode "$4" ${2:+--model "$2"} < "$3"' \
      _ "$REPO" "$MODEL" "$PROMPT_FILE" "$APPROVAL_MODE" \
      > "$RESULT_FILE"
  fi
fi
RC=$?
if [ "$QWEN_METERED_WATCH_PID" -ne 0 ]; then
  kill "$QWEN_METERED_WATCH_PID" 2>/dev/null || true
  wait "$QWEN_METERED_WATCH_PID" 2>/dev/null || true
fi
set -e

if [ -n "$QWEN_METERED_KILL_MARKER" ] && [ -s "$QWEN_METERED_KILL_MARKER" ]; then
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: STOPPED MID-ROUND by the metered kill switch:" >&2
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: $(cat "$QWEN_METERED_KILL_MARKER")." >&2
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: internal review never runs on a pay-per-token tier. No verdict;" >&2
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: this backend edits by default, so audit the tree below." >&2
  rm -f "$QWEN_METERED_KILL_MARKER"
  emit_post_round_audit_guarded >&2
  exit 7
fi
[ -z "$QWEN_METERED_KILL_MARKER" ] || rm -f "$QWEN_METERED_KILL_MARKER"

if [ "$RC" -eq 124 ]; then
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: qwen timed out after ${TIMEOUT}s" >&2
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: A TIMEOUT WITH NO VERDICT DOES NOT MEAN" >&2
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: NOTHING HAPPENED — this backend edits by" >&2
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: default, so audit the tree below." >&2
  emit_post_round_audit_guarded >&2
  exit 4
elif [ "$RC" -ne 0 ]; then
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: qwen failed (exit=$RC)" >&2
  # stream-json can echo the prompt back, and the prompt QUOTES the verdict
  # boilerplate. A failed round must not leave a line that a log-watcher could read
  # as this round's verdict. The reviewer proposed STRIPPING those lines; that is a
  # det fence over an already-fixed root cause (await-log.sh's marker is anchored to
  # the lines this wrapper itself emits) and it would silently delete the most
  # informative lines of a failed round's diagnostics. So we ANNOTATE instead of
  # suppress: every byte of the captured output survives, in order, and the prefix
  # guarantees no dumped line can begin a verdict. Compute and TELL, never withhold.
  sed 's/^/  |raw| /' "$RESULT_FILE" >&2 2>/dev/null || true
  emit_post_round_audit_guarded >&2
  exit 5
fi

# ---- extract and print the result text from JSON stream ----------------------
# `|| PARSE_RC=$?` keeps `set -e` from killing the script before the post-round
# audit runs: an unparseable result still leaves reviewer EDITS on disk.
PARSE_RC=0
RESULT_TEXT="$(python3 - "$RESULT_FILE" <<'PYEOF'
import sys, json
result_events = []
with open(sys.argv[1], encoding='utf-8') as result_stream:
    for line in result_stream:
        line = line.strip()
        if not line:
            continue
        try:
            chunk = json.loads(line)
            items = chunk if isinstance(chunk, list) else [chunk]
            for item in items:
                if isinstance(item, dict) and item.get('type') == 'result':
                    result_events.append(item)
        except json.JSONDecodeError:
            pass

if not result_events:
    print('[qwen-review: no result event parsed]', file=sys.stderr)
    sys.exit(1)

r = result_events[-1]
if r.get('is_error'):
    print('[qwen-review: result is_error=true]', file=sys.stderr)
    sys.exit(1)
print(r.get('result', ''), end='')
PYEOF
)" || PARSE_RC=$?

if [ "$PARSE_RC" -ne 0 ]; then
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: no parseable result event — treat as" >&2
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: NOT converged. Reviewer edits may still" >&2
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: be on disk; audit the tree below." >&2
  emit_post_round_audit_guarded >&2
  exit 6
fi

printf '%s\n' "$RESULT_TEXT"

# ---- parse + emit the verdict ------------------------------------------------
VERDICT_LINE="$(printf '%s\n' "$RESULT_TEXT" | grep -ioE "VERDICT: *(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" | tail -1 || true)"
if [ -z "$VERDICT_LINE" ]; then
  BARE="$(printf '%s\n' "$RESULT_TEXT" | grep -ioE "(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" | tail -1 || true)"
  [ -n "$BARE" ] && VERDICT_LINE="VERDICT: $BARE"
fi
[ -z "$VERDICT_LINE" ] && VERDICT_LINE="VERDICT: ${VERDICT_CHANGES} (no explicit verdict parsed — treat as not converged)"

# INFORMATION must never be able to destroy the verdict it precedes — see
# emit_post_round_audit_guarded above.
emit_post_round_audit_guarded

echo
echo "==== qwen-review verdict (phase=$PHASE, model=${MODEL:-qwen-default}) ===="
echo "$VERDICT_LINE"
exit
}
