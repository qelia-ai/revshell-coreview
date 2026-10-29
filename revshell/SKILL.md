---
name: revshell
description: "REVSHELL — single-session in-shell review gate. The host agent implements a change, then drives a REVIEWER as a blocking subprocess to review the diff BEFORE it lands. BLOCKING MEANS IN-TURN: launch the round detached to a unique log, then block on it with scripts/await-log.sh (a foreground Bash call, tool timeout 600000) and RE-ISSUE it on exit 10 until it exits 0 — never hand the wait to Monitor or run_in_background and end your turn, because a background-completion notification does not wake a subagent and four measured sessions were lost that way (2026-08-16/17/19/20). TOP RULES (2026-08-08): (1) the host is barred from using an API key itself — no curl/SDK model call of its own — but MAY load and drive subscription-backed agents, which is what every backend below is; (2) the reviewer EDITS BY DEFAULT and fixes its own findings — every backend is edit-capable, agy included (driven with --mode accept-edits since 2026-09-18). ONE shared review contract used by every backend — Codex (DEFAULT as of 2026-07-28, ChatGPT SUBSCRIPTION not an API key, via scripts/codex-review.sh), agy (first fallback, via scripts/agy-review.sh, Gemini on its own subscription, edit-capable via --mode accept-edits), Qwen Code (second fallback, via scripts/qwen-review.sh, the regular in-shell `qwen` CLI with edit rights — no Ollama path implied; hosted/off-machine depending on the user's own Qwen config, still gated by scripts/confidentiality-guard.sh), a Claude review subagent — so review logic is never forked. No second human session or cross-session handoff watcher: the subprocess return IS the handoff. Use when the user says revshell / shellrev, 'review this in shell', 'have agy review this', wants a one-session implement-then-review loop, or as the review gate consumed by other skills (a project fix-gate, coreview's shellrev mode). Review rounds never create commits; approval lands curated commits merged to dev, deletes the temp branch, and ends with ONE memory commit. ONE ROUND WHEN BOTH SIDES AGREE (the owner, 2026-08-16): if the host accepts the reviewer's edits on inspection and no finding is left open, the round is over and it lands — never re-run the reviewer to confirm its own accepted edits, and never ask the user to confirm an agreement that already exists; a second round is for DISAGREEMENT only."
---

# revshell — in-shell review gate (shared, model-agnostic)

## TOP RULE — DRIVE AGENTS, NEVER CALL AN API YOURSELF (the owner, 2026-08-08)

**revshell and internal dev work may use SUBSCRIPTION-billed model access only. Never
API-metered (pay-per-token) access.** This holds across this whole skill, every workflow
that consumes it, every repo, every agent.

**The differentiator is how the tokens are invoiced** — not which vendor answers, not
whether a credential exists in the chain, and not whether something is loosely "an API".
Ask: *is this invoiced per token, or covered by a flat subscription?* Same vendor, different
billing = different answer. `codex` and Qwen Code are **agent shells on subscriptions**, and
are fully allowed here:

- **ALLOWED — loading an agent.** Spawn a CLI agent or subagent that is signed in on its
  own plan and manages its own model access. All four backends qualify and all four stay
  available:
  - `codex` (Backend C) — ChatGPT subscription (`~/.codex/auth.json`:
    `auth_mode: "chatgpt"`, no `OPENAI_API_KEY`).
  - **Qwen Code (Backend B) — subscription plan, and allowed even though the CLI
    authenticates with a plan key.** That key is the agent's own credential, not yours;
    it does not make Qwen an API backend. (Its off-machine egress limits still apply —
    see Backend B and `scripts/confidentiality-guard.sh`.)
  - `agy` (Backend A) — Gemini on its own subscription.
  - A Claude subagent in the host session (Backend D).
  - The default order below is unchanged.
- **BANNED — you holding the key.** Never make a model call with an API key yourself: no
  `curl` to an inference endpoint, no `openai`/`anthropic`/`google-genai` SDK call, no
  script you write that reads `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `DASHSCOPE_API_KEY`,
  `BAILIAN_*` or any equivalent to get a model to answer. Wrapping it in a helper script
  or handing it to a subagent does not launder it.
- **A project may be stricter.** A product repo's `CLAUDE.md` golden rule bars model APIs for
  internal work *including* dispatching API-backed reviewers/evaluators — obey the
  stricter project rule there. This machine-wide rule is the floor, not the ceiling.
- Rationale: subscription agents are already paid for and are the intended tool; a raw API
  call is unbudgeted spend and an egress decision that is the owner's to make, not yours.

## TOP RULE — YOU BLOCK ON THE ROUND, IN YOUR OWN TURN. A NOTIFICATION WILL NOT WAKE YOU.

**This is the single most common way a revshell session loses its work.** Measured on four
separate days — 2026-08-16 (six agents), 08-17 (five), 08-19 (two), and the night of
08-19/20 (**seven occurrences in one session, one agent twice; ~713k tokens burned with
nothing committed**). Restating "don't do that" has failed three times, so this section now
states the MECHANICS and hands you a command that cannot go wrong.

### Why the obvious advice does not work (read this — it is what traps everyone)

1. **A Bash tool call cannot outlive its timeout.** Default 120s, hard maximum 600000 ms
   (10 min). A real review round runs **250–3000s**. When the timeout expires the harness does
   not fail your call — it **moves your command to the background** and hands you a task id
   (`Command did not complete within its 120s timeout and was moved to the background (ID: …)`).
   So "just run the reviewer in the foreground and block on it" is **not available to you** for
   any round longer than 10 minutes. The harness backgrounds it whether you meant to or not.
2. **An unconditional foreground `sleep` may be refused.** Measured verbatim: `Blocked: sleep 30
   followed by: echo done. To wait for a condition, use Monitor with an until-loop … To wait for
   a command you started, use run_in_background: true. Do not chain shorter sleeps to work around
   this.` **Both alternatives that message names will end your turn.**
3. **`Monitor` instructs you, in its own tool result, to stop working:** *"You will be notified on
   each event. Keep working — do not poll or sleep."* An agent whose only remaining work IS the
   review has nothing left to keep working on — so it ends its turn. The trap is baited, and
   agents who were explicitly told to drive the reviewer synchronously still walked into it.
4. **Ending your turn is not "pausing". For a subagent it is FINISHING — and the notification
   does not come.** Measured on this machine 2026-08-19/20: of 42 subagent transcripts, 11
   started background tasks and **not one was ever re-entered by a background-task completion
   notification.** One agent waited on task `b39sotnlt`; that task exited cleanly at 18:52 having
   written `VERDICT_APPEARED` to its output file. The agent never saw it, and had to be woken by
   hand with everything uncommitted. **This is a platform semantic, not a bug you can out-argue:
   plan around it.**

### THE PATTERN — copy this, do not improvise

**Step 1 — launch the round DETACHED yourself**, to a log path unique to your invocation, so the
harness's timeout is not what decides its fate:

```bash
LOG=$(mktemp -t revshell-<area>.XXXXXX)          # NEVER a shared /tmp/qwen-review.log
nohup bash <revshell-skill-dir>/scripts/qwen-review.sh \
      --plan "$PLAN" --phase code --repo "$REPO" --base <ref> --timeout 0 \
      >"$LOG" 2>&1 &
