#!/usr/bin/env bash
{ # The whole file is one group, so bash parses all of it before running any of it: a rewrite in place
  # cannot corrupt a running round (2026-10-21: a cp over this file killed a 75-minute review at line 517).
# codex-review.sh — drive Codex as the in-shell REVIEWER for `shellrev` mode.
#
# In shellrev mode the host (Claude) is BOTH orchestrator and IMPLEMENTER and runs
# in a single session: there is no second human-driven Codex session, no plan-file
# marker dance, and no cross-session watcher. Each review round is just a BLOCKING
# `codex exec` subprocess — this script — whose stdout carries Codex's findings and
# whose last line carries a parseable verdict. Codex runs with `workspace-write`, and its
# MANDATE is to directly implement EVERY finding it can fix itself — it edits the plan in
# --phase plan and source in --phase code — and TAGS each edit (a `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:` block
# in its output, plus an inline `[reviewer: reason]` marker in edited prose/plan). The host
# (implementer) then reviews every tagged edit with `git diff` + focused tests before landing.
#
# Usage:
#   codex-review.sh --plan <plan-path> --phase <plan|code> --repo <worktree-dir> \
#                   [--base <ref>] [--model <m>] [--effort <level>] [--sandbox <mode>] \
#                   [--context <file>] [--timeout <seconds>] [--canonical-recall]
#
#   --model     review model. Defaults to gpt-5.6-terra FOR REVSHELL ROUNDS ONLY, passed
#               per-invocation; the user's ~/.codex/config.toml is never read or written
#               for it. Pass an empty string to inherit the Codex config default instead.
#               NOTE: the bare name `terra` is rejected on a ChatGPT account — pass the
#               full `gpt-5.6-terra`.
#   --effort    reasoning effort (minimal|low|medium|high|xhigh). Defaults to high — a
#               low-effort pass over a large diff is not a gate. Also per-invocation only.
#
#   --plan      the ONE canonical plan file (Codex reads it; in --phase plan it fixes every fixable issue in it directly, tagged)
#   --phase     plan  → review the PLAN; Codex fixes every fixable plan issue directly (tagged), no source edits
#               code  → review the implemented DIFF; Codex fixes every fixable finding in source directly (tagged)
#   --repo      working root passed to `codex -C` (the temp-branch worktree)
#   --base      git ref the diff is measured against (code phase only; default: HEAD~1)
#   --context   optional file whose contents steer this round (e.g. the host's "here is what I changed
#               since your last verdict" note, plus the checks the round must settle). Code phase: placed
#               ABOVE the verdict line and the diff. Plan phase: appended after the verdict lines.
#
#   --canonical-recall
#               OPT-IN, DEFAULT OFF. Probed and established 2026-08-27: with the default
#               `-s "$SANDBOX" -c approval_policy=$APPROVAL_POLICY` (today's behaviour,
#               unchanged unless this flag is passed), every `acme-agent-index` MCP
#               tool call Codex attempts fails with EXACTLY this error:
#                   MCP tool call requires approval, but approval policy is never
#               Re-probed with `--approve-for-me` instead of `-s`/`-c approval_policy`:
#               the same MCP call SUCCEEDS. So when --canonical-recall is passed, this
#               script invokes `codex exec --approve-for-me` INSTEAD OF
#               `-s "$SANDBOX" -c approval_policy=$APPROVAL_POLICY` — everything else
#               (model, effort, -C, --skip-git-repo-check, -o, prompt on stdin) is
#               unchanged. The trade-off: `--approve-for-me` is mutually exclusive with
#               `-s/--sandbox` in the Codex CLI — passing both is a Codex CLI error
#               ("the argument '--sandbox <SANDBOX_MODE>' cannot be used with
#               '--approve-for-me'") — and `--approve-for-me` unconditionally forces
#               `approval: on-request` + `sandbox: workspace-write [workdir, /tmp,
#               $TMPDIR]`, so this script never gets to pick a stricter sandbox (e.g.
#               read-only) once canonical recall is requested. Concretely: a read-only
#               comment-mode round (explicit `--sandbox read-only`) CANNOT ALSO have MCP
#               access — passing both together is a fail-fast usage error (exit 2), not a
#               silent choice of one over the other. The round's first stderr line
#               ([revshell:...] logging) always states whether canonical recall is
#               ENABLED or disabled for that round, so a transcript shows which mode ran
#               without having to reconstruct it from the invocation.
#
#               --approve-for-me IS NOT ENOUGH ON ITS OWN (measured 2026-09-19). Codex
#               >= 0.147 starts optional MCP servers in the BACKGROUND, gives them a
#               shared ONE-SECOND startup grace, and OMITS any server still pending from
#               that step's tool catalog (openai/codex#35742 "Avoid blocking turns on
#               optional MCP startup"; #35590, #36011). `acme-agent-index serve` needs
#               5.7s idle and 7.1s under four-way concurrency to answer `initialize`
#               (uv start + imports + its pre-handshake index_status), so it ALWAYS
#               misses that one second: the reviewer's first step sees an EMPTY catalog,
#               reports "the canonical-index MCP was unavailable", and — obeying the
#               contract below — spends the whole round on the committed fallback. Two
#               rounds did exactly that on 2026-09-19 (sessions 01a0b9df / 01a0b9e6,
#               `ALL_TOOLS.filter(/acme/)` -> `[]` at +7.3s and +8.9s), while rounds
#               whose model happened to look at +11.3s or later found all seven tools.
#               Codex keeps waiting for a server the TURN EXPLICITLY NAMES as a mention
#               in the user text — `[$name](mcp://name)` — so --canonical-recall now
#               emits exactly that line into the prompt (CANONICAL_RECALL_MCP_SERVER
#               below). Verified: with the line, the seven tools are in ALL_TOOLS at
#               the model's FIRST action and search_specs returns a record; without it,
#               same repo and flags one minute earlier, ALL_TOOLS has none of them.
#               READY IS NOT VISIBLE: code mode DEFERS MCP tools (absent from the exec
#               tool's description, present only in ALL_TOOLS / tools.*), so the prompt
#               also says where they are and which check decides availability — see
#               write_canonical_recall_mention (S2 R02, 2026-09-19).
#
# Prints Codex's full message to stdout, then a final line:  VERDICT: <verdict>
# Exit status is 0 on a clean run regardless of verdict; non-zero only on a Codex
# invocation failure (so the host can distinguish "Codex spoke" from "Codex broke").

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=review-runtime.sh
. "$SCRIPT_DIR/review-runtime.sh"

# ---- centralized, tunable constants -----------------------------------------
# Model + reasoning effort are pinned HERE, for revshell review rounds ONLY, and are
# passed per-invocation to `codex exec`. The user's global ~/.codex/config.toml is
# neither read nor written for these two values: a review round gets a review-grade
# model at high effort while everyday Codex work keeps whatever the user configured.
# Tuning the review gate must never mean editing someone's editor settings.
#
# Both remain overridable. If the account lacks the pinned model, `codex exec` fails
# loudly (exit 5) rather than silently reviewing with a different one — override with
# --model / COREVIEW_CODEX_MODEL, or set it empty to inherit the config default.
#
# Set BACK to gpt-5.6-terra at high effort by the owner, 2026-08-09 ("gpt-5.4
# should not be the default. terra high should be"), reverting the 2026-08-08
# switch to gpt-5.4/medium. Verified callable on this account before the switch:
# `codex exec -m gpt-5.6-terra` answers; note that the bare name `terra` does
# NOT work ("not supported when using Codex with a ChatGPT account") — the full
# `gpt-5.6-terra` is the id to pass.
#
# On temperature: deliberately absent, not overlooked. These are reasoning
# models — they expose `model_reasoning_effort`, not a temperature knob, so a
# request to review "at temp 0.1" is answered by the effort setting below and
# by nothing else. Do not add a temperature flag; codex exec would ignore it.
CODEX_MODEL_DEFAULT="${COREVIEW_CODEX_MODEL-gpt-5.6-terra}"
# High by owner instruction, 2026-08-09. A low-effort pass over a large diff is
# not a gate, and the medium default made that the caller's problem to remember;
# high is the safer floor. Lower it per-invocation via --effort /
# COREVIEW_CODEX_REASONING_EFFORT for a small, mechanical diff where the cost is
# not worth it.
CODEX_EFFORT_DEFAULT="${COREVIEW_CODEX_REASONING_EFFORT-high}"
# GPU repos need `danger-full-access`: the sandbox denies `iokit-open`, so
# `MTLCreateSystemDefaultDevice()` returns nil and any import of MLX (mlx /
# mlx_audio / mlx_whisper) aborts the interpreter with SIGABRT — an uncatchable
# `[metal::load_device] No Metal device available` C++ throw, which means the
# reviewer's test run reports NOTHING instead of failing cleanly. Measured
# 2026-08-03 on voiceclone. Widen per-invocation only, never globally.
CODEX_SANDBOX_DEFAULT="${COREVIEW_CODEX_SANDBOX:-workspace-write}"
# NO ABSOLUTE CEILING BY DEFAULT (2026-08-27), adopting qwen-review.sh's own
# 2026-08-19 ruling for the same reason, now measured on Codex too: a
# gpt-5.6-sol xhigh plan round was killed at the 1800s ceiling while ALIVE and
# streaming (10.5 MB and still growing). review-runtime.sh's own message names
# the fix -- "it was alive, so raise --timeout or set it to 0". SILENCE, not
# elapsed time, is the correct stop condition; the idle timeout below is what
# actually protects against a hung round. Pass --timeout <secs> to bound a
# round deliberately.
CODEX_TIMEOUT_DEFAULT="${COREVIEW_CODEX_TIMEOUT:-0}"
# Codex xhigh rounds think for long stretches between streamed chunks; the
# runtime's 300s default is one slightly larger plan away from killing a
# healthy round. The caller's own REVSHELL_IDLE_TIMEOUT_SECONDS always wins.
: "${REVSHELL_IDLE_TIMEOUT_SECONDS:=600}"
export REVSHELL_IDLE_TIMEOUT_SECONDS
CODEX_BASE_DEFAULT="HEAD~1"
APPROVAL_POLICY="never"                                   # non-interactive: never prompt
# The canonical-index MCP server a --canonical-recall round must have BEFORE its
# first model request. Named here (never spliced into the prompt text by hand) so
# another project can point the same driver at its own index server without
# editing this file: COREVIEW_CANONICAL_RECALL_MCP_SERVER=<server> codex-review.sh
# --canonical-recall …. The name must match the server id in ~/.codex/config.toml
# (`codex mcp list`); see the --canonical-recall block in the header for why the
# mention is what makes Codex wait for it.
# When the variable is unset, the reviewed repository names its own server: the one
# [mcp_servers.<name>-agent-index] table in its .codex/config.toml (resolved once --repo is
# known, below). acme-agent-index stays the default only for a repository that declares
# none (2026-10-21: an a product repo round named the default server, the model fell back to
# a product repo, and the blind-recall report fired on a round that had used its index).
CANONICAL_RECALL_MCP_SERVER="${COREVIEW_CANONICAL_RECALL_MCP_SERVER:-acme-agent-index}"

# Verdict sentinels Codex is instructed to emit (the host parses these).
VERDICT_PLAN_GO="ready for implementation"
VERDICT_SHIP="ready to ship"
VERDICT_CHANGES="changes requested"

# ---- arg parse ---------------------------------------------------------------
PLAN="" ; PHASE="" ; REPO="" ; BASE="$CODEX_BASE_DEFAULT"
MODEL="$CODEX_MODEL_DEFAULT" ; SANDBOX="$CODEX_SANDBOX_DEFAULT"
EFFORT="$CODEX_EFFORT_DEFAULT"
CONTEXT_FILE="" ; TIMEOUT="$CODEX_TIMEOUT_DEFAULT"
CANONICAL_RECALL=0            # opt-in; see usage block above
SANDBOX_EXPLICIT=0             # tracks whether --sandbox was passed by the caller

while [ $# -gt 0 ]; do
  case "$1" in
    --plan)    PLAN="$2"; shift 2 ;;
    --phase)   PHASE="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --base)    BASE="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --effort)  EFFORT="$2"; shift 2 ;;
    --sandbox) SANDBOX="$2"; SANDBOX_EXPLICIT=1; shift 2 ;;
    --context) CONTEXT_FILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --canonical-recall) CANONICAL_RECALL=1; shift 1 ;;
    *) echo "codex-review.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$PLAN" ]  || { echo "codex-review.sh: --plan is required" >&2; exit 2; }
