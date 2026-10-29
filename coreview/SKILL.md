---
name: coreview
description: "COREVIEW — one cross-model plan + implementation review loop shared by Claude, Codex and Gemini (single source of truth). Two agents share one on-disk plan file: an IMPLEMENTER (writes plan then code) and a REVIEWER. The user picks mode + who implements + who reviews UPFRONT, then it runs end-to-end and finishes autonomously (reviewer audit → commit on dev/test, no push → save learnings). Three modes: 'coreview' (both sides may write to correct each other), 'coreviewlight' (reviewer only STEERS; implementer writes everything), and 'shellrev' (one session: Claude implements and drives an in-shell REVIEWER via blocking subprocess calls through the revshell skill — default backend Codex; owner: revshell/SKILL.md, “Reviewer backend selection” — no second session, no watcher). Use when the user says coreview / coreviewlight / shellrev / claudereview, 'have <agent> review this', 'iterate with <agent>', 'review this in shell', after writing a plan and wanting a second-model pass, or asks to monitor committed code. Only stop mid-loop for a question needing USER arbitration."
---

# COREVIEW — cross-model plan + implementation review (role- and runtime-neutral)

This is the **single common file** for `coreview`, shared by Claude Code, Codex and Gemini CLI
(each runtime's skill dir symlinks this repo's `coreview/` directory — Claude `~/.claude/skills/`,
Codex `~/.codex/skills/`, Gemini `~/.gemini/config/skills/`). The protocol is
identical everywhere; only the background-watcher mechanism and agent-dispatch tool differ per
runtime — see **`scripts/TOOLS.md`** and the Runtime tool mapping section below.

Two agents collaborate over **one on-disk plan file**. Markers in that file + a background
watcher are the only handoff channel. The two roles are:

- **IMPLEMENTER** — owns the **first write**: writes the plan (Phase 1), then writes the code
  (Phase 2). In `coreviewlight` the implementer writes *all* code, every round.
- **REVIEWER** — reviews the plan and the code. In **regular `coreview`** the reviewer may *also
  write* corrections directly (to the plan and to the code). In **`coreviewlight`** the reviewer
  **only steers** (findings/instructions) and never edits source.

The agent in whose CLI this skill is invoked is the **HOST / orchestrator**: it owns the watcher,
the shell, and the autonomous finish sequence. The other agent is the **COUNTERPART**, driven by
the user in a separate session. The host may be the implementer or the reviewer depending on the
upfront choice — the protocol is symmetric because the counterpart reads this exact same file.

## TL;DR — read before anything else (NON-NEGOTIABLE)

1. **First, do the Upfront setup** (below): mode, who implements, who reviews, commit target, temp
   branch. This is the ONLY sanctioned interactive pause. The user's answer is the **authorization**
   to run end-to-end.
2. **Both phases are MULTI-ROUND loops.** `complete` ends a *turn*, not a *phase*. A phase ends only
   when the **reviewer's** sentinel contains the terminator (Phase 1: `ready for implementation`;
   Phase 2 / ship: `ready to ship`).
3. **Every round:** do the work → append your marker at the file FOOTER via
   `scripts/append-marker.sh` → confirm the watcher is alive (re-arm if dead) → send a one-line
   status (`Plan: <path> — marker @ <ts>. Counterpart's turn.`) → STOP and wait.
   **Codex exception:** Codex `exec_command` PTY sessions are pull-only, not monitors. Codex as
   IMPLEMENTER must run `scripts/watch_reviewer.py "$PLAN"` after appending its marker; that script
   exits immediately if a reviewer marker is already below the latest implementer marker. Do not
   rely on an ad-hoc background watcher. If any watcher is left as an ongoing session, Codex MUST
   poll it before every user-visible status/final response.
4. **Run to completion.** Do NOT stop and ask the user for confirmation at convergence. At ship
   convergence, execute the **Finish sequence** autonomously: land curated commits on dev/test, delete
   the temp branch, save ONE memory commit — then **hand the user the commit list to decide** push/promote/merge
   (the agent never pushes or promotes). The ONLY mid-loop stop is a question that genuinely needs
   **user arbitration** (a product/scope call the counterpart cannot settle) — and even then, **keep the
   monitor armed** (do not kill the watcher).

