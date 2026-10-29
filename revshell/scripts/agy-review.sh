#!/usr/bin/env bash
{ # The whole file is one group, so bash parses all of it before running any of it: a rewrite in place
  # cannot corrupt a running round (2026-10-21: a cp over this file killed a 75-minute review at line 517).
# agy-review.sh — drive `agy` as the in-shell REVIEWER for `revshell` mode.
#
# This is the first revshell fallback after the default Codex backend. `agy` runs on its own
# subscription via its CLI at `~/.local/bin/agy`.
#
# CORRECTED 2026-09-18: this read "`agy` drives Claude models (not OpenAI)". the owner,
# 2026-09-15: "no agy is its own sub", "agy is gemini", "flash 3.8 ... that is the default"
# — so run it with no --model. Measured on the day the Claude weekly limit was reached:
# `agy --print='name the model you run as'` answered "Gemini 3.8 Flash". The stale line
# mattered because it implied agy spends the CLAUDE quota, which is the worst thing to
# believe on the day that quota runs out.
#
# Parallel to codex-review.sh / qwen-review.sh: same prompt structure, same verdict
# sentinels, same reviewer-edit tagging protocol. Driven via `agy --mode accept-edits --print`.
#
# CORRECTED 2026-09-18 (the owner: "can you correct that at skill level please"): this said
# "agy in print mode does NOT edit files", so the REVIEWER EDITS block was forced to "none"
# and every agy round was silently a COMMENT-ONLY review -- the exact downgrade the user-wide
# review policy (~/.agents/review-mode.md) forbids. The installed agy CLI has
# `--mode accept-edits`; with it the reviewer edits the worktree directly and tags each edit,
# like Codex and Qwen. AGY_REVIEW_MODE=plan is the one named read-only exception (an audit
# of an artefact that must not change); anything else refuses.
#
# Usage:
#   agy-review.sh --plan <plan-path> --phase <plan|code> --repo <worktree-dir> \
#                 [--base <ref>] [--model <m>] [--context <file>] [--timeout <secs>]
#
#   --plan      the ONE canonical plan file
#   --phase     plan → review the PLAN only; code → review the implemented DIFF
#   --repo      working root (agy runs with this as its working directory)
#   --base      git ref the diff is measured from (code phase only; default: HEAD~1)
#   --model     agy model id (default: AGY_REVIEW_MODEL env or agy's configured default;
#               run `agy models` to see what's available on this machine).
#   --context   optional file appended as extra steering for this round
#   --timeout   seconds before giving up (default: AGY_REVIEW_TIMEOUT env or 1800). Applied
#               both by the shared revshell watchdog AND passed to agy's own
#               --print-timeout, so a hang is bounded even if one guard misbehaves.
#
# Prints agy's full response to stdout, then a final line: VERDICT: <verdict>
# Exit status: 0 on clean run; non-zero only on agy invocation failure.
#
# Caveat: the full prompt (conventions + inlined diff) is passed to agy as a single CLI
# argument, not via stdin (agy's --print takes its value directly, matching the proven
# invocation pattern). Very large diffs risk the shell's argv size limit; the same ~600KB
# diff-size warning used by codex-review.sh/qwen-review.sh applies — for bigger diffs,
# tighten --base or fall back to qwen-review.sh, which streams the prompt over stdin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=review-runtime.sh
. "$SCRIPT_DIR/review-runtime.sh"

# ---- constants ---------------------------------------------------------------
# No --model by default (the owner, 2026-09-15: "agy is gemini", "flash 3.8 ... that is the
# default"); the stale default here named a Claude model agy no longer runs by default.
AGY_MODEL_DEFAULT="${AGY_REVIEW_MODEL:-}"
# NO ABSOLUTE CEILING BY DEFAULT (2026-08-27), same ruling as qwen-review.sh
# (2026-08-19) and codex-review.sh: silence, not elapsed time, is the stop
# condition -- a live round killed at a ceiling loses completed work.
# CORRECTED 2026-10-17 (a product repo): `agy --print` buffers its whole answer and streams
# nothing until it exits, so the shared silence watchdog fired on every healthy round longer
# than 600 s (measured: an Argon plan review stopped at 611 s with 0 B, no edits; the re-run
# with the watchdog off finished in 965 s). The bound is agy's own --print-timeout instead,
# the same value as the wrapper ceiling below; a stop is reported as "agy timed out after Ns"
# (exit 4). The silence watchdog is off for agy only; codex/qwen stream and keep it.
AGY_TIMEOUT_DEFAULT="${AGY_REVIEW_TIMEOUT:-3600}"
REVSHELL_IDLE_TIMEOUT_SECONDS=0
export REVSHELL_IDLE_TIMEOUT_SECONDS
AGY_BASE_DEFAULT="HEAD~1"

VERDICT_PLAN_GO="ready for implementation"
VERDICT_SHIP="ready to ship"
VERDICT_CHANGES="changes requested"

# ---- arg parse ---------------------------------------------------------------
PLAN="" ; PHASE="" ; REPO="" ; BASE="$AGY_BASE_DEFAULT"
MODEL="$AGY_MODEL_DEFAULT" ; CONTEXT_FILE="" ; TIMEOUT="$AGY_TIMEOUT_DEFAULT"

while [ $# -gt 0 ]; do
  case "$1" in
    --plan)    PLAN="$2";    shift 2 ;;
    --phase)   PHASE="$2";   shift 2 ;;
    --repo)    REPO="$2";    shift 2 ;;
    --base)    BASE="$2";    shift 2 ;;
    --model)   MODEL="$2";   shift 2 ;;
    --context) CONTEXT_FILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "agy-review.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$PLAN" ]  || { echo "agy-review.sh: --plan is required" >&2; exit 2; }