[ -n "$PHASE" ] || { echo "codex-review.sh: --phase is required (plan|code)" >&2; exit 2; }
[ -f "$PLAN" ]  || { echo "codex-review.sh: plan file not found: $PLAN" >&2; exit 2; }
# A --context that names no readable file is refused, never dropped (2026-10-25, a product repo: a review launched
# with the context TEXT as the argument ran without its round context, and nothing said so).
[ -z "$CONTEXT_FILE" ] || [ -f "$CONTEXT_FILE" ] || { echo "codex-review.sh: context file not found: ${CONTEXT_FILE:0:120}" >&2; exit 2; }
# ABSOLUTE PLAN PATH (2026-10-06, a product repo coordinator): the prompt hands codex "the plan at: $PLAN" and codex runs
# with its cwd in --repo, so a path relative to the CALLER's cwd passed this check and then resolved to nothing
# inside the session: nine a product repo reviews ran without their briefs ("briefs/R-X.md was unavailable").
PLAN="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
if [ -z "$REPO" ]; then REPO="$(cd "$(dirname "$PLAN")" && pwd)"; fi
[ -d "$REPO" ]  || { echo "codex-review.sh: repo dir not found: $REPO" >&2; exit 2; }
if [ -z "${COREVIEW_CANONICAL_RECALL_MCP_SERVER:-}" ]; then
  REPO_ROOT="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)"
  REPO_CODEX_CONFIG="$REPO_ROOT/.codex/config.toml"
  if [ -n "$REPO_ROOT" ] && [ -r "$REPO_CODEX_CONFIG" ]; then
    REPO_RECALL_SERVERS="$(sed -n -E \
      -e 's/^[[:space:]]*\[[[:space:]]*mcp_servers[[:space:]]*\.[[:space:]]*([A-Za-z0-9_-]+-agent-index)[[:space:]]*\][[:space:]]*(#.*)?$/\1/p' \
      -e 's/^[[:space:]]*\[[[:space:]]*mcp_servers[[:space:]]*\.[[:space:]]*"([A-Za-z0-9_-]+-agent-index)"[[:space:]]*\][[:space:]]*(#.*)?$/\1/p' \
      -e "s/^[[:space:]]*\\[[[:space:]]*mcp_servers[[:space:]]*\\.[[:space:]]*'([A-Za-z0-9_-]+-agent-index)'[[:space:]]*\\][[:space:]]*(#.*)?$/\\1/p" \
      "$REPO_CODEX_CONFIG")"
    if [ -n "$REPO_RECALL_SERVERS" ] && [ "$(printf '%s\n' "$REPO_RECALL_SERVERS" | wc -l | tr -d ' ')" = 1 ]; then
      CANONICAL_RECALL_MCP_SERVER="$REPO_RECALL_SERVERS"
    fi
  fi