> **`shellrev` mode overrides points 2–3's mechanics:** there is no second session, no marker, and no
> watcher — the host implements and drives the reviewer via blocking subprocess calls through
> the standalone **`revshell`** skill. Points 1 (upfront setup) and 4 (run to completion + Finish
> sequence) still apply. See **Mode: `shellrev`** below.

## Upfront setup — establish roles once, then run uninterrupted (NON-NEGOTIABLE)

On invocation, before arming any watcher, confirm these five things. If the user already stated
them ("coreviewlight, Gemini implements, I review, land on dev"), proceed without re-asking. If any
is missing, ask ONCE (a single grouped question), then run end-to-end.

| Decision | Options | Default if unstated |
|---|---|---|
| **Mode** | `coreview` (both correct each other) / `coreviewlight` (reviewer steers only) / `shellrev` (Claude implements, an in-shell REVIEWER reviews — default backend Codex; owner: revshell/SKILL.md, “Reviewer backend selection”; single session, no watcher) | infer from the trigger word; else `coreview` |
| **Implementer** | Claude / Codex / Gemini | the host runtime |
| **Reviewer** | Claude / Codex / Gemini (the other one) | the counterpart |
| **Commit target** | `dev` / `test` | `dev` |
| **Temp branch** | the branch/worktree the work lives on | the current feature branch |

**`shellrev` shortcut:** in shellrev the roles are fixed — **Claude is host + implementer, an in-shell REVIEWER is driven via the revshell skill** (default backend `codex`; see revshell/SKILL.md → "Reviewer backend selection") — so the Implementer/Reviewer rows are pre-answered. There is also no counterpart session and no watcher to arm. Only **commit target** and **temp branch** remain to confirm. If the user said "shellrev" with a target, proceed with zero further questions.

Bind your own role from this before touching the plan file:

- **Host is REVIEWER:** do not seed an implementer plan/marker. Read the counterpart's plan or
  implementation, append a `review:` verdict (`ready for implementation`, `changes requested`, or
  `ready to ship` as appropriate), then arm the watcher that waits for the **implementer's** next
  marker. This is the normal "Codex reviews Claude/Gemini" shape.
- **Host is IMPLEMENTER:** write/refine the plan or code, append an `impl:` marker, then arm the watcher
  that waits for the **reviewer's** next verdict.

Either way the host owns the watcher + finish.

## Roles, the single-stop rule, and never killing the monitor

- The host runs the loop autonomously once roles are set. It does the work for its own role, drives
  the watcher, and at convergence performs the Finish sequence — **no "should I commit?" prompt**.
- **The only sanctioned mid-loop stop** is a question that *must* be arbitrated by the **user**, not
  the counterpart — e.g. "the plan and the original commit disagree about whether feature X should
  exist at all" (a product decision), or "this change would touch client data / a protected branch
  in a way the plan didn't anticipate". Mechanical disagreements are resolved between the two agents
  via the plan file, NOT escalated.
- **When you do escalate, do NOT kill the watcher.** Surface the question, keep the `Monitor`/watcher
  armed, and resume the loop the moment the user answers. Killing the monitor to ask a question is the
  failure this rule prevents.

## Runtime tool mapping

Bind the abstract steps below to your host runtime using **`scripts/TOOLS.md`**. Summary:

- **Claude Code:** arm watchers with the `Monitor` tool running `bash scripts/<phaseN>-watcher.sh "$PLAN"`
  (`persistent: true`, `timeout_ms: 3600000`) — NEVER `Bash run_in_background` (its stdout is buffered
  to a file the harness won't surface as notifications). Dispatch agents with the `Agent` tool.
- **Codex as REVIEWER:** run `scripts/watch_plan.py` as a blocking waiter for the implementer's next
  marker. Use `--phase plan --after-latest-review` during Phase 1 plan review and
  `--phase implementation --after-latest-review` during Phase 2/code review. If launched as an
  `exec_command` PTY session, Codex must poll the session with `write_stdin` before any status/final
  response; the session is not a push notification channel.
- **Codex as IMPLEMENTER:** use `scripts/phase1-watcher.sh <plan>` while waiting for a Phase 1 reviewer
  verdict, then use `scripts/watch_reviewer.py <plan>` after every implementation/fix marker. Do not
  use `watch_plan.py` to wait for a reviewer verdict; it watches implementer markers and can complete
  on your own marker. Do not hand-roll regex watchers. If any watcher runs as a Codex PTY session,
  poll it before every status/final response.
- **Gemini:** background-exec the same `*.sh` (or `watch_plan.py`) and poll; dispatch with its sub-agent
  mechanism.

All watcher scripts match BOTH the canonical role lexemes (`impl:`/`review:`) and the legacy runtime
lexemes (`claude:`/`codex:`), so mixed/in-flight plans keep working.

## Marker wire protocol

The plan file's footer carries the machine-readable handoff. Lines are role-tagged:

- **Implementer:** `<!-- impl: <status> @ <iso8601> - <note>[ - <trigger>] -->` + `<!-- impl-detail: <narrative> -->`
- **Reviewer:** `<!-- review: <verdict> @ <iso8601> - <note> -->` + `<!-- review-detail: <narrative> -->`

(Legacy plans use `claude:` for the implementer line and `codex:` for the reviewer line; the watchers
honor both. New markers should use the role lexemes.)

Status blocks (the `<!-- ... -->` header that precedes each side's lines):

| Block | Owner | Phase |
|---|---|---|
| `coreview-plan-status` (legacy alias `codexreview-status`) | either side, Phase 1 | plan convergence |
| `coreview-impl-status` | implementer | Phase 2 code handoff |
| `coreview-review-status` | reviewer | Phase 2 verdict |
| `coreviewlight-impl-status` | implementer | light kickoff/fix |
| `coreviewlight-fix-status` | implementer | light fix round |
| `coreviewlight-review-status` | reviewer | light steering verdict |

**Trigger phrases** (case-insensitive; watchers also accept the legacy forms in parentheses):
- Implementer → reviewer handoff: **`ready for review`** (legacy: `ready for Coreview review` / `ready for Claude review`).
- Reviewer → implementer (light fix request): **`ready for fixes`** (legacy: `ready for Codex fixes`).
- Phase 1 terminator (reviewer): **`ready for implementation`**.
- Ship terminator (reviewer): **`ready to ship`** (also `ship it`, `ready_to_ship`).
- Reviewer non-terminator: `changes requested`.

### Marker hygiene — always use `scripts/append-marker.sh` (NON-NEGOTIABLE)

```
bash scripts/append-marker.sh "$PLAN" <impl|review> <block-tag> <status-or-verdict> "<trigger-or-empty>" "<verdict note>" "<detail note>"
```

For `impl`, `<status-or-verdict>` is normally `complete` or `partial`.
For `review`, `<status-or-verdict>` MUST be the actual reviewer sentinel parsed by watchers:
`ready for implementation`, `changes requested`, or `ready to ship` (plus implementation-review
legacy forms only when already in use). Do not write `review: complete ... - ready for implementation`;
some watchers require the verdict immediately after `review:`.

The script fixes two real stall modes:
- **Real `date -u` timestamp.** Some runtimes disable `Date.now()`/`new Date()`, tempting a hand-typed
  ISO time that lands *earlier* than the counterpart's last verdict — the symmetric watcher then reads
  your marker as stale and the loop silently stalls. The script stamps the real shell clock and warns
  if it is not strictly after the counterpart's last verdict.
- **Exactly ONE live trigger.** Each round appends a fresh marker; the script neutralizes the trigger
  phrase in all *prior* lines of your role so the counterpart's watcher can't latch onto an older copy.

**Append at the FOOTER, never edit an earlier block in place.** Symmetric counterparts watch the file
footer; an in-place edit to an earlier block is invisible to them and stalls the loop (burnt v6.7.13
round 2, 2026-05-28). Each new marker goes BELOW the other side's latest block.

**ONE canonical marker file — never split the handoff (NON-NEGOTIABLE, 2026-06-19).** All sentinel
markers (both roles, all phases) live in the SINGLE plan file you pass to the watcher. If the work
references or spawns OTHER documents (a design file, a sibling spec), the markers STILL go in that one
canonical plan file — reference the other doc by path inside the marker/detail; do not move markers into
it. Splitting the handoff (e.g. the design and its review land in file B while the watcher is armed on
file A) silently misses the counterpart's turn — this exact miss happened on 2026-06-19 (a Pass-1 design
review landed in a sibling spec the watcher wasn't watching). If a loop genuinely MUST carry markers in
more than one file, pass EVERY such file to the watcher: all watchers now accept multiple plan paths
(`phase1-watcher.sh <a> <b> …`, `phase2-watcher.sh <a> <b> …`, `watch_plan.py <a> <b> …`,
`watch_reviewer.py <a> <b> …`). Prefer the single canonical file; multi-file is the safety net, not a
license to scatter markers. (Do NOT use the deprecated `coreviewlight-watcher.sh`; it now warns and still
runs, but the phase / `watch_*.py` watchers are canonical.)

**`partial` vs `complete`:** use `complete` only when the full scope of the handoff is done; use
`partial` for any intermediate state (some streams done, a per-round fix subset, a committed-SHA
handoff). The trigger phrase stays on the line either way; only the status word changes.

## The system-reminder IS the round signal (NON-NEGOTIABLE)

During an active loop, any host `<system-reminder>` saying the plan file "was modified, either by the
user or by a linter" **is the counterpart taking its turn** (the wording is generic; in this skill the
modifier is always the counterpart). On such a reminder:

1. **Read the plan to the END** (use the file length; the visible diff is often truncated near the
   bottom where the sentinel block lives).
2. Compare the counterpart's sentinel timestamp against the last one you saw. If it advanced → your turn.
3. **Never reply "awaiting the counterpart's round N" when a reminder shows the file changed** — the
   modification *is* round N. Respond with the review/fix.

The system-reminder is the **earliest, strongest** signal; the watcher is a fallback. If a reminder
shows a truncated diff, ALWAYS `Read` the full file before changing any watcher protocol.

## Hollow-seed diagnostic — run on every invocation

A plan handed to you may already contain `ready for implementation` / `ready to ship` at the footer,
self-seeded with zero real review rounds. Detect it:

```bash
grep -c '<!-- \(impl\|claude\): complete @' "$PLAN"
```

If this is `0` but a terminator line is present, it is a **hollow seed** — no implementer round ran, so
no real review could have happened. Do NOT treat it as convergence. Instead: do a genuine round-1
review, fold findings into the plan, **neutralize the hollow seed** (rewrite that terminator line to a
non-terminator note — paraphrase, don't quote the trigger, or the watcher's pre-check false-fires),
append your real round-1 marker, arm the watcher, and proceed.

---

## Mode: regular `coreview` — both sides may correct each other

Two phases over the one plan file. **Implementer owns the first write each phase.** In this mode the
reviewer is not limited to requesting changes — it MAY directly edit the plan (Phase 1) or the code
(Phase 2) to fix things, and the implementer may push back / re-edit. Disagreements resolve via the
plan file; only genuine user-arbitration questions escalate.

### Phase 1 — plan convergence (plan only, never code)

1. Implementer writes the plan to the agreed path. **No source edits, no mutating git in Phase 1** —
   the plan file is the only artifact touched.
2. Append a `coreview-plan-status` marker (impl side, no special trigger needed for Phase 1) and arm
   the Phase 1 watcher (`scripts/phase1-watcher.sh`).
3. Each round: read the counterpart's edits in full, verify load-bearing `file:line` claims with
   read-only checks, accept / refine / push-back **as edits to the plan file** (no silent reverts —
   leave a one-line reason), append your marker at the footer, keep the watcher armed.
4. Be a tough peer: no reflexive agreement, no reflexive disagreement, verify claims, time-box style
   ties. Either side may rewrite weak sections directly.
5. **Phase 1 ends only when the reviewer's line says `ready for implementation`.** A bare matched-content
   convergence without that phrase is NOT a green light — keep iterating.

On `ready for implementation`: stop the Phase 1 watcher and **transition to Phase 2 immediately** (the
upfront choice pre-authorized this — no confirmation prompt). On Claude as host, call `ExitPlanMode`
before dispatching implementation agents (plan mode otherwise blocks sub-agent source edits).

### Phase 2 — implementation review (both may correct code)

1. Implementer executes the converged plan — **dispatch parallel sub-agents, one per work stream** (the
   default pattern), not sequential inline work.
2. Verify each agent's changes actually landed (`git diff` per worktree — sub-agent Edits can silently
   no-op), run focused tests + build per stream.