echo "round started pid=$! log=$LOG"
```

**Step 2 — block on it with `await-log.sh`, as an ordinary FOREGROUND Bash call, in the SAME
turn, with the tool `timeout` set to `600000`:**

```bash
bash <revshell-skill-dir>/scripts/await-log.sh "$LOG"
```

**Step 3 — read its exit code and act, still in the same turn:**

| exit | meaning | what you do |
|------|---------|-------------|
| `0`  | verdict present, tail printed | consume it; audit `git status`/`git diff` for reviewer edits |
| `10` | still running (not an error) | **re-issue the exact same command, now.** Repeat as often as the round needs |
| `11` | log stopped growing, no verdict | round looks dead — audit the tree for edits it already made, then re-run or land unreviewed and say so |
| `12` | **the round never started** — the launcher exited on its own arguments | fix the launch command and relaunch. NOTHING ran, so unlike 11 there are no reviewer edits to audit |
| `2`  | bad usage / no log | fix the path |

### MEASURED 2026-08-20 — a launch that fails on arguments looks exactly like a slow reviewer

A round was launched without `--plan`. `codex-review.sh` printed
`codex-review.sh: --plan is required`, wrote 36 bytes, and exited instantly. No codex
process ever existed. `await-log.sh` then polled that inert file for ~6.5 minutes, and
would have polled for 7 (`STALL=420`) before exit 11 — because a log that never grows is
ALSO what a reviewer thinking hard about a large diff looks like, and the script could not
tell them apart.

**`await-log.sh` now fast-fails this in ~20s (exit 12):** past 20s, a log under 4KB whose
text matches `is required|usage:|unknown option|no such file|command not found|invalid
option/argument` is reported as a launch failure, with the log's contents printed.

Two habits that make this self-correcting, and you should keep both:
- **Check the log has GROWN before you settle into waiting.** A round that has produced
  nothing after ~30s did not start. Real rounds write within seconds.
- **`--plan` is REQUIRED by `codex-review.sh`.** Write the plan to a file first; a review
  launched without it never runs. Full shape:
  `bash ~/.claude/skills/revshell/scripts/codex-review.sh --plan <path> --phase code --repo <ABSOLUTE worktree path> --base <sha> --model gpt-5.6-sol --effort high`

Why this matters beyond the lost minutes: exit 11 tells you to audit the tree because a dead
round MAY have made edits. Exit 12 tells you the opposite — nothing ran, nothing changed —
and conflating them sends you auditing a tree nobody touched.

`await-log.sh` returns at 510s **by design** — under the 600s tool ceiling — precisely so the
harness can never background it. Exit 10 is the normal case on a long round: you will re-issue it
three, five, six times. **That is the correct behaviour, not a stall.** Six re-issued waits and a
consumed verdict beats one elegant Monitor and a lost session.

Why a script rather than an inline loop: it is condition-guarded (the form the sleep guard's own
message endorses), it keeps `sleep` out of the tool's command string entirely so no guard
heuristic can refuse it, and it polls the **review log** — not the poller's own output file, which
is empty until the poller exits and told one agent nothing at all.

### THE ANTI-PATTERN — name it so you can catch yourself

You are doing the broken thing the moment you are about to write any of these:

> *"I'll continue once the background poll notifies me…"* · *"I'll wait for the `bXXXXXXXX`
> background task to notify completion."* · *"I'll stop checking manually and wait for the
> notification."* · *"I'll pause here and wait for the Monitor's notification."* · *"Nothing else
> productive to do until then, so I'll wait."*

All five are verbatim from agents that lost their work. **If your next sentence ends your turn
while something you started is still running, you are about to lose everything you built.**
There is no "productive use of the wait" — the wait IS your work. Block on it.

**This covers ANY background work, not just review rounds** — a backgrounded `vitest` run, a
build, a deploy, a log tail. The 2026-08-17 recurrence included an agent that parked on a
background *test run* with 218 tool calls of finished work behind it, having never been near a
reviewer. `await-log.sh` takes any log and any marker regex:
`bash …/await-log.sh "$LOG" 510 'passed|failed|error'`. If you started it and you are waiting on
it, you block on it yourself.

**If the harness backgrounds something on you anyway** (you forgot the `timeout`, or a command
overran), you have NOT lost it: the task keeps writing to
`…/tasks/<id>.output`. Point `await-log.sh` at that file and carry on in-turn. Never conclude a
round did not happen because the process table is empty — a finished review has already exited.

### Non-negotiable trimmings

- **A unique log per invocation, and confirm the output is yours.** Independent hosts run rounds
  concurrently; several agents on one machine will otherwise pick the same obvious path and read
  each other's review. Measured 2026-08-17: an agent polling a colliding log read a *different*
  agent's verdict, about files it had never touched, and nearly acted on it. Use
  `$(mktemp -t revshell-<area>.XXXXXX)` or embed the branch name — never a bare
  `/tmp/qwen-review.log`.
  - Before trusting a verdict, check it actually discusses **your** files. A verdict naming
    modules outside your diff is someone else's round, not a surprise finding.
  - Cross-check with `git status` / `git diff --stat` in your own worktree: if the reviewer
    supposedly edited files you never touched, you are reading the wrong log.
- **An empty process table does NOT mean "no review ran."** A finished review has already exited.
  Read the log before concluding anything.
- **A timeout with no verdict does NOT mean nothing happened — the reviewer edits by default, so
  its edits may ALREADY be in your working tree.** Audit `git status` / `git diff` before assuming
  a clean slate, and `git log` for a commit it made on its own.
- If you genuinely run out of patience, **COMMIT ANYWAY** and say plainly in your report that the
  branch landed unreviewed. That is an acceptable, visible outcome. Stalling silently with
  uncommitted work is not — it is the one failure mode that loses everything.

## RULE — REVIEWS RUN IN THE BRANCH'S OWN WORKTREE, EDIT-CAPABLE, BEFORE THE MERGE (the owner, 2026-09-15)

the owner, 2026-09-15, verbatim: *"send all your new commits as they land to qwen for
review"*, and on being shown a scheme that rebuilt each change in a throwaway tree:
*"no no make qwen review and edit directly your worktrees without duplication. change
revhsell and your code"*.

**The rule: a review happens in the worktree the branch already lives in, with edit
rights, before the branch merges. No second checkout, no scratch tree, no applying a
patch into a synthetic copy and transplanting the result back.**

Three reasons it is better, not merely shorter:
- **Reviewer edits land ON THE BRANCH**, where the next commit is made, instead of in a
  copy someone then has to move.
- **The review happens before the merge**, which is what a review is for. The backlog that
  provoked this ruling was eleven branches already merged into `dev` unreviewed.
- **One tree per package means nothing to reconcile.** A review copy can drift from the
  branch, and then the reviewed bytes are not the merged bytes.

**Seeing a COMMITTED branch.** `qwen review run` with no target reads the WORKING TREE
diff, so a finished branch — clean tree, all work committed — shows it nothing. The route
that works is this skill's own `--phase code` drivers: they compute
`git -C <worktree> diff <base>` (base → working tree, committed work included) and EMBED
THE COMPLETE UNIFIED DIFF IN THE PROMPT. Pass `--base` the fork point
(`git merge-base <branch> dev`) so the reviewer sees the branch's whole change and none of
the base branch's. Never soft-reset a branch to manufacture a working-tree diff: the
worktree may belong to a live agent, and HEAD would sit at the base for the length of the
round.

**Reading back what the reviewer did is then free.** The branch's own work is committed,
so the worktree is clean when the round starts; anything dirty when it ends is the
reviewer's edits, exactly. Refuse to start on an already-dirty worktree — those changes
belong to whoever is working there, the reviewer would edit over them, and afterwards they
would be indistinguishable from its own.

### RULE W-1 — NO AGENT EVER RUNS A DESTRUCTIVE GIT COMMAND IN A WORKTREE IT DID NOT CREATE

`git checkout -- .`, `git restore .`, `git reset --hard`, `git clean -fd`, `git stash`
(already banned here), `git worktree remove` — **none of them, in anyone else's tree, for
any reason, including tidiness.** Not to clear reviewer edits you have already landed
elsewhere, not to leave things neat for the next agent, not because the tree "should" be
clean.

**Evidence, 2026-09-15 (a product repo):** a review host finished eleven rounds, transplanted the
kept edits onto a follow-up branch, and then swept the reviewed worktrees with
`git checkout -- .` so nobody would find a dirty tree. **Fourteen paths of another agent's
uncommitted work were discarded by a cleanup loop whose whole purpose was tidiness** —
about thirty minutes of live work: eight `.py` files, two test files, three regenerated
goldens. Unstaged content that was never `git add`ed leaves no git object, so `fsck`
recovers nothing.

**A DIRTY WORKTREE BELONGING TO SOMEONE ELSE IS NOT A MESS TO CLEAN. It is work in
progress, and dirty is the NORMAL state of an agent that is working.** "The worktree was
dirty" is never a safe signal to act on. The only correct actions are to leave it alone,
or to ask its owner.

**The deletion is not the worst of it.** The owner's own account: the sweep landed
mid-edit and *"left a tree that looked coherent"* — the prompt fragment reverted while the
regenerated goldens had not yet been touched, so for a window the fragment documented two
values and the goldens rendered three, **and nothing failed**. A commit inside that window
would have shipped a prompt whose contract and whose render disagreed. A destructive sweep
does not merely delete work; it can manufacture a consistent-looking inconsistency no test
is watching for.

**W-1b — THE REVIEWER'S OWN EDITS ARE REMOVED BY THE OWNER OF THAT WORKTREE, OR NOT AT
ALL.** Transplanting the keeps to a follow-up branch is right; sweeping afterwards is the
error. A worktree left dirty with reviewer edits is its owner's to resolve — and their
dirty tree refusing the next round is a FEATURE, not a problem to clear. Land your keeps
where they belong, TELL THE OWNER what is sitting in their tree and why, and leave it to
them.

The clean-tree check above guards the START of a round and guards nothing after it: a
round runs ten to twenty minutes, and the package's own agent can come back at any point
inside that window — which is exactly what happened. W-1 is the other half, and it is a
RULE AN AGENT READS, not a mechanism. *(A guard that detected and refused such commands
was written and deleted the same night: a tool that refuses is a GATE, and a gate is
the owner's to admit — never something a review host grants itself, however good
the reason.)*

**The constraints that ride along, unchanged:** the reviewer is dispatched edit-capable and
never comment-only; qwen has NO SHELL under `--approval-mode auto-edit` (the tool is
dropped from its registry) and is NEVER told to run a command — whatever it cannot verify,
the brief GIVES it, as test names, assertion text and command output; **the host runs the
tests and makes the commit**, and a reported green suite is never believed; every reviewer
edit is READ and REFUSED with the reason named where it contradicts a ruling in the brief
(a new deterministic gate, an i18n layer, a policy claim the project's own `CLAUDE.md`
contradicts); and **model-facing text — prompts, guide rules, principle rows, field
descriptions a model reads — is never edited by a reviewer**, it is flagged, because it
lands only with the owner's line-by-line assent.

A product repo's driver for this pattern is `scripts/review_branch_with_qwen.sh`, whose reviewer
prompt is the authored file `scripts/qwen_review_brief.md`.

## RULE — FINDINGS COME BACK AS EDITS, NEVER AS A TO-DO LIST (the owner, 2026-08-19)

The reviewer runs in EDIT MODE and the contract MANDATES it fix everything it can. The
host absorbing a findings list and re-implementing it is the failure mode this gate
exists to remove — it spends host time and tokens doing the reviewer's job twice.

- A LOW/MEDIUM mechanical finding returned WITHOUT an applied edit is a contract
  violation by the reviewer, not work for the host. Send it BACK: re-run ONE round with
  `--context` containing the unfixed findings and the line "apply these yourself as
  edits now; return only what genuinely needs the author's judgement." (This bounce-back
  round is NOT the disagreement round — one-round-when-both-sides-agree is about
  verdicts, not about a reviewer that skipped its own mandate.)
- The host implements a reviewer finding itself ONLY when it is a genuine architectural
  judgement call or a user-arbitration item, and the report labels it as such
  ("host-implemented judgement call: <what>").
- Measured 2026-08-19 (a product repo): a clean, proxy-routed, auto-edit round returned "one
  MEDIUM worth closing at the root, plus a LOW" as descriptions and the host implemented
  both by hand. The LOW was the reviewer's to fix by definition; the MEDIUM's mechanical
  part was too. The drivers now warn on this signature in the post-round audit.

revshell is the standalone, **shared** review mechanism. The host (the agent in whose
session this runs) implements a change, then gates it through a REVIEWER before landing.
The reviewer runs as a **blocking subprocess in the same session** — its return is the
handoff. There is no second human-driven session or cross-session file watcher.

This is its own skill on purpose: project fix-gate skills and coreview's `shellrev` mode
both consume it. One hardened driver + one review contract that every backend — agy, Qwen
Code, Codex, a Claude subagent — uses, never a second, forked review implementation.

## MEASURED 2026-08-19 — the fallback cascade can walk you into a BANNED backend

**What happened:** five agents in one product session reached their review gate.
`codex` failed in seconds (`You've hit your usage limit… try again at Aug 20th
8:50 AM`). They fell back to `agy`, which failed in seconds too (`Individual
quota reached. Resets in 82h41m`). **`agy-review.sh` then printed
`fall back to qwen-review.sh`** — and qwen is exactly the backend this skill
bars for confidential repos. `confidentiality-guard.sh` said
`preflight OK (remote+path clean, no credential patterns)` and a complete diff
of confidential business data streamed to a hosted endpoint before the round
was killed at 97s.

**The agents did not disobey.** They followed the documented order. The
documented order terminates at the one backend that must not be used there.

**Why the guard missed it:** check A greps `git remote -v` against the
confidential-remote pattern. The repos had moved to personal remotes, so the
org-based patterns no longer matched, and check B only covered one path root
while the worktree sat elsewhere. **Fixed the same day:** the remote pattern
now also matches the repository NAME, which covers every git worktree too
since worktrees inherit remotes (verified: blocked with exit 6 for the repo
and its worktrees, allowed with exit 0 for unrelated repos). **Revised
2026-10-06:** the owner lifted the block on one of the two repos ("remove the
ban", "for good"; "the ban is about sending confidential data to
qwen. here we are merely reviewing code, which was never banned to start with").
Code of that repo may go to hosted Qwen; confidential data (mail, client
records, credentials) never does.

**Two rules follow from this:**

1. **When both subscription backends are quota-dead, the answer is Backend D
   (a Claude review subagent) — never the qwen tail of the cascade.** Say so
   out loud when you pick it.
2. **A guard that PASSES is not permission.** Ownership moves; allow-lists keyed
   to an old identity silently invert from protecting to permitting, and nothing
   announces it. If you have not personally checked the remote, do not treat
   `preflight OK` as authority.

## MEASURED 2026-08-19 — Backend D delivered five for five, and it was not a rubber stamp

With codex and agy both quota-dead all day, every gate ran as an in-session
Claude subagent. Across five independent diffs it found, and in most cases
self-fixed:

- a **live `sid` leaking into an exception message** — `requests`/urllib3 embeds
  the failed URL in its error text and the `frontdoor.jsp` hop carries the raw
  session id; a redaction test already existed and passed, because it used a
  synthetic message containing no sid;
- a **CRITICAL exit-code gap**: an implementer changed a gate decline from
  exit 1 to exit 0, and three call sites still trusting the exit code alone
  would have reported a WITHHELD Legal notification to the operator as *sent*;
- **two idempotency bugs**, one of which turned on `"x-draft"` being a literal
  string prefix of `"x-draft-failed"`, so a single transient failure would have
  convinced every later run the mail was already sent;
- a leaked `{{detail}}` i18n placeholder, verified empirically against i18next;
- a shared helper left un-navigated after a caller's navigation was removed.

Practical shape that worked: pass the diff as a **file path** (not inlined),
tell it to verify empirically rather than speculate, confine probe scripts to
the scratchpad, and budget 2–3 rounds on safety-critical diffs.

## ROOT-CAUSED 2026-08-20 — why "just block on it" kept failing

The stall recurred a fourth time on the night of 2026-08-19/20: **seven occurrences in one
session, one agent twice, ~713k tokens spent and never committed.** Several of those agents had
been told explicitly, in their brief, to drive revshell synchronously — and still ended up
parked. That is the tell that the instruction was not the problem.

Root cause, established from the transcripts (evidence is quoted in the TOP RULE above):

- **(b) harness semantics, and they cannot be argued with.** A Bash call is capped at 600s while
  a round runs 250–3000s, so the harness **auto-backgrounds** the reviewer no matter what the
  agent intended; the sleep guard refuses an unconditional foreground wait and names `Monitor` /
  `run_in_background` as the alternatives; `Monitor` then instructs *"Keep working — do not poll
  or sleep"*; and a subagent that ends its turn is **finished**, not paused. Across 42 subagent
  transcripts, 11 started background tasks and **zero** were ever re-entered by a completion
  notification. The agents were not disobeying — the mechanism was inviting it.
- **(a) a documentation defect sitting on top of it.** This skill's own rule said "run the round
  in the FOREGROUND and block on it", which the harness makes **impossible** for a round over ten
  minutes. An instruction that cannot be followed gets improvised around, and every improvisation
  ended in the same trap.

**Fixed 2026-08-20** by making the achievable pattern the only one written down:
`scripts/await-log.sh` — a condition-guarded, in-turn blocking wait that always returns *below*
the tool ceiling so the harness can never background it, and that says "RE-ISSUE THIS NOW, do not
end your turn" in its own exit-10 output. See the TOP RULE at the top of this file.

## CANONICAL RECALL — the reviewer/implementer has the project's index MCP only if you ask for it (2026-08-27 codex; 2026-08-29 qwen + codex-implement)

Measured 2026-08-29 on a product repo, all three shells probed against `acme-agent-index`:

- **codex** — `codex exec -s … -c approval_policy=never` (the default review/implement
  invocation) REFUSES every MCP call ("MCP tool call requires approval, but approval
  policy is never"). `codex exec --approve-for-me` succeeds. So: `codex-review.sh
  --canonical-recall` (08-27) and `codex-implement.sh --canonical-recall` (08-29) run
  `--approve-for-me` instead of `-s`; both are mutually exclusive with an explicit
  `--sandbox`. Trap: `codex exec` with the prompt as an ARGUMENT blocks forever on a
  non-TTY stdin ("Reading additional input from stdin…") — pipe the prompt (`- <
  file`) or redirect `< /dev/null`, as the drivers do.
- **qwen** — two independent switches, both off by default: (1) `--safe-mode`
  unloads every MCP server ("SAFE MODE — all customizations disabled (hooks,
  extensions, skills, MCP servers, QWEN.md)"); (2) a headless round DECLINES any MCP
  tool call unless the server entry in `~/.qwen/settings.json` carries `"trust":
  true` ("requires user approval but cannot execute in non-interactive mode" — the
  `-y` it suggests is the banned yolo mode). `qwen-review.sh --canonical-recall`
  drops `--safe-mode`; the trust flag is set with `qwen mcp add --trust -s user
  <name> <command> serve` (re-add; `qwen mcp add` has no update). The index launcher
  is inert unless the round's cwd is a worktree of the indexed repo.
- **`codex-implement.sh --canonical-recall` is NOT enough on its own (measured 2026-08-29,
  WP-F):** the session runs in a `git clone --shared` whose git common dir is not the
  primary's, and a repo-local launcher that guards "serve only inside this repo" by
  comparing common dirs (a product repo's does) refuses there — codex reports canonical recall
  unavailable and falls back to committed docs. The flag removes the approval refusal;
  the clone still defeats the launcher. Owed fix: under `--canonical-recall`, run the
  session in a `git worktree` of the source repo instead of a clone (same sandbox
  isolation — workdir-scoped — and the branch already lives in the primary's refs, so
  the fetch-back step disappears). Until then, the IMPLEMENTER is recall-blind and the
  REVIEWER round (`codex-review.sh`/`qwen-review.sh --canonical-recall`, run in a
  worktree) is where recall happens — the wrapper brief says so.
- **codex: `--approve-for-me` makes the MCP CALLABLE, not READY (measured 2026-09-19).**
  Codex >= 0.147 starts optional MCP servers in the background with a one-second
  startup grace and omits any server still pending from the step's tool catalog
  (openai/codex#35742). `acme-agent-index serve` needs 5.7-7.1s to answer
  `initialize`, so a `--canonical-recall` round whose model checked its catalog early
  saw NO index tools (`ALL_TOOLS.filter(/acme/)` -> `[]` at +7.3s and +8.9s, two
  rounds that day) and reported "the canonical-index MCP was unavailable" — while the
  log line said ENABLED. Codex waits for a server the user text names as
  `[$name](mcp://name)`, so both codex drivers now emit that line under
  `--canonical-recall` (server id: `COREVIEW_CANONICAL_RECALL_MCP_SERVER`, default
  `acme-agent-index`; must match `codex mcp list`). Verified: with it, all seven
  tools are in `ALL_TOOLS` at the first action and `search_specs` returns a record;
  without it, same flags and worktree, `ALL_TOOLS` has none. `test-review-drivers.sh`
  fails if the line is dropped.
- **codex: READY is not VISIBLE (measured the same day, S2's R02 code round, session
  01a0b9f7, 704 KB diff).** Code mode DEFERS MCP tools: they are absent from the exec
  tool's description and reachable only through `ALL_TOOLS` / `tools.*`. That round's
  Codex had waited for the server (first request at +6.4s vs +2.1-3.8s without the
  mention), but the reviewer never ran `ALL_TOOLS` and replied "Canonical-index MCP was
  unavailable in the callable catalog" — the first recall note had told it the tools
  were "in your catalog" and to "say so" if it could not see them. The note now names
  where they are (`ALL_TOOLS.filter(x => x.name.startsWith("mcp__<server>__"))`, called
  as `tools.mcp__<server>__search_specs(...)`) and says only an empty filter or a failed
  call means unavailable. It sits above the diff, which matters: that round's prompt was
  279,536 tokens against a 258,400 window, and Codex compacted the middle of the message
  away. Tried and NOT effective on 0.154.0: `-c
  features.code_mode.direct_only_tool_namespaces=[...]` (both `mcp__acme_agent_index__`
  and `mcp__acme-agent-index__`) left the tools deferred. If a round still reports the
  index unavailable, first check whether it ran the filter; then whether server startup
  exceeded Codex's default 10s `startup_timeout_sec` (headroom 1.4x at load 16) —
  measure before raising anything.
- **codex-review.sh REPORTS two ways a round can see less than it should (2026-09-19,
  report-only by the coordinator's ruling — never a refusal, never a failed round).** Both print
  on stderr and again on stdout just above the verdict line:
  - `DIFF EXCEEDS THE REVIEWER'S WINDOW (~N tokens > W): Codex will compact it and the
    middle will go unreviewed. Split the diff.` — from the one prompt-size preflight
    (which still REFUSES above Codex's 1,048,576-char input limit). N = prompt chars /
    2.87 (R02's measured ratio, the conservative one: code measured 3.78, so a code-heavy
    prompt near the line can be flagged while it still fits). W = context_window x
    effective_context_window_percent from `$CODEX_HOME/models_cache.json` for the round's
    model, else 258,400 (that same figure for gpt-5.6-*). R02 would have read ~279,750 >
    258,400; its real count was 279,536 and Codex compacted away the middle of its diff.
    The old unmeasured 600 KB "diff is large; review may be slow" warning is gone.
  - `canonical recall requested but the round ran WITHOUT the index` — a --canonical-recall
    round whose output has no line starting `mcp: <server>/` never called the index,
    whatever its reply says. Checked on the day's real logs: R02 and the first plan round
    (both blind) have none; r02b / r04 / rc2 have 4, 4 and 10.
- The round's first `[revshell:…]` log line states `canonical-recall: ENABLED |
  disabled` so a transcript shows which mode ran. A product repo's `AGENTS.md` and the
  global dispatch rule require recall for any review that judges "does an existing
  mechanism cover this" — pass the flag for those rounds and say so in the report.
  ENABLED is the driver's configuration, not proof of recall: the reviewer's own reply
  is — a round that says the MCP was unavailable ran blind whatever the log line says.
- `scripts/test-review-drivers.sh` is green as of 2026-09-19 (the old qwen
  prompt-capture failure noted here was fixed by the stub's `-p` handling).

## Reviewer backend selection — read this before picking a backend

**Default order when the user states no preference: `codex` → `agy` → Qwen Code, full stop.**
(Unchanged by the 2026-08-08 TOP RULE — all three are subscription-backed agents you
*drive*, which is exactly what that rule permits.)

- **`codex` is the default reviewer backend** (Backend C, `scripts/codex-review.sh`),
  restored 2026-07-28 by the owner ("go back to using codex for revshell"), superseding the
  2026-07-27 instruction that had demoted it. Use it unless the user asks for a specific
  different backend. It runs on the ChatGPT subscription, not an API key.
- **If `codex` is unavailable** (not on PATH, or the invocation itself fails) **fall back to
  `agy`** (Backend A, `scripts/agy-review.sh`, Gemini-backed), then to **Qwen Code**
  (Backend B, `scripts/qwen-review.sh`).
- **Qwen Code means the regular in-shell `qwen` CLI** — do not route it through Ollama.
  By default, let it inherit the user's own working Qwen configuration; only pass a model
  override when the user explicitly asks for one. Because that configuration may still point
  to a hosted backend, the EGRESS limits stand: do not select it for a repository or path root
  declared confidential on this machine (see the guard's config file); `scripts/confidentiality-guard.sh`
  blocks those outright, but choose another backend rather than relying on the guard to catch it.
  See Backend B for the full egress rules.
- Practical note from 2026-07-27: `agy` is subject to an individual quota that can hard-fail
  a review in seconds, and older Ollama-based Qwen experiments drifted off-contract on a large diff. Whichever
  backend runs, **check elapsed time before trusting a verdict** — a review that returns in
  seconds on a large diff did not happen, and the driver's unparsed-verdict default
  (`VERDICT: changes requested`) looks identical to a real adverse verdict.
- **UNTRACKED FILES ARE INVISIBLE TO THE REVIEWER — `git add -N` FIRST.** Discovered
  2026-08-15 on a product repo: the driver builds its diff from TRACKED files only, so a branch
  whose substance is a NEW module gets reviewed as if that module did not exist. Round 1
  returned `ready to ship` in 200s having never seen the file the branch was about. Round 3,
  after `git add -N`, immediately found two defects the earlier rounds could not have seen.
  This is more dangerous than the elapsed-time trap below, because the elapsed time looks
  *normal* — the reviewer really did spend 200s reading the tests and the edits around a hole
  where the new code should be. **Before every round: `git add -N .` (intent-to-add) so new
  files enter the diff.** A "ready to ship" on a branch that adds a module and whose diff
  shows no new module is not a pass; re-run it.
- **`git add -N .` CAN BLOW THE INPUT LIMIT AND FAKE A VERDICT.** Discovered 2026-08-15 on
  a product repo, one round after the untracked-file trap above. Staging intent-to-add over a worktree
  that also holds run artefacts (transcripts, logs, eval output) pulled a **3.29 MB** diff into
  the request; the backend returned `400 … Range of input length should be [1, 983616]` and the
  driver printed `VERDICT: changes requested (no explicit verdict parsed)` — **9 seconds
  elapsed**, indistinguishable from a real adverse verdict. Narrow the staged set to CODE
  (107 KB in that case) rather than `add -N .` blindly, and treat any sub-30s round on a real
  diff as a review that did not happen. Two distinct causes now produce that identical footer:
  a network/auth failure (`ENOTFOUND`, usage limit) and an oversized diff.
- **Codex ChatGPT usage limits fail in ~4 SECONDS and echo the prompt.** Seen 2026-08-15: the
  run emitted `VERDICT:` lines that were prompt echo, not findings. If codex returns in seconds,
  check for a usage-limit message before reading anything as a verdict — and note the limit has
  a RESET DATE, so the backend may be unavailable for days, not minutes.
- **A quota refusal is not proof a backend is unavailable — check the ENDPOINT first
  (2026-08-19).** Codex and agy quotas are genuinely per-account and do strand you for days,
  but Qwen's are per-SUBSCRIPTION and a user may run several behind a local failover proxy.
  Naming a model whose provider entry points at the spent subscription refuses instantly and
  looks identical to "Qwen is down". Measured 2026-08-19: nine review rounds were run on
  Claude subagents because both `qwen -p --model qwen3.7-max` and `codex exec` returned
  quota errors — and a healthy second Qwen subscription was serving fine one hop away the
  whole time. Before concluding no reviewer exists, probe the proxy
  (`curl -s localhost:8787/__failover/status`) and let `qwen-review.sh` pick the routed model
  itself; see "Quota failover" under Backend B.
- A Claude subagent (Backend D below) is a fine alternative to `agy`/Qwen when the host
  itself is Claude Code and dispatching a sibling subagent is cheaper or faster than
  shelling out — use judgement, it is not ranked above agy/Qwen in the default order.

**DEFAULT: the reviewer EDITS — it fixes its own findings (the owner, 2026-08-08).** Run the
reviewer with edit rights unless the user says otherwise; the self-fix mandate in the
shared contract below ("Direct implementation is the MANDATE") is the default posture, not
an opt-in. Consequences for backend choice:

- **Prefer an edit-capable backend**: `codex` (default) and Qwen Code both edit; a Claude
  subagent (Backend D) edits when given the tools.
- **`agy` edits too** — `agy-review.sh` drives it with `--mode accept-edits` (corrected
  2026-09-18; until then this line said agy could not edit, and every agy round was silently
  comment-only). `AGY_REVIEW_MODE=plan` is the one named read-only exception.
- Reviewer edits are still **tagged and implementer-reviewed** before landing — see
  *Reviewer direct-edit tagging* below. "The reviewer edits by default" never means
  "trust the edits blind"; it means the gate returns working code, not a to-do list.

## The shared review contract (EVERY backend uses this — do not fork it)

Every revshell review — whichever backend is driving — uses this exact contract:

- **Input:** the COMPLETE unified diff (base → working tree), **inlined**. The reviewer
  reviews ONLY that diff.
- **Constraints:** do NOT broadly explore/grep the repo; do NOT recall past sessions or
  other repos; judge the diff on its own and answer promptly. The reviewer MAY open a
  couple of the changed files for surrounding context, but must not go hunting.
- **Synchronous completion:** the review is one blocking process. The reviewer MUST NOT
  spawn, delegate to, poll, or wait on agents, sub-sessions, background jobs, or watchers.
  It must not wait for external results. It may run directly available checks itself only
  when that needs no delegation; the host performs authoritative verification after the
  reviewer returns. A backend without test capability states inspection-only verification
  and returns its verdict — it never asks or waits for another agent to test.
- **Output:** concise findings, each as `file:line — issue (CRITICAL/HIGH/MEDIUM/LOW)`,
  then a final line that is EXACTLY one of:
  `VERDICT: ready to ship` / `VERDICT: changes requested`.
- **Direct implementation is the MANDATE (both phases).** The reviewer MUST directly
  implement EVERY finding it can fix mechanically itself — edit the plan in Phase 1, edit
  source in Phase 2 — structural fixes included, not just clear one-liners. It never hands
  back a fixable finding for the implementer to apply. It TAGS every edit it makes so the
  implementer reviews it (see *Reviewer direct-edit tagging* below). It reserves a
  *description-without-a-fix* ONLY for items that genuinely need architectural judgement the
  author must make, or user arbitration — those go in the findings. A `changes requested`
  verdict MUST still be accompanied by the reviewer's own self-fixes for everything that was
  mechanically fixable; it is never a substitute for doing the fixes the reviewer can do.
- **Edit-incapable rounds are the exception and must not multiply rounds** (the owner,
  2026-08-07). When a backend genuinely cannot edit (a deliberately isolated
  dispatch, or agy under the named AGY_REVIEW_MODE=plan exception), the reviewer MUST supply exact, paste-ready replacement
  hunks — not descriptions — for every mechanical finding, and the implementer applies them
  verbatim and re-verifies as the CLOSING act of the same round: apply → focused tests →
  done. A findings-list that forces the implementer to re-derive fixes, or a fix applied
  without its repro locked into a test, are both contract violations.

## Reviewer direct-edit tagging (the default — applies to BOTH backends)

When the reviewer corrects something directly, the implementer must be able to see, find,
and judge exactly what the reviewer changed before it lands. So every reviewer edit is
**tagged** two ways:

1. **In the reviewer's output**, a required block headed exactly
   `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:` listing each edit as
   `file:line — what changed + why`. This is the canonical, scannable record. If the
   reviewer made no edits, it writes `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none`.
2. **Inline, in prose/plan/markdown the reviewer edits**, an ` [reviewer: <reason>]` marker
   on or beside the changed lines. (Do NOT inject marker comments into source code — keep
   source clean; for code the output block + `git diff` is the tag.) Never silently revert
   or rewrite the author's intent — tag, with a reason.

The implementer (the host — implementer and orchestrator are the same session here) then
**reviews every tagged reviewer edit** before landing: `git diff` the reviewer's changes,
re-run focused tests, and explicitly keep or revert each one. This is mandatory **even when
the verdict is `ready to ship`** — a tagged reviewer edit is an implementer-review gate, not
a fix to trust blind.

## Backend A — agy reviewer (first fallback)

This skill OWNS the driver `scripts/agy-review.sh`. It implements the contract above for
`agy` (`~/.local/bin/agy`), a CLI whose configured default is Gemini — **not** the OpenAI API.
Use it when the default Codex backend is unavailable or the user asks for it.

```
bash <revshell-skill-dir>/scripts/agy-review.sh \
     --plan "$PLAN" --phase <plan|code> --repo "$REPO" --base <ref> \
     [--model <m>] [--context <file>] [--timeout <secs>]
```

`<revshell-skill-dir>` resolves from the host runtime's own skills dir (e.g.
`~/.claude/skills/revshell`, `~/.codex/skills/revshell`). It prints the reviewer's findings
then a parseable final `VERDICT: …` line. No `--model` by default: agy's own default is
Gemini 3.8 Flash on agy's own subscription (the owner, 2026-09-15); override via
`AGY_REVIEW_MODEL` or `--model`. `agy` runs `--mode accept-edits --print`: it EDITS the
worktree and lists every edit under `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:`, like
Codex and Qwen; it has no shell, so the host runs the tests. `AGY_REVIEW_MODE=plan` is the
named read-only exception. *(Corrected 2026-09-18, on the owner's "can you correct that at
skill level please": this said agy did not edit in print mode, which made every agy round a
comment-only review.)*

All script-backed reviewer calls block only their caller; they do **not** acquire a global
lock. Multiple shells or agents can run revshell concurrently. Every invocation gets a unique
ID and reports start, elapsed-time heartbeats, and completion on stderr while preserving stdout
for the review and terminal verdict. Reviewer output is intentionally buffered in a private
per-invocation file until the backend exits, which prevents escaped tool children from holding
a caller's pipe open; that buffering is not serialization or a stalled reviewer. Heartbeats
default to 30 seconds; set `REVSHELL_HEARTBEAT_SECONDS=0` to disable them or another integer to
tune them. (This paragraph applies to every backend below too — it's the shared driver
runtime, `scripts/review-runtime.sh`.)

## Backend B — Qwen Code reviewer (regular shell `qwen` CLI)

When `agy` is not on PATH or its invocation fails, fall back to **Qwen Code** — also useful on
its own for a second model's perspective without burning Claude quota:

```
bash <revshell-skill-dir>/scripts/qwen-review.sh \
     --plan "$PLAN" --phase <plan|code> --repo "$REPO" --base <ref> \
     [--model <name>] [--context <file>] [--timeout <secs>] [--approval-mode <mode>]
```

Same flags and contract as `agy-review.sh`; the `--sandbox` flag is omitted (Qwen Code
manages its own tool permissions). Qwen runs from `$REPO` as its working directory and, like
`agy`, edits files directly (tag every edit per the contract above).

### Quota failover — the model id decides whether a round survives (2026-08-19)

**A Qwen review dying with `insufficient_quota` usually means the WRONG ENDPOINT was named,
not that Qwen is unavailable.** Each provider entry pins one fixed upstream, so naming a
model whose entry points at an exhausted subscription kills the round even when another
healthy subscription is one hop away. Measured 2026-08-19: a whole review series was
written off as "qwen is quota-dead for two days" while a second subscription sat idle
behind a local proxy — those reviews were lost to a flag value, not to a quota.

If a **local failover proxy** is listening (a small local server that replays a refused
request against the next upstream in a cascade), `qwen-review.sh` now finds it and routes
through it automatically:

- Detection is a probe of `QWEN_FAILOVER_STATUS_URL` (default
  `http://127.0.0.1:8787/__failover/status`). If nothing answers, NOTHING changes and the
  caller's own `qwen` configuration is inherited exactly as before — but that fallback is
  now OFF by default (see the next bullet).
- **The proxy is the DEFAULT ROUTE, not an optimisation (owner ruling 2026-08-19: "use the
  proxy, it auto-routes to the correct registration" / "always use the proxy").** If it is not
  listening, `qwen-review.sh` exits 4 instead of quietly running against one fixed upstream.
  `QWEN_FAILOVER_REQUIRED=0` restores the old best-effort behaviour. The failure this prevents
  is real and measured twice on 2026-08-19: a `token-plan` 1-week quota returned
  `insufficient_quota` outright, and separately a duplicate `qwen3.8-max` provider entry (one
  on the proxy, one on `dashscope-intl`) made the CLI resolve to whichever came first.
- When it answers, the round runs as `QWEN_FAILOVER_MODEL` (default `qwen3.8-max`) — **only
  the id whose provider entry points AT the proxy traverses the cascade**; every other id
  talks to one fixed upstream and dies with it.
- An explicit `--model` / `QWEN_REVIEW_MODEL` always wins and is never rerouted (pinning is a
  deliberate act), but the script says out loud that the pin forfeits failover.
- **Pre-flight route assert.** The CLI resolves a model id to the FIRST provider entry with
  that id, and the same id can legitimately appear twice (once via the proxy, once straight at
  a metered endpoint). Before spending anything, the script reports when the id resolves
  somewhere other than the proxy, and notes when it is declared more than once — so a
  reordered provider list cannot silently move where reviews are billed.
- **Metered-tier announcement.** The POST-ROUND AUDIT names the upstream that served, and if
  the cascade fell through to a per-token tier (`QWEN_FAILOVER_METERED_TIERS`, default
  `on-demand`) it says so loudly. The round still runs — the user built the cascade
  deliberately and the spend is theirs to choose — but this skill's TOP RULE is that internal
  work rides subscriptions, so metered spend is never silent. It flags the reverse case too:
  proxy up but zero requests served means the round did NOT use the cascade.

### The round talks to the PROXY and nothing else — no direct plan link (the owner, 2026-08-25)

Measured 2026-08-25 on a product repo: three rounds died in 10 s each with `token-plan 1-week
quota has been exhausted` while the proxy's `token-plan-2` upstream was healthy and the
proxy served **zero** requests. The user's `~/.qwen/settings.json` listed `qwen3.8-max`
twice — first straight at `token-plan`, later at the proxy — and the CLI took the first.
The pre-flight route assert reported it correctly and could do nothing about it; neither
`QWEN_FAILOVER_MODEL=` (empty falls back to the default) nor `OPENAI_BASE_URL` (the
settings' provider list wins) changed the route. the owner: *"it should only be using the
proxy that auto selects the plan that has token. fix the proxy and remove direct plan
link from revshell."*

`qwen-review.sh` therefore no longer depends on the user's provider list: when the proxy
answers, it writes a **workspace** `$REPO/.qwen/settings.json` naming exactly one provider
entry — the proxy — and exports a placeholder `REVSHELL_PROXY_TOKEN` (the proxy strips the
client's `Authorization` and injects its own upstream key, verified in
`proxy.mjs::sendUpstream`; the placeholder never reaches a vendor). The file is removed, or
a pre-existing one restored, on exit. Verified: `token-plan-2` request counter 2 → 3 on a
one-line prompt. A pinned `--model` still bypasses this on purpose.

### The stop condition is SILENCE, not elapsed time (2026-08-19)

`review-runtime.sh` has stopped reviewers on liveness since 2026-08-17: a round dies after
`REVSHELL_IDLE_TIMEOUT_SECONDS` (300s) with **no new output**, never for merely being slow.
`--timeout` is a separate ABSOLUTE ceiling, and `0` means "no ceiling".

**Qwen's driver now defaults that ceiling to 0**, because qwen streams
(`--output-format stream-json`) so capture-file growth is a true sign of life. Shipping
`1800` anyway re-created the exact failure the liveness work removed: measured 2026-08-19,
a round was killed at `elapsed=1504s, ceiling=1500s` **while still streaming** — the runtime
logged "it was alive, so raise --timeout or set it to 0" — losing 25 minutes of real review
and leaving the reviewer's edits behind with no verdict to judge them by.

With no ceiling, the idle timeout is the ONLY stop condition, so it must outlast the
backend's silent phase. Qwen reads the whole diff before emitting its first real token, and
that phase scales with diff size: measured on a 79 KB diff, the capture file sat at 1,478 B
from t=30s to t=270s and only grew at t=300s — a hair inside the runtime's 300s default.
Qwen's driver therefore raises `REVSHELL_IDLE_TIMEOUT_SECONDS` to 600s (the caller's own
value always wins). Watch for this whenever a backend is moved to ceiling-0: the two knobs
have to be set together, or you trade a wall-clock kill for a silence kill.

The other drivers keep a ceiling deliberately: `agy --print` is buffered and emits nothing
until it finishes, so an idle timer would kill a healthy run. Only move a backend to
ceiling-0 once you have evidence it streams incrementally into the capture file.

### A CONCURRENT EDIT TO THIS SKILL'S SCRIPTS CORRUPTS A LIVE ROUND (2026-08-19)

**Do not edit these scripts while a round is in flight. That is the whole fix — and note the
obvious workaround does NOT work.**

Process substitution is the natural way to snapshot a script, and it BREAKS EVERY DRIVER HERE:

```sh
bash <(cat <revshell-skill-dir>/scripts/qwen-review.sh) --plan … --phase code …   # ← DO NOT
```

Each driver resolves its shared sibling from its own location —
`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, then
`. "$SCRIPT_DIR/review-runtime.sh"`. Under `<(cat …)` that location is `/dev/fd`, so the source
fails on line 43 before the reviewer ever starts:

    /dev/fd/11: line 43: /dev/fd/review-runtime.sh: No such file or directory

Measured 2026-08-20 and AGAIN 2026-08-21, the second time by an agent that had a saved memory
warning about it — because this paragraph is what gets read at invocation time, which is why the
correction belongs here and not only in a memory file. `await-log.sh` now catches it as **exit 12
in ~20s** with the log printed, rather than the seven minutes it cost the first time, but the
launch is still wasted.

**If you genuinely need a snapshot, copy the WHOLE `scripts/` directory to a temp dir and run the
copy from there**, so the sibling resolves beside it:

```sh
SNAP=$(mktemp -d) && cp <revshell-skill-dir>/scripts/*.sh "$SNAP"/
bash "$SNAP/qwen-review.sh" --plan … --phase code …
```

**Measured 2026-08-19.** A plan-phase round ran 17:57→18:28. `qwen-review.sh` was edited at
18:09 — mid-round, by the same operator, for an unrelated improvement. Bash reads a script file
INCREMENTALLY, not into memory, so when the reviewer returned the shell resumed at a now-stale
byte offset inside `emit_failover_audit` and died with `line 519: syntax error near unexpected
token ';;'`. The `EXIT` trap then deleted `$RESULT_FILE` **before** the parser printed the
findings and the `VERDICT:` line. The round had completed successfully and its 20 reviewer edits
were on disk — only the verdict and findings text were destroyed, and they are unrecoverable
(the proxy logs metadata only, and `--safe-mode` leaves no qwen session log).

Two rules follow:
- **Never edit these scripts while a round is in flight.** Check for running rounds first; if one
  is live, defer the edit.
- **Write `$RESULT_FILE` somewhere the EXIT trap does not remove on an ABNORMAL exit**, so a
  crash surfaces the captured review instead of deleting it. A round that did the work and lost
  only its report is the most expensive possible failure — you pay full tokens and full
  wall-clock for nothing.

### Qwen's SILENT phase scales with diff size — set the idle timeout to match (2026-08-19)

`REVSHELL_IDLE_TIMEOUT_SECONDS=600` (the Qwen driver's default) is NOT enough for a large diff.
Measured the same day: a **135 KB** diff sat at `streamed=1476B` from t=30s and was killed as
unresponsive at 600s having produced no verdict — while a successful round on a comparable diff
**broke silence at t=450s and finished at 795s**. Three separate rounds were lost this way and
misdiagnosed as a dead proxy. For anything above ~100 KB set
`REVSHELL_IDLE_TIMEOUT_SECONDS=1500` with `--timeout 0`, or split the diff into per-area passes.

### The POST-ROUND AUDIT can report a FALSE NEGATIVE under `git add -N` (2026-08-19)

The audit compares `git status --porcelain` strings before and after. A scratch clone seeded with
`git add -N` shows the same `A ` letters before and after a CONTENT change, so the audit printed
"Working tree unchanged by the reviewer" while the reviewer had in fact edited both files.
**Verify reviewer edits by diffing CONTENT, never by trusting that line.**

### Orphaned `qwen` children outlive a killed driver (2026-08-19)

When an agent driving a round is killed (session limit, timeout), its `qwen` child processes
SURVIVE and keep consuming the shared failover cascade. Measured: five orphans — one **25 hours**
old — were holding upstream capacity and stalling live rounds; more than half the load was dead
work. After any aborted round, sweep for `qwen` processes older than ~10 minutes and kill them.

### Invocation gotchas (learned through 2026-08-14)

- **There is NO `--branch` flag.** The script reviews whatever is checked out at `--repo`
  against `--base`. To review a branch, pass **the worktree that branch already lives in** as
  `--repo` — it has one; every work package does. `git worktree add` a second copy ONLY when
  the branch genuinely has none, and never to make a review copy of a branch already checked
  out somewhere (see "REVIEWS RUN IN THE BRANCH'S OWN WORKTREE"). Passing `--branch` exits
  instantly with `unknown arg '--branch'` — and if you only watch the log tail, that one-line
  failure is easy to mistake for a fast completion.
- **Under shell-driven debugging, use structured output mode.** `qwen -p` in plain text mode can
  look idle under host-shell capture even when the model is working. The reliable host-side path
  on this machine is `qwen --safe-mode --output-format json|stream-json -p ...` and then wait
  for the terminal `result` event. The shared `qwen-review.sh` driver already does this; ad hoc
  debugging should too.
- **Scope size still matters.** On this machine, small scoped file reviews can return cleanly in
  that structured-output mode, while larger multi-file or large-single-file prompt reviews may sit
  silent long enough to be operationally useless. When debugging or forcing a review through the
  shell tool, prefer one small file or one narrow concern at a time and aggregate the verdicts.
- **A "changes requested (no explicit verdict parsed — treat as not converged)" footer is NOT
  a review verdict.** The wrapper prints that default whenever the reviewer produced no
  sentinel. Treat that as a failed/non-converged run and inspect the log body before acting.
- **If the user explicitly says "use regular shell qwen", do exactly that.** Do not swap in
  an Ollama model name or any alternate local bridge. Use the top-level `qwen` CLI in the
  worktree, and let it inherit the user's working default unless they asked for `--model`.
- **For headless revshell runs, prefer `qwen --safe-mode`.** On this machine that keeps the
  regular shell `qwen` path but avoids local hooks/extensions/MCP/skills that can otherwise
  stall a non-interactive review before it ever reaches the model. It does **not** affect
  which tools the reviewer gets — see the next entry.
- **NEVER tell a headless qwen reviewer to run a shell command itself.** _(2026-08-16.)_
  Headless qwen registers `run_shell_command` **only** under `--approval-mode yolo`; under
  `default` / `auto` / `auto-edit` the tool is dropped from the registry entirely, because a
  confirmation-requiring tool cannot be confirmed with no user attached. Measured here:
  `yolo` → 29 tools (has the shell), `auto-edit` → 27, `auto`/`default` → 24 (none), and
  `tool_search` then answers `Not found: run_shell_command`.
  Qwen does not stop at that dead end. Given a prompt ordering it to run `git diff --cached`,
  it `tool_search`ed for a shell **24 times**, spawned **5 nested subagents** that each failed
  identically, then reached for its built-in `computer_use__*` desktop-automation tools and
  drove **Terminal.app** through synthetic `⌘N` / `type_text` / `press_key` to run the command
  via the GUI — outside the sandbox, outside the approval flow, outside the review audit log.
  Those desktop calls were logged `decision: auto_accept` while the shell was withheld. That
  asymmetry is the thing to remember: qwen strips the shell for being unconfirmable but leaves
  strictly more powerful desktop automation registered and auto-approved. Across
  2026-08-06..16 it produced 336 desktop-automation calls, including `page get_text` against
  the user's personal Chrome.
- **Route qwen reviews through `qwen-review.sh`, never ad hoc `qwen -p "..."`.** The script is
  safe by construction: it embeds the complete unified diff in the prompt, so its reviewer
  never needs a shell. The 2026-08-16 escape came from hand-rolled `qwen -p` calls that
  bypassed the driver and told the model to "run `git diff --cached` yourself first". Do not
  add that language here, and never "fix" a missing shell by switching to `--approval-mode
  yolo`.
- **Defence in depth:** `tools.computerUse.enabled: false` is set in `~/.qwen/settings.json`
  so qwen cannot reach for desktop automation even if a reviewer is starved of a shell again.
  Leave it off unless there is a deliberate, supervised reason to turn it back on.
- **Do not add `--bare` casually.** On this machine `--bare` strips the configured auth type, so
  non-interactive runs fail immediately with `No auth type is selected` unless an explicit auth
  mode is also provided.

### Qwen in EDITABLE mode — audit the tree, never trust the verdict alone

Qwen is one of the two backends that actually writes to your working tree. That is why it is
worth using — and it means **the round's side effects are not confined to its verdict.** After
every Qwen round, before you do anything else:

1. **`git log` first — Qwen sometimes COMMITS your staged work mid-review, unasked.** Measured
   2026-08-16: a `feat(wip)` commit appeared ~6 minutes into a code-phase round nobody asked to
   commit. Recover with `git reset --soft <base>`, and prove no content was lost by comparing
   `git rev-parse HEAD^{tree}` before and after. Note the memory-recall receipt some repos
   require dies with the discarded commit and must be re-recorded.
2. **`git status` / `git diff` next — a round that produced NO verdict may still have edited
   files.** A timeout, a crash, or the "no explicit verdict parsed" footer all leave edits in
   place. Never conclude "the review didn't happen" from a missing verdict; conclude it from
   the log plus a clean tree.
3. **Check scope.** Reviewers here have been caught scope-bleeding into files unrelated to the
   diff. Diff `git status` against the set of files you intended to touch, and revert anything
   outside it rather than shipping a reviewer's opportunistic edit.
4. **Mutation-test any regression test the reviewer wrote for its own fix.** Revert ONLY the
   fix and confirm the new test fails with the described symptom, then restore. A reviewer that
   authored both the fix and its test has no independent check that the test discriminates —
   this has caught a non-discriminating test here before.
5. Keep or reject each edit deliberately and **say which in your report**, with reasoning.
   "Reviewer edits by default" never means "trust blind" — that is the standing rule, and
   editable mode is exactly where it bites.

### ⚠️ This backend sends code OFF-MACHINE — read before selecting it

This backend uses the machine's regular shell `qwen` CLI, which may still be configured
against a hosted provider. The `code` phase inlines the COMPLETE diff, so treat every
invocation as a potential data-egress event to a third party unless you know the user's
Qwen setup is purely local.

`scripts/confidentiality-guard.sh` enforces this and runs before any network call. It
**hard-blocks (exit 6)**, printing what tripped and sending nothing:

| Check | Default | Override |
|---|---|---|
| repo remote matches a confidential org (declared in `REVSHELL_CONFIDENTIAL_REMOTES`) | block (when declared) | `REVSHELL_ALLOW_CONFIDENTIAL_SOURCE=1` |
| repo path under a confidential root (declared in `REVSHELL_CONFIDENTIAL_PATHS`) | block | `REVSHELL_ALLOW_CONFIDENTIAL_SOURCE=1` |
| credential-shaped text in the outgoing prompt (`sk-`, `ghp_`, `AKIA`, `xox`, PEM keys, JWTs, …) | block | `REVSHELL_ALLOW_SECRETS_IN_PROMPT=1` |

Declare the roots/orgs with `REVSHELL_CONFIDENTIAL_PATHS` / `REVSHELL_CONFIDENTIAL_REMOTES`, in the
environment or in `~/.config/revshell/guard.conf` (a shell file; the environment wins; both default to
empty, so a fresh install blocks by path or remote nothing until its owner declares it).
**For a repository declared confidential use a LOCAL backend or a Claude subagent — not this one.** The guard reports only the pattern name and line number, never the matched text.

### Default model behavior and edit rights

- **By default the script inherits the user's normal shell `qwen` model selection.**
  If the user wants a specific model, pass `--model` or set `QWEN_REVIEW_MODEL`; otherwise
  let the installed CLI use its own working default.
- **Edit rights come from `--approval-mode auto-edit`** (default; override with
  `QWEN_REVIEW_APPROVAL_MODE`). This auto-approves file edits but NOT shell, which is the
  right blast radius for a reviewer — but it means the reviewer **cannot run tests** and will
  verify by inspection instead. The Qwen driver explicitly forbids delegating,
  polling, or waiting for tests/background agents: the host runs tests after the
  reviewer returns, keeping the gate synchronous and bounded. Use
  `--approval-mode yolo` only in a throwaway worktree if you need it to execute.
- Do NOT try to grant permissions via a `permissions.allow` block in `~/.qwen/settings.json`
  — that is a Claude Code idiom, not Qwen's schema, and Qwen silently discards it on its next
  rewrite. `tools.approvalMode` is the real setting; the CLI flag beats it and survives.
- The API key lives in the login keychain (`security find-generic-password -s qwen-dashscope`)
  and is exported by `~/.zshrc`. Qwen also caches it in plaintext in `settings.json` on its
  own — that file is CLI-managed, so treat it as a cache, not the source of truth.

## Backend C — Codex reviewer (ChatGPT subscription, never an API key — THE DEFAULT, restored 2026-07-28)

**This is the default backend.** Restored 2026-07-28 by the owner ("go back to using codex for
revshell"), superseding the 2026-07-27 instruction that had demoted it in favour of `agy`.
Select it unless the user asks for something else; fall back to `agy`, then Qwen, if it is
unavailable.

This skill OWNS the driver `scripts/codex-review.sh`. It implements the contract above for
Codex and is hardened against the failure modes that made naive `codex exec` unusable:

1. **Session-memory recall flood** — disabled globally in `~/.codex/config.toml`
   (`[features] memories = false`), so Codex no longer recalls thousands of lines of
   unrelated cross-repo history every run. Kept at config level, not per-invocation.
2. **Repo-paging instead of concluding** — fixed by **inlining the diff** with a strict
   "review ONLY this diff, don't explore" prompt and a forced terminal `VERDICT:` line.
3. **Healthy concurrent reviews looking hung** — fixed with per-invocation IDs plus periodic
   elapsed-time heartbeats on stderr while the safely isolated reviewer output is buffered.

```
bash <revshell-skill-dir>/scripts/codex-review.sh \
     --plan "$PLAN" --phase <plan|code> --repo "$REPO" --base <ref> \
     [--model <m>] [--sandbox <mode>] [--context <file>] [--timeout <secs>]
```

It prints the reviewer's findings then a parseable final `VERDICT: …` line. Defaults, set by
the owner 2026-08-08: **`gpt-5.4` at `medium` reasoning effort**, `workspace-write` (so the
reviewer edits code directly, per its direct-implementation mandate), portable timeout. The
model/effort pins apply to REVSHELL ROUNDS ONLY and are passed per-invocation — `~/.codex/
config.toml` is never read or written for them, so everyday Codex work is unaffected.
Override with `COREVIEW_CODEX_MODEL` / `--model` and `COREVIEW_CODEX_REASONING_EFFORT` /
`--effort`; pass an empty model to inherit the Codex config default.

**Raise `--effort` yourself on a large diff or a safety-critical change.** `medium` is the
standing default, but a low-effort pass over a big diff is not a gate — that judgement now
sits with the caller rather than the script.

**There is no temperature setting, by design.** These are reasoning models: they expose
`model_reasoning_effort`, not temperature. A request to review "at temp 0.1" is answered by
`--effort` and nothing else; a temperature flag would be silently ignored.

**GPU repos (MLX/Metal) need `--sandbox danger-full-access`.** The sandbox denies
`iokit-open`, so `MTLCreateSystemDefaultDevice()` returns nil and any import of `mlx` /
`mlx_audio` / `mlx_whisper` kills the interpreter with SIGABRT — `[metal::load_device] No
Metal device available` is thrown from C++ and escapes as `std::terminate`, so pytest cannot
catch it and the run reports *nothing*, not a failure. Measured 2026-08-03 on `voiceclone`:
26 macOS crash reports in two days, every one parented by `codex`. Set it per invocation:

```
COREVIEW_CODEX_SANDBOX=danger-full-access bash …/codex-review.sh --repo ~/Dev/voiceclone …
# or: --sandbox danger-full-access   (same flag now exists on codex-implement.sh)
```

Widening the sandbox also removes the isolation that keeps a session away from the shared
primary checkout — do it for repos that genuinely need the GPU, never as a default.

## Backend D — Claude (or other) subagent reviewer

When the reviewer should be a **Claude subagent** — you want a second perspective /
adversarial pass without shelling out, e.g. the host is itself Claude Code — dispatch the
review subagent with the **same contract**: hand it the inlined diff, the same constraints
(review only the diff, no broad exploration, no cross-session recall), and require the same
`file:line — issue (severity)` findings plus the terminal `VERDICT:` line. Do **not** invent a
different review shape — the contract is shared so every backend's verdict means the same
thing.

**Dispatch WITH edit rights (default, per the owner 2026-08-07).** Give the review subagent
file access to the implementer's worktree (Read/Edit/Write on that path) so the
direct-implementation mandate applies in full: it fixes every mechanically fixable finding
itself and tags per the contract, and the implementer's next act is *auditing the reviewer's
edits* (`git diff`, focused tests, keep-or-revert each) instead of re-implementing prose
findings — one audit pass instead of an extra full round. Dispatch text-only ONLY when
isolation genuinely demands it, and say so next to the verdict, because a text-only round
degrades the contract (see below).

## Backend E — Cursor agent (`cursor-agent`), no driver script yet (2026-10-29)

Use it only when the user asks for Cursor (the owner, 2026-10-29, asked for a simultaneous multi-model check that included Cursor). It runs on the user's Cursor subscription (`cursor-agent status` → "Logged in as …"). Never pass
`--api-key` or set `CURSOR_API_KEY` (TOP RULE). `cursor-agent --list-models` lists its seats. A Grok or Composer
seat gives a third provider beside Codex (OpenAI) and agy (Google).

**MEASURED 2026-10-29: in `-p --mode plan`, `--output-format text` can return an EMPTY answer with exit 0.** A
headless consultation (`grok-4.7-high`, a 1,200-word design question) wrote 1 byte to stdout and nothing to stderr,
and exited 0. The same question re-run with `--output-format json` returned `{"type":"result","subtype":"success",
"result": "<answer>", …}`, with an 8,769-character answer after 417 s. So:

- Always run headless Cursor with `--output-format json` and read `.result`. Treat an empty `.result`, or an
  `is_error: true`, as a FAILED round, never as "no findings".
- Put this line in the prompt: "write your whole answer as your final chat message; do not create a plan file or a
  to-do list instead". Plan mode otherwise tends to produce a plan, not an answer.
- Read-only consultation: `--mode plan` (or `ask`). Edit-capable review: run it in the branch's worktree without
  `--mode plan`, under the shared contract (inlined diff, `VERDICT:` line, tagged edits). Never `--yolo`/`--force`.
- Shape of the call: `cursor-agent -p --mode plan --model <seat> --trust --workspace <dir> --output-format json
  "$(cat <prompt-file>)" < /dev/null`. Wrap it in `~/.claude/bin/claude-sub-slots run --owner "<who and what>" --`
  like every subscription shell, and close stdin.


## Loop

1. **Phase 1 (optional) — plan review:** `--phase plan` until the verdict is
   `ready for implementation`. The reviewer edits the **plan file** directly by default
   (tagged, per above); no *source* edits / no mutating git in Phase 1.
2. **Implement** the converged change on the temp worktree branch — including
   reviewing/accepting any tagged reviewer edits to the plan. **Do not commit:** the working
   tree is the review artifact; the stable diff base is `$(git merge-base <target> HEAD)`
   (stays correct across mid-loop reconcile merges).
3. **Phase 2 — code review:** `--phase code --base "$(git merge-base <target> HEAD)"` →
   read findings AND the `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:` block → review every
   tagged reviewer edit (`git diff` + focused tests, keep or revert each) → address remaining
   findings as **working-tree edits, never a per-round commit** (subagents for non-trivial
   scope, direct edits for 1–3 mechanical files) → re-verify → re-run.
4. **Ends when the verdict is `ready to ship`.** Then land per the discipline below; never
   push/promote without explicit user ask.

**Convergence guard:** three consecutive `changes requested` on the *same* unresolved point
is a genuine user-arbitration stop — surface it and ask.

## ONE ROUND WHEN BOTH SIDES AGREE — SPEND NEITHER SIDE'S TOKENS TWICE (the owner, 2026-08-16)

> *"spare yours and qwen's tokens. if changes are ok on both sides, no need to send back for
> an extra review or confirmation."*

**If the reviewer's edits are acceptable to the host on inspection, the round is OVER. Land it.**
Do not re-run the reviewer to confirm its own accepted edits, and do not ask the user to confirm
an agreement that already exists. A second round exists to resolve DISAGREEMENT; where there is
none it buys nothing and costs a full diff of tokens on both sides.

Concretely, after a `--phase code` round:

- Host reads the findings and the `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:` block, and
  audits each tagged edit (`git diff` + focused tests).
- **All edits kept, no findings left open → LAND.** No re-run. The reviewer already said its
  piece; the host already agreed. That IS convergence.
- **Host reverts an edit, or a finding needs work → fix in the working tree, then re-run.** The
  re-run is for the changed part, not a re-litigation of what both sides already settled.
- **Never** re-run purely to hear `ready to ship` said out loud. A verdict is not a ceremony.

This does not weaken the gate: the diff is still reviewed by a second model before it lands, and
the host still personally audits every reviewer edit. What is removed is the confirmation lap.

**It also does not license skipping the round.** One round is the floor, not the ceiling — a
genuine disagreement still iterates until it converges, and the three-strikes arbitration guard
above is unchanged.

## Commit & landing discipline (NON-NEGOTIABLE — all backends/runtimes; 2026-07-18)

- **Review rounds never create commits.** The reviewer corrects the working tree and hands
  it back corrected; the implementer folds fixes in place. No "checkpoint"/"round-N"
  commits — for crash safety keep at most ONE local WIP commit, refreshed with
  `git commit --amend` (temp branches are private, never pushed), squashed away before landing.
- **Land only approved commits.** At `ready to ship`, shape the branch into clean commits
  (`git reset --soft $(git merge-base <target> HEAD)`, then commit coherent units) whose
  messages describe the CHANGE — subjects with `wip`/`checkpoint`/`revshell`/`codex round`
  are refused by finish.sh. Then merge into dev/test and delete the temp branch:
  `bash <revshell-skill-dir>/../coreview/scripts/finish.sh --repo <main-checkout> --target dev
  --temp-branch <name>` (`--squash --message` for a single-unit change).
- **End with exactly ONE memory commit.** After the merge, save the session summary (goal,
  resolution, learnings) via `<revshell-skill-dir>/../coreview/scripts/save-learnings.sh` —
  it writes the note, refreshes vectors, and commits ONLY the memory store as one
  `docs(memory):` commit on the target branch (the sanctioned docs-only exception to "never
  commit directly on the base branch"). No mid-loop `docs(memory)` commits.
- Net history per session: approved commit(s) + one merge + one memory commit.

## Notes

- A host waits for its own blocking review round before consuming that verdict, but independent
  hosts can run rounds concurrently. A round can take many minutes on a large diff.
- **The driver stops a reviewer for SILENCE, not for elapsed time (2026-08-17).** The watchdog
  watches the capture file grow; a reviewer that is still streaming is never interrupted no
  matter how long it takes. Knobs:
  - `REVSHELL_IDLE_TIMEOUT_SECONDS` (default 300) — kill after this much *silence*.
  - `REVSHELL_IDLE_POLL_SECONDS` (default 10) — how often liveness is sampled.
  - `--timeout` is now only an **absolute backstop** against a pathological infinite-output
    loop. **`--timeout 0` means "no ceiling — silence is the only stop condition"**, which is
    the right choice for a big diff. Setting both to 0 is refused (no stop condition at all).
  - The heartbeat line reports `streamed=<bytes>`, so a stall is visible rather than inferred,
    and the exit line names which condition fired (`went SILENT` vs `hit the ABSOLUTE CEILING`).
  - **This requires a streaming backend.** `qwen-review.sh` uses `--output-format stream-json`
    for exactly this reason: with plain `json` the CLI emits nothing until the very end, so
    idle-detection would kill healthy runs. Do not "simplify" it back to `json`. The
    line-delimited stream still ends with the same terminal `result` event the parser reads.
  - _Why:_ measured 2026-08-17 — three rounds over one 325 KB diff were killed by a hard
    wall-clock timeout while the reviewer was alive and working, and a 63-file change through
    the coaching seam landed unreviewed as a result. Slow is not the same as dead.
- Very large diffs are still worth splitting into per-area passes for review QUALITY (the
  driver warns above ~600 KB) — but no longer because the clock will kill them.
- **BLOCKING ON THE ROUND IS THE TOP RULE OF THIS SKILL — see the top of this file.** Short form:
  launch the round detached to a unique log, then block in your own turn with
  `bash <revshell-skill-dir>/scripts/await-log.sh "$LOG"` (a foreground Bash call, tool
  `timeout: 600000`), and **re-issue it on exit 10** until it exits 0. Never hand the wait to
  `Monitor` or `run_in_background` and end your turn: a completion notification does not wake a
  subagent, and four measured sessions were lost that way (2026-08-16, 08-17, 08-19, 08-20).
- **`git diff` does not show untracked files, so a reviewer cannot see your new modules or
  tests.** Stage them with `git add -N` before invoking the driver. Measured 2026-08-16: a round
  reviewed a change whose core new module was invisible to it, and its own closing note said so;
  the follow-up round then found a HIGH-severity bug in the unseen file. A second round to cover
  material the first literally could not see is NOT a violation of the one-round rule — that rule
  is about not re-confirming edits you already accepted.
- The reviewer corrects clear issues directly by default (workspace-write) and tags each
  edit. Treat tagged edits like a subagent's: `git diff` to confirm what changed and re-run
  focused tests before trusting them — the `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:`
  block is your checklist of what to review.