[ -n "$PHASE" ] || { echo "agy-review.sh: --phase is required (plan|code)" >&2; exit 2; }
[ -f "$PLAN" ]  || { echo "agy-review.sh: plan file not found: $PLAN" >&2; exit 2; }
# A --context that names no readable file is refused, never dropped (2026-10-25, a product repo: a review launched
# with the context TEXT as the argument ran without its round context, and nothing said so).
[ -z "$CONTEXT_FILE" ] || [ -f "$CONTEXT_FILE" ] || { echo "agy-review.sh: context file not found: ${CONTEXT_FILE:0:120}" >&2; exit 2; }
if [ -z "$REPO" ]; then REPO="$(cd "$(dirname "$PLAN")" && pwd)"; fi
[ -d "$REPO" ]  || { echo "agy-review.sh: repo dir not found: $REPO" >&2; exit 2; }
command -v agy >/dev/null 2>&1 || { echo "agy-review.sh: agy CLI not on PATH (fall back to qwen-review.sh)" >&2; exit 3; }

# ---- review mode: EDIT-CAPABLE by default (2026-09-18) ------------------------
# ~/.agents/review-mode.md: reviews default to edit-capable mode; read-only is a NAMED
# exception. AGY_REVIEW_MODE=plan is that exception and says so in the prompt.
AGY_MODE="${AGY_REVIEW_MODE:-accept-edits}"
case "$AGY_MODE" in
  accept-edits)
    EDIT_MANDATE_PLAN='You have WRITE access in this session. Directly apply every fix you can make yourself to the plan file ($PLAN) -- do not hand back a to-do list. Do NOT edit source code in this phase. TAG every edit: add " [reviewer: <reason>]" beside each changed plan line, and list every edit in your reply under a block headed exactly:
      REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:
  as "file:line — what changed + why" (write "... : none" if you made no edits). Never silently revert the author'"'"'s intent. You have no shell: the host runs the tests.'
    EDIT_MANDATE_CODE='You have WRITE access to the worktree in this session. Directly implement every fix you can make yourself, including a regression test where a defect is real -- do not hand back a to-do list. TAG every edit: list each one in your reply under a block headed exactly:
      REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:
  as "file:line — what changed + why" (write "... : none" if you made no edits). Do not add marker comments to source. Do not commit, push, merge or rebase. You have no shell: the host runs the tests and the commit.'
    ;;
  plan)
    EDIT_MANDATE_PLAN='READ-ONLY review (named exception: AGY_REVIEW_MODE=plan). Do not edit anything; give paste-ready replacement text for every fix, and include the block "REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none".'
    EDIT_MANDATE_CODE="$EDIT_MANDATE_PLAN"
    echo "agy-review.sh: READ-ONLY round (AGY_REVIEW_MODE=plan) -- the named exception to edit-capable review." >&2
    ;;
  *) echo "agy-review.sh: AGY_REVIEW_MODE must be accept-edits (default) or plan, not '$AGY_MODE'" >&2; exit 2 ;;
esac
EDIT_MANDATE_PLAN="${EDIT_MANDATE_PLAN//\$PLAN/$PLAN}"