3. Append a `coreview-impl-status` marker (impl side) with the **`ready for review`** trigger, then arm
   the Phase 2 watcher (`scripts/phase2-watcher.sh`).
4. Reviewer reviews the worktree diff(s) — launching its own review sub-agents per stream — and
   **directly implements every finding it can fix mechanically itself** in code, noting each
   correction in the plan; it requests changes (`changes requested`) only for items needing the
   author's architectural judgement or user arbitration, and even then still lands its own fixes
   for everything mechanically fixable. Implementer addresses feedback (agents for non-trivial
   scope, direct edits for 1–3 mechanical files), re-verifies, appends its next marker.
5. **Review rounds never create commits** (2026-07-18): fixes are working-tree edits. If a
   cross-merge reviewer genuinely needs a committed tip, keep at most ONE local WIP checkpoint per
   worktree and refresh it with `git commit --amend` — never one per round, never pushed, and squashed
   into the approved commits before the Finish merge.
6. Iterate until the reviewer's line says **`ready to ship`** → go to the **Finish sequence**.

Hard rules: no push / no merge to integration branches / no rebase of shared history *during* Phase 2
(those belong to the Finish sequence). Respect user overrides on any finding. Re-verify silent-no-flush
after every Edit.

---

## Mode: `coreviewlight` — reviewer steers only; implementer writes everything