fi
command -v codex >/dev/null 2>&1 || { echo "codex-review.sh: codex CLI not on PATH" >&2; exit 3; }

# --canonical-recall runs `codex exec --approve-for-me`, which the Codex CLI refuses to
# combine with an explicit `--sandbox` (verbatim: "the argument '--sandbox <SANDBOX_MODE>'
# cannot be used with '--approve-for-me'"). A read-only comment-mode round explicitly
# asking for --sandbox read-only is exactly the case that would otherwise be silently
# resolved one way or the other — fail fast instead.
if [ "$CANONICAL_RECALL" -eq 1 ] && [ "$SANDBOX_EXPLICIT" -eq 1 ]; then
  echo "codex-review.sh: --canonical-recall and an explicit --sandbox ('$SANDBOX') are mutually exclusive in the Codex CLI" >&2
  echo "codex-review.sh: --approve-for-me (required for MCP/canonical-recall access) cannot be combined with -s/--sandbox — Codex CLI error: \"the argument '--sandbox <SANDBOX_MODE>' cannot be used with '--approve-for-me'\"" >&2
  echo "codex-review.sh: a read-only comment-mode round therefore cannot also have MCP access — pick one for this round" >&2
  exit 2
fi

# ---- build the per-phase prompt into a temp file (avoids bash-3.2 nested-heredoc bugs) ----
PROMPT_FILE="$(mktemp -t coreview-codex-prompt.XXXXXX)"
LAST_MSG="$(mktemp -t coreview-codex-last.XXXXXX)"
# The round's full captured output (Codex's progress lines included), kept so the
# driver can read what the round actually did before it prints the verdict.
REVIEW_OUT="$(mktemp -t coreview-codex-out.XXXXXX)"
trap 'rm -f "$PROMPT_FILE" "$LAST_MSG" "$REVIEW_OUT"' EXIT