# ---- coding conventions (shared with codex-review.sh / qwen-review.sh) ------
write_conventions() {
  cat >> "$PROMPT_FILE" <<'EOF'

Project coding conventions to enforce while reviewing:
1. i18n every USER-FACING string (route through the project's t()/translation helper).
   Internal-only strings (console.log, thrown invariant messages, debug labels) are exempt.
2. Tunable values (magic numbers, model names, URLs, retry counts, timeouts, flags) live in
   centralized, scoped constants modules — never inline at call sites. Test assertions exempt.
3. No duplicate logic: reuse/export an existing helper rather than copy-pasting an equivalent.
   But do NOT abstract prematurely — duplication is cheaper than the wrong abstraction.
4. Exported helpers used by >=2 modules get their own single-responsibility file + a unit test;
   no utils.ts/helpers.ts dumping grounds. Private one-module helpers may co-locate.
Also: prefer pure functions, validate types at boundaries, never write client names into code.
EOF
}

write_execution_constraints() {
  cat >> "$PROMPT_FILE" <<'EOF'

Synchronous review constraints:
- This is one synchronous review. Do NOT spawn, delegate to, or wait on agents,
  sub-sessions, background jobs, watchers, or polling tools.
- Do not wait for any external result. Return the required reviewer-edits block and
  terminal verdict promptly after inspecting the supplied material.
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

# ---- build prompt --------------------------------------------------------------
PROMPT_FILE="$(mktemp -t agy-review-prompt.XXXXXX)"
RESULT_FILE="$(mktemp -t agy-review-result.XXXXXX)"
trap 'rm -f "$PROMPT_FILE" "$RESULT_FILE"' EXIT

if [ "$PHASE" = "plan" ]; then
  cat > "$PROMPT_FILE" <<EOF
You are the REVIEWER in a revshell loop. The IMPLEMENTER wrote the plan at: $PLAN
Read that plan IN FULL. This is PHASE 1 (plan convergence) — review the PLAN ONLY.

Your job, as a tough but fair peer:
- Verify load-bearing claims in the plan (file:line references, named symbols) against the
  repo at $REPO to the extent you can. Flag anything unverifiable or wrong.
- Pressure-test the approach: missing edge cases, wrong abstraction, risky steps, scope gaps.
- $EDIT_MANDATE_PLAN
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
  CODE_DIFF="$(git -C "$REPO" diff "$BASE" 2>/dev/null)"
  revshell_require_code_diff agy-review.sh "$BASE" "$REPO" "$CODE_DIFF"
  DIFF_BYTES=${#CODE_DIFF}
  if [ "$DIFF_BYTES" -gt 600000 ]; then
    echo "agy-review.sh: diff is large (${DIFF_BYTES} bytes); this backend passes the prompt as a CLI argument — consider a tighter --base or qwen-review.sh instead." >&2
  fi
  cat > "$PROMPT_FILE" <<EOF
You are the REVIEWER in a revshell loop (PHASE 2: implementation review).
Review ONLY the unified diff at the END of this message. It is the COMPLETE change set
(base $BASE -> working tree of $REPO). Plan context: $PLAN

HARD CONSTRAINTS:
- Do NOT broadly explore or grep the repository.
- Do NOT recall or reference past sessions or other repositories.
- You MAY open at most a couple of specific changed files for surrounding context — default
  to the diff; do not go hunting.
- List each finding as: file:line - issue (CRITICAL/HIGH/MEDIUM/LOW).
- $EDIT_MANDATE_CODE

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
  echo "agy-review.sh: --phase must be 'plan' or 'code' (got '$PHASE')" >&2
  exit 2
fi

if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
  printf '\n--- ROUND CONTEXT FROM THE IMPLEMENTER ---\n' >> "$PROMPT_FILE"
  cat "$CONTEXT_FILE" >> "$PROMPT_FILE"
fi

# ---- run agy print mode (blocking, non-interactive) ---------------------------
# agy's --print takes the prompt as its own argument value (not stdin), so the prompt
# file's contents are substituted in — safe under double quotes even if the diff itself
# contains quote characters, since bash does not re-parse an already-substituted value.
revshell_make_invocation_id "agy" "$PHASE"
REVIEW_INVOCATION_ID="$REVSHELL_CURRENT_INVOCATION_ID"

set +e
revshell_run_with_timeout "$REVIEW_INVOCATION_ID" "$TIMEOUT" \
  bash -c 'cd "$1" && exec agy --mode "$5" ${2:+--model "$2"} --print-timeout "${3}s" --print "$(cat "$4")"' \
  _ "$REPO" "$MODEL" "$TIMEOUT" "$PROMPT_FILE" "$AGY_MODE" \
  > "$RESULT_FILE"
RC=$?
set -e

if [ "$RC" -eq 124 ]; then
  echo "agy-review.sh[$REVIEW_INVOCATION_ID]: agy timed out after ${TIMEOUT}s" >&2
  exit 4
elif [ "$RC" -ne 0 ]; then
  echo "agy-review.sh[$REVIEW_INVOCATION_ID]: agy failed (exit=$RC) — fall back to qwen-review.sh" >&2
  cat "$RESULT_FILE" >&2
  exit 5
fi

RESULT_TEXT="$(cat "$RESULT_FILE")"
printf '%s\n' "$RESULT_TEXT"

# ---- parse + emit the verdict ------------------------------------------------
VERDICT_LINE="$(printf '%s\n' "$RESULT_TEXT" | grep -ioE "VERDICT: *(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" | tail -1 || true)"
if [ -z "$VERDICT_LINE" ]; then
  BARE="$(printf '%s\n' "$RESULT_TEXT" | grep -ioE "(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" | tail -1 || true)"
  [ -n "$BARE" ] && VERDICT_LINE="VERDICT: $BARE"
fi
[ -z "$VERDICT_LINE" ] && VERDICT_LINE="VERDICT: ${VERDICT_CHANGES} (no explicit verdict parsed — treat as not converged)"

echo
echo "==== agy-review verdict (phase=$PHASE, model=${MODEL:-agy-default}) ===="
echo "$VERDICT_LINE"
exit
}