The reviewer **never edits source** — not the initial build, not fixes, not via code-editing sub-agents.
The implementer writes ALL code (initial build + every fix round). The reviewer's job is the plan +
rigorous review + steering instructions. This REPLACES Phase 2 (it can follow a converged Phase 1 plan
or run standalone from a brief).

### Flow

1. The plan is finalized (implementer owns it; reviewer may have refined it in a Phase 1 pass). The
   implementer implements every stream.
2. Implementer appends a `coreviewlight-impl-status` (or `-fix-status`) marker with the **`ready for
   review`** trigger.
3. The reviewer (host, in the usual light setup) arms `scripts/coreviewlight-watcher.sh` — scoped to the
   implementer's tail-most line, no auto-terminator (the reviewer decides ship).
4. **Reviewer reviews — REVIEW ONLY.** `git diff` the worktree, then **dispatch cheap full-code
   verification agents** (standing rule below) + focused tests. Append a `coreviewlight-review-status`
   marker: `changes requested` (with the **`ready for fixes`** steering trigger and the specific findings)
   → implementer iterates; or `ready to ship` → go to the Finish sequence.
5. Loop until the reviewer writes `ready to ship`.

**Standing rule — always verify with cheap agents over the FULL code (NON-NEGOTIABLE).** Both at the
initial implementation check and every review round, dispatch cheap (e.g. Haiku) sub-agents with narrow
questions ("does this break any existing caller of X across the repo?", "is every user-facing string
routed through `t()`?") rather than eyeballing the diff in isolation. RESTATE the project's coding
conventions verbatim in each agent prompt and add "grep your own findings before reporting". Fan out in
parallel. Reviewing only the local diff misses cross-file regressions; the full-code sweep is what makes
review-only safe.

**Escape hatch (user-gated):** if the implementer fails to resolve the SAME blocker across 3 consecutive
rounds, the reviewer MAY take over that one fix — but ONLY after asking the user and getting an explicit
OK (this is a genuine user-arbitration stop; keep the monitor armed). Log the takeover in the review block.

**coreviewlight anti-patterns:** reviewer silently fixing code "because it was faster"; reviewing without
the full-code agents or without `git diff`-confirming the implementer's edits landed; editing an earlier
block in place; treating `changes requested` as terminal.

---

## Mode: `shellrev` — single session, an in-shell REVIEWER (delegates to the `revshell` skill)

`shellrev` collapses the two-session protocol into ONE autonomous host session: the host is
implementer, and the reviewer is invoked synchronously as a **blocking subprocess** each
round — no second human session, no marker dance, **no background watcher**; the subprocess
return *is* the handoff.

**The shellrev mechanism is its own standalone skill — `revshell` — which owns the hardened
drivers, the backend-selection order, and the shared review contract.** Do not duplicate any
of that here.

> **"Blocking subprocess" means BLOCKING IN YOUR OWN TURN — it does NOT mean a plain
> foreground Bash call.** A Bash call is capped at 600s and a round runs 250–3000s, so the
> harness auto-backgrounds a naive foreground invocation. Launch the round detached to a
> unique log, then block with `bash <revshell-skill-dir>/scripts/await-log.sh "$LOG"` (a
> foreground Bash call, tool `timeout: 600000`), **re-issuing it on exit 10 until it exits
> 0**. Never hand the wait to `Monitor` or `run_in_background` and end your turn: a
> background-completion notification does not wake a subagent, and four measured sessions
> were lost that way. Full mechanics and evidence: revshell/SKILL.md → TOP RULE.

**REQUIRED SUB-SKILL:** Use the **`revshell`** skill. **Its default driver is
`<revshell-skill-dir>/scripts/codex-review.sh`** (resolves from the host runtime's own skills
dir, e.g. `~/.claude/skills/revshell`) — see revshell/SKILL.md → "Reviewer backend selection"
for the full order (Codex → agy → Qwen). Run `--phase plan` until `ready for
implementation`, then implement (working tree only — no per-round commits; at most one
amendable WIP) and run `--phase code --base "$(git merge-base <target> HEAD)"` until
`ready to ship` → **Finish sequence**. The same contract (inline diff, no exploration/recall,
`file:line` findings, terminal `VERDICT:`) applies no matter which backend is reviewing.
Re-verify any reviewer-written fix (`git diff` + focused tests). The convergence guard,
Phase-1 discipline, Finish sequence, and no-push/no-promote guardrail are unchanged.

---

## Finish sequence — autonomous, shared by all modes (NON-NEGOTIABLE)

Triggered when the reviewer's verdict reaches **`ready to ship`**. The upfront agent selection is the
authorization — **execute this end-to-end without a confirmation prompt.** The HOST orchestrates; the
REVIEWER role performs the final audit gate.

1. **Reviewer's final-audit gate — dispatch parallel agents** (one per scope: server/runtime, client/UI,
   shared/lib, deploy/config, tests, security) to:
   a. **Audit the FULL code** that landed (read the changed files + their call paths/config/tests — not
      just the diff hunks), against the project's coding conventions.
   b. **Correct if needed** — apply fixes for any real issue found (in regular mode directly; in light
      mode the implementer applies them — but the audit still runs before landing). Re-verify with
      `git diff` + focused tests after each fix.
   c. **Evaluate cross-commit compatibility** — check the work against *other* commits / uncommitted work
      in the checkout: does it conflict with, duplicate, or break anything already on the target branch or
      in sibling worktrees? Inspect `git log --oneline <target>..HEAD`, `git status` in the checkout, and
      any in-flight branches the plan touches. Surface integration risks; resolve mechanical ones, escalate
      only genuine product conflicts.
   If the audit finds blockers, loop back (request fixes, re-review) — do NOT land broken or incompatible
   code. Land only once the audit is clean.