# Coding conventions restated for the reviewer (keep in sync with your global agent instructions).
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

write_execution_constraints() {
  cat >> "$PROMPT_FILE" <<'EOF'

Synchronous review constraints:
- This is one synchronous review. Do NOT spawn, delegate to, or wait on agents,
  sub-sessions, background jobs, watchers, or polling tools.
- Do not wait for any external result. You may run directly available checks yourself
  only when they require no delegation; the host performs final verification after you return.
- Make any permitted direct edits, report the required reviewer-edits block, and return
  the terminal verdict promptly.
EOF
}

# Codex-only, and deliberately NOT part of write_canonical_recall_contract below:
# that function's text is byte-identical across the codex, agy and qwen drivers
# (test-review-drivers.sh asserts it), while `[$name](mcp://name)` is Codex's own
# mention syntax and means nothing to the other two. It is emitted only for a
# --canonical-recall round: in a default round every MCP call is refused by the
# approval policy anyway, so naming the server would only buy a pointless wait.
# Why a mention at all: header, --canonical-recall.
#
# The mention makes the server READY; it does not make its tools VISIBLE. Codex code
# mode DEFERS MCP tools: they are omitted from the exec tool's description and reachable
# only through ALL_TOOLS and `tools.*` (codex-rs/code-mode-protocol description.rs,
# "Some deferred nested tools may be omitted from this description"). The first wording
# here said "Its tools are in your catalog … If you still cannot see them, say so", and
# S2's R02 code round (2026-09-19, session 01a0b9f7) did exactly that: Codex had waited
# for the server, the reviewer never ran ALL_TOOLS, and it replied "Canonical-index MCP
# was unavailable in the callable catalog". So the note names where the tools are and
# the one check that decides availability. It must stay ABOVE the diff (both call sites
# are): an oversized diff pushes the prompt past the model's window and Codex compacts
# the middle of the message away.
write_canonical_recall_mention() {
  [ "$CANONICAL_RECALL" -eq 1 ] || return 0
  local tool_prefix="mcp__${CANONICAL_RECALL_MCP_SERVER//-/_}__"
  cat >> "$PROMPT_FILE" <<EOF

Canonical-index MCP for this round: [\$${CANONICAL_RECALL_MCP_SERVER}](mcp://${CANONICAL_RECALL_MCP_SERVER})
Codex finished starting that server before this turn. Its tools are DEFERRED: they are NOT
listed in your exec tool's description, and they ARE callable. Find them inside exec with
  text(ALL_TOOLS.filter(x => x.name.startsWith("${tool_prefix}")).map(x => x.name));
and call them there, e.g. await tools.${tool_prefix}search_specs({query: "...", limit: 5}).
Only an empty result from that filter, or a failed call, means the index is unavailable; a
tool list that does not show them is not evidence of absence.
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

# Optional round context from the implementer (what changed since Codex's last verdict, and the
# checks this round must settle). The code phase writes it ABOVE the diff and the verdict line:
# appended after them, a round's named checks were read last and lost to "review ONLY the diff"
# (2026-10-21: A2ORIGIN passed in 100 s with no edits, its hardest checks "outside this scoped review").
write_round_context() {
  if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
    printf '\n--- ROUND CONTEXT FROM THE IMPLEMENTER ---\n' >> "$PROMPT_FILE"
    cat "$CONTEXT_FILE" >> "$PROMPT_FILE"
  fi
}

if [ "$PHASE" = "plan" ]; then
  cat > "$PROMPT_FILE" <<EOF
You are the REVIEWER in a coreview "shellrev" loop. The IMPLEMENTER (another agent) wrote
the plan at: $PLAN
Read that plan IN FULL. This is PHASE 1 (plan convergence) — review the PLAN ONLY.

Your job, as a tough but fair peer:
- Verify load-bearing claims in the plan (file:line references, named symbols) with read-only
  checks against the repo at $REPO. Flag anything unverifiable or wrong.
- Pressure-test the approach: missing edge cases, wrong abstraction, risky steps, scope gaps.
- MANDATE: directly implement EVERY plan issue you can fix yourself by editing the plan file
  (you run with $SANDBOX) — structural gaps included, not just wording. Never hand back a
  fixable issue for the implementer to apply. Reserve a description-without-a-fix ONLY for
  genuine judgement calls / design decisions the author must make, or user arbitration. A
  "$VERDICT_CHANGES" verdict MUST still carry your own plan edits for everything that was fixable.
- TAG every edit you make so the implementer reviews it: (1) inline in the plan, append
  " [reviewer: <reason>]" on or beside each changed line; (2) in your reply, list every
  edit under a block headed exactly:
      REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:
  as "file:line — what changed + why" (write "... : none" if you made no edits).
  Never silently revert or rewrite the author's intent.
- Do NOT edit any source code in this phase. The plan file is the only artifact you may touch.
EOF
  write_conventions
  write_execution_constraints
  write_canonical_recall_mention
  write_canonical_recall_contract
  cat >> "$PROMPT_FILE" <<EOF

End your reply with EXACTLY ONE of these two lines, on its own line, nothing after it:
VERDICT: $VERDICT_PLAN_GO        (only when the plan is sound enough to implement)
VERDICT: $VERDICT_CHANGES        (when anything still needs to change — list the specifics above)
EOF
  write_round_context

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
  # Compute the diff and INLINE it (do not make Codex go explore for it — that, plus
  # session-memory recall, is what made this drown without ever emitting a verdict).
  # Size is judged ONCE, on the whole rendered prompt, in the preflight below. (A
  # 600,000-byte "diff is large; review may be slow" warning used to sit here: an
  # unmeasured threshold whose message understated the real consequence. Removed
  # 2026-09-19 in favour of the measured window report.)
  CODE_DIFF="$(git -C "$REPO" diff "$BASE" 2>/dev/null)"
  revshell_require_code_diff codex-review.sh "$BASE" "$REPO" "$CODE_DIFF"
  cat > "$PROMPT_FILE" <<EOF
You are the REVIEWER in a coreview "shellrev" loop (PHASE 2: implementation review).
Review the unified diff at the END of this message, and settle every check named in the
ROUND CONTEXT FROM THE IMPLEMENTER above it, if there is one. The diff is the COMPLETE change set
(base $BASE -> working tree of $REPO). Plan context: $PLAN.

HARD CONSTRAINTS — follow these or the review is useless:
- Do NOT broadly explore or grep the repository, and do NOT recall or reference past
  sessions or other repositories. Judge THIS diff on its own and answer promptly.
- You MAY open at most a couple of specific changed files in $REPO for surrounding
  context if strictly needed, plus the specific files and targeted commands a check named
  in the ROUND CONTEXT needs — but default to the diff; do not go hunting.
- Be concise. List each finding as: file:line - issue (CRITICAL/HIGH/MEDIUM/LOW). Then
  report each check named in the ROUND CONTEXT as: check - PASS / FAIL / INCOMPLETE
  (reason), with brief evidence. "$VERDICT_SHIP" requires every named check to PASS.
- MANDATE: directly implement EVERY finding you can fix mechanically yourself, by editing
  source in $REPO (sandbox: $SANDBOX) — structural fixes included, not just one-liners. Never
  hand back a fixable finding for the implementer to apply. Reserve a description-without-a-fix
  ONLY for items that genuinely need architectural judgement the author must make, or user
  arbitration. A "$VERDICT_CHANGES" verdict MUST still carry your own self-fixes for everything
  that was mechanically fixable.
- SEVERITY RULE: a LOW or MEDIUM finding is presumed mechanically fixable — it MUST arrive as an
  applied edit, not a description. EVERY finding you return without an edit must carry one line
  "not self-fixed because: <genuine architectural judgement / user arbitration / needs shell>".
  If you can describe the exact change, you can make it — make it.
- TAG every source edit you make so the implementer reviews it before it lands: list each one
  in your reply under a block headed exactly:
      REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:
  as "file:line — what changed + why" (write "... : none" if you made no edits). Do NOT add
  marker comments into source — keep it clean; your edits + git diff are the record.
- Do not push, merge, or rebase — landing is the host's job.

Find real correctness bugs, regressions to existing callers, convention violations, or
missing tests IN THIS DIFF.
EOF
  write_conventions
  write_execution_constraints
  write_canonical_recall_mention
  write_canonical_recall_contract
  write_round_context
  cat >> "$PROMPT_FILE" <<EOF

End your reply with EXACTLY ONE line, on its own line, nothing after it:
VERDICT: $VERDICT_SHIP
VERDICT: $VERDICT_CHANGES

=== UNIFIED DIFF (base $BASE) ===
EOF
  printf '%s\n' "$CODE_DIFF" >> "$PROMPT_FILE"

else
  echo "codex-review.sh: --phase must be 'plan' or 'code' (got '$PHASE')" >&2
  exit 2
fi

# ---- prompt-size preflight (added 2026-09-15, measured) ---------------------
# `codex exec` refuses a single input above 1,048,576 CHARACTERS at turn/start
# ("Input exceeds the maximum length of 1048576 characters. (code -32602)"),
# after the round has been launched and waited on. Measured twice on 2026-09-14/15:
# a --base that swept in large generated review logs produced a 2,052,450-char
# prompt. Refuse before dispatch, naming the size and the usual cause, so the
# caller narrows the diff instead of discovering it from the provider.
#
# The SAME check also REPORTS -- never refuses -- a prompt larger than the reviewer's
# context window (2026-09-19). Codex dispatches such a prompt, then auto-compacts the
# conversation and drops the MIDDLE of the message. Measured on S2's R02 code round
# (session 01a0b9f7): 279,536 input tokens against a 258,400 window; the compacted user
# message kept 284,969 of 802,880 chars ("tokens truncated" at char 144,039) and the
# review ran on what was left. Report-only by the coordinator's ruling (the coordinator,
# 2026-09-19): "A review that sees less than its diff must SAY so loudly; it must not be
# blocked or silently continued."
#
# Tokens are ESTIMATED from characters at the LOWER of the two measured ratios, so the
# estimate errs high: 2.87 chars/token is R02's 802,880 prompt chars -> 279,536
# first-request input tokens (a count that includes Codex's own instructions, which
# makes the ratio more conservative still). Code measured 3.78 (756,843 -> 200,459,
# session 01a0ba0b).
CODEX_CHARS_PER_TOKEN_MEASURED="2.87"
# The window is Codex's own figure for the model: context_window x
# effective_context_window_percent in ${CODEX_HOME:-~/.codex}/models_cache.json
# (gpt-5.6-sol/terra, gpt-6-astra on 2026-09-19: 272,000 x 95% = 258,400, the
# model_context_window Codex reported for R02). Used when the model or the cache
# cannot be read -- that same measured figure.
CODEX_CONTEXT_WINDOW_FALLBACK_TOKENS=258400
CODEX_INPUT_CHAR_CAP=1048576
PROMPT_CHARS=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8", errors="replace").read()))' "$PROMPT_FILE")
if [ "$PROMPT_CHARS" -gt "$CODEX_INPUT_CHAR_CAP" ]; then
  echo "codex-review.sh: REFUSING before dispatch -- the rendered review prompt is $PROMPT_CHARS characters; codex exec refuses more than $CODEX_INPUT_CHAR_CAP per input." >&2
  echo "codex-review.sh: the usual cause is a --base that includes large generated files (review logs, measurement dumps); pass a --base closer to the change, or review in smaller slices." >&2
  exit 2
fi
# Prints "<estimated tokens> <window tokens> <where the window came from>".
read -r PROMPT_TOKENS_EST REVIEW_WINDOW_TOKENS REVIEW_WINDOW_SOURCE < <(python3 - \
    "$PROMPT_CHARS" "$CODEX_CHARS_PER_TOKEN_MEASURED" "$CODEX_CONTEXT_WINDOW_FALLBACK_TOKENS" \
    "${CODEX_HOME:-$HOME/.codex}" "$MODEL" <<'PY'
import json, math, os, sys
chars, ratio, fallback, home, model = int(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
window, source = fallback, "fallback-constant"
try:
    if not model:
        import tomllib
        with open(os.path.join(home, "config.toml"), "rb") as fh:
            model = str(tomllib.load(fh).get("model", ""))
    with open(os.path.join(home, "models_cache.json"), encoding="utf-8") as fh:
        models = json.load(fh).get("models", [])
    entry = next((m for m in models if isinstance(m, dict) and m.get("slug") == model), None)
    if entry and entry.get("context_window"):
        window = int(entry["context_window"] * entry.get("effective_context_window_percent", 100) / 100)
        source = f"models_cache.json:{model}"
except Exception:
    pass
print(math.ceil(chars / ratio), window, source)
PY
)
REVIEW_WINDOW_REPORT=""
if [ "$PROMPT_TOKENS_EST" -gt "$REVIEW_WINDOW_TOKENS" ]; then
  REVIEW_WINDOW_REPORT="DIFF EXCEEDS THE REVIEWER'S WINDOW (~$PROMPT_TOKENS_EST tokens > $REVIEW_WINDOW_TOKENS): Codex will compact it and the middle will go unreviewed. Split the diff."
  echo "codex-review.sh: $REVIEW_WINDOW_REPORT" >&2
  echo "codex-review.sh: (estimate: $PROMPT_CHARS prompt chars / $CODEX_CHARS_PER_TOKEN_MEASURED chars per token; window from $REVIEW_WINDOW_SOURCE) -- dispatching anyway; this is a report, not a refusal." >&2
fi

# ---- run codex exec (blocking, non-interactive) ------------------------------
# Only pass -m when a model override is set; otherwise inherit Codex's config default.
MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=(-m "$MODEL")
# Reasoning effort is forced per-invocation via -c, so the user's global
# model_reasoning_effort is neither read nor written for review rounds.
EFFORT_ARGS=()
[ -n "$EFFORT" ] && EFFORT_ARGS=(-c "model_reasoning_effort=$EFFORT")
revshell_make_invocation_id "codex" "$PHASE"
REVIEW_INVOCATION_ID="$REVSHELL_CURRENT_INVOCATION_ID"

# State the round's mode as the first line of this invocation's log, before the
# "reviewer started" line revshell_run_with_timeout emits next — so a transcript
# always shows whether this round had canonical-index (MCP) recall or not.
if [ "$CANONICAL_RECALL" -eq 1 ]; then
  revshell_log "$REVIEW_INVOCATION_ID" "canonical-recall: ENABLED — running codex exec --approve-for-me (MCP tool calls allowed; sandbox forced to workspace-write [workdir, /tmp, \$TMPDIR], approval on-request; -s/--sandbox not passed); the prompt names [\$$CANONICAL_RECALL_MCP_SERVER](mcp://$CANONICAL_RECALL_MCP_SERVER) so this turn waits for that server to finish starting instead of sampling with an empty catalog"
else
  revshell_log "$REVIEW_INVOCATION_ID" "canonical-recall: disabled (default) — running codex exec -s $SANDBOX -c approval_policy=$APPROVAL_POLICY; MCP tool calls will fail with 'MCP tool call requires approval, but approval policy is never'"
fi

# No Codex plugins in a review round (2026-10-22). The account's remote Firebase plugin started
# `npx firebase-tools@latest mcp` in every round: an npm registry check, 2-5 s of CPU and ~120 MB
# for a server no reviewer calls, nine copies alive at once that morning. Measured with codex-cli
# 0.163: these two switches stop it, and the [mcp_servers] in ~/.codex/config.toml (the canonical
# recall servers) still start. the owner, same day: "why does firebase use cpu or batteru?".
PLUGIN_ARGS=(--disable remote_plugin --disable plugins)

set +e
if [ "$CANONICAL_RECALL" -eq 1 ]; then
  revshell_run_with_timeout "$REVIEW_INVOCATION_ID" "$TIMEOUT" codex exec \
    -C "$REPO" \
    --skip-git-repo-check \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} \
    "${PLUGIN_ARGS[@]}" \
    --approve-for-me \
    -o "$LAST_MSG" \
    - < "$PROMPT_FILE" > "$REVIEW_OUT"
else
  revshell_run_with_timeout "$REVIEW_INVOCATION_ID" "$TIMEOUT" codex exec \
    -C "$REPO" \
    --skip-git-repo-check \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} \
    "${PLUGIN_ARGS[@]}" \
    -s "$SANDBOX" \
    -c "approval_policy=$APPROVAL_POLICY" \
    -o "$LAST_MSG" \
    - < "$PROMPT_FILE" > "$REVIEW_OUT"
fi
RC=$?
set -e
# The runtime buffers the round and emits it only when it ends, so routing that emission
# through a file and printing it here changes nothing a caller sees.
cat "$REVIEW_OUT"

if [ "$RC" -eq 124 ]; then
  echo "codex-review.sh[$REVIEW_INVOCATION_ID]: codex exec timed out after ${TIMEOUT}s" >&2
  exit 4
elif [ "$RC" -ne 0 ]; then
  echo "codex-review.sh[$REVIEW_INVOCATION_ID]: codex exec failed (exit=$RC)" >&2
  exit 5
fi

# ---- did a --canonical-recall round actually call the index? (report-only) ------
# `codex exec` prints one "mcp: <server>/<tool> …" progress line, at the start of a line,
# for every MCP call it makes. A round with none never queried the index, whatever its
# reply says about recall. Measured 2026-09-19: S2's R02 printed no such line and replied
# "Canonical-index MCP was unavailable in the callable catalog", and nothing said so.
# Reported on stderr and above the verdict; the round is never failed for it (the
# coordinator's ruling, the coordinator, 2026-09-19: report, don't gate). Anchored at line
# start so a diff echoed in the output ('+'/' ' prefixed) cannot fake a call.
RECALL_BLIND_REPORT=""
if [ "$CANONICAL_RECALL" -eq 1 ] && ! grep -q "^mcp: ${CANONICAL_RECALL_MCP_SERVER}/" "$REVIEW_OUT"; then
  RECALL_BLIND_REPORT="canonical recall requested but the round ran WITHOUT the index (no \"mcp: ${CANONICAL_RECALL_MCP_SERVER}/\" line in its output) -- treat its recall claims as unverified; re-run it if recall mattered."
  revshell_log "$REVIEW_INVOCATION_ID" "$RECALL_BLIND_REPORT"
fi

# ---- parse + normalize the verdict from the last message ---------------------
VERDICT_LINE="$(grep -ioE "VERDICT: *(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" "$LAST_MSG" | tail -1 || true)"
if [ -z "$VERDICT_LINE" ]; then
  # Fall back to a bare sentinel anywhere in the last message.
  BARE="$(grep -ioE "(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" "$LAST_MSG" | tail -1 || true)"
  [ -n "$BARE" ] && VERDICT_LINE="VERDICT: $BARE"
fi
[ -z "$VERDICT_LINE" ] && VERDICT_LINE="VERDICT: ${VERDICT_CHANGES} (no explicit verdict parsed — treat as not converged)"

echo
# Report-only findings about the round itself, repeated here beside the verdict so a
# caller that keeps only stdout still sees them.
[ -z "$REVIEW_WINDOW_REPORT" ] || echo "codex-review.sh: $REVIEW_WINDOW_REPORT"
[ -z "$RECALL_BLIND_REPORT" ] || echo "codex-review.sh: $RECALL_BLIND_REPORT"
echo "==== codex-review verdict (phase=$PHASE, model=${MODEL:-config-default}, effort=${EFFORT:-config-default}) ===="
echo "$VERDICT_LINE"
exit
}