2. **Curate, then land on the main checkout (dev or test), NO push.** First shape the temp branch into
   its final APPROVED commits — squash all WIP/checkpoint/round noise
   (`git reset --soft $(git merge-base <target> <temp>)`, then commit coherent units); messages describe
   the change, never the review process. Then use `scripts/finish.sh`:
   ```
   bash scripts/finish.sh --repo <main-checkout> --target <dev|test> --temp-branch <name> [--squash] --message "<msg>"
   ```
   The script enforces the guardrails: target must be `dev`/`test` (never `main`/`master`/a production branch),
   re-verifies the branch in the same call, refuses review-process subjects (`wip`/`checkpoint`/`revshell`/
   `codex round`; `--allow-noisy` only for a user-approved exception), merges the temp branch into the
   target, and **never pushes**. Production promotion stays with your dedicated promote flow — do not trigger it here.
3. **Delete the temp branch.** `finish.sh` deletes it (safe `-d`; `--force-delete` only for a confirmed
   squash-merge whose content you've verified landed).
4. **Save the session's final summary as ONE memory commit.** One concise note — GOAL, RESOLUTION,
   LEARNINGS (what the loop converged on, surprises, anti-patterns, the outcome):
   ```
   bash scripts/save-learnings.sh --repo <main-checkout> --slug <kebab-slug> --title "<title>" \
       --description "<one-line hook>" --body-file <note.md> [--type feedback|project|reference]
   ```
   It auto-detects the project's store (`internal/agents/memory/` + an npm `memory:index` script when present;
   `internal/memories/`; any `*/memory/` with a `MEMORY.md`; creates one if missing), writes the
   note + index line, refreshes the vectors, and **commits the store as exactly one `docs(memory):` commit**
   on the target branch (docs-only — the sanctioned exception to "never commit directly on the base branch";
   `--no-commit` to opt out). This is the session's ONLY memory commit — never sprinkle `docs(memory)`
   commits through the loop. Save only what is non-obvious and won't rot.
5. **Hand the user the commit list to decide.** This is the final deliverable. Present:
   - the commits that landed (`finish.sh` prints `git log --oneline <base>..HEAD` for the target branch, plus
     how far ahead of `origin/<target>` it now is),
   - the deleted temp branch and the saved memory note,
   - any cross-commit / integration observations from step 1c.
   The agent has already committed, checked checkout compatibility, and saved — but **push, promotion
   (your promote flow), and any further merge are the USER's call, made from this commit list.** Do NOT push or
   promote. Then stop the watcher (loop fully closed).

---

## Stopping the watcher

Stop the active watcher ONLY when:
- The Finish sequence has fully completed (work landed + branch deleted + learnings saved), OR
- The user abandons the loop ("stop", "never mind", "let's do something else"), OR
- You're pivoting to an unrelated task.

**Never stop the watcher to ask a user-arbitration question** (keep it armed and resume on the answer).
Leaking watchers between sessions wastes file descriptors and confuses the next loop — but a quiet watcher
during a long idle gap is normal, not a reason to stop.

## Quick-reference flow

```
User: "coreview" (or coreviewlight / shellrev)
  ↓
Upfront setup: mode + implementer + reviewer + commit target + temp branch  (the ONE pause)
  (shellrev: implementer=Claude, reviewer=in-shell backend pre-set (Codex default, see revshell); only target + branch to confirm)
  ↓
Phase 1 (regular & shellrev): implementer writes plan → reviewer corrects via plan-file edits
  → loop until reviewer: `ready for implementation`
  ↓
Phase 2 / light loop: implementer writes code (parallel agents)
  regular:  reviewer reviews + directly implements every fixable finding; implementer addresses feedback  (watcher)
  light:    reviewer steers only; implementer applies every fix                   (watcher)
  shellrev: Claude implements; `codex-review.sh` blocking call per round (the reviewer fixes directly,
            see revshell/SKILL.md) (NO watcher)
  → loop until reviewer: `ready to ship`
  ↓
Finish (autonomous, host-driven):
  1. reviewer dispatches agents → full-code audit + fixes + cross-commit compatibility
  2. curate temp branch → approved commits only (no wip/checkpoint/round subjects)
  3. finish.sh → merge into dev/test in main checkout (NO push) + delete temp branch
  4. save-learnings.sh → goal/resolution/learnings as ONE docs(memory) commit + vectors
  5. hand the user the COMMIT LIST to decide push/promote/further-merge; stop watcher
```

If the user abandons the loop at any point, stop the watcher (shellrev: just stop looping) and exit cleanly.

## Notes

- **Process-only.** This skill does not specify the plan's *content* — only the loop, the handoff
  protocol, and the autonomous finish. It applies to any plan-shaped task (code, infra, debugging, writing).
- **Symmetric.** The counterpart reads this same file via its own symlink, so both sides agree on markers,
  blocks, triggers and finish. There is no separate "Codex prompt" or "Gemini prompt" to maintain.
- Editing the skill itself needs no target-project worktree — commit skill changes in this repo normally.
  The *target project* is where the temp branch, commit, and memory live.
- Hardened watcher logic (tail-most extraction, codex-detail-in-signature to emit on same-verdict rounds,
  block-anchored Phase 2 scoping, `$0` capture) lives in `scripts/*.sh` and `scripts/watch_plan.py` —
  call the scripts, never re-inline the awk.
