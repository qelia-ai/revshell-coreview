# revshell + coreview

Reviewer-gated development loops for CLI coding agents (Claude Code, Codex CLI, Gemini CLI).
One canonical copy, symlinked into every runtime's skills directory, so every agent follows the
same review contract. No forked prompts per model.

**Why.** An agent that implements and merges its own work has no second pair of eyes. These
skills put a second model between "the change is written" and "the change lands", inside one
session, and make that review produce edits rather than a to-do list.

## What's inside

### `revshell/` - a review gate inside one session

The host agent implements a change in a git worktree, then runs a REVIEWER as a **blocking
subprocess** on the diff before it lands. No second session, no watcher: the subprocess return is
the handoff. The reviewer's answer ends in a parseable `VERDICT:` line.

**The reviewer edits.** Every backend is run with write access to the worktree. It fixes what it
can fix itself, tags each edit (`REVIEWER EDITS - IMPLEMENTER REVIEW REQUIRED`), and the host
inspects each edit (`git diff`, focused tests) before landing. A comment-only review is treated as
a failed review. Findings come back as edits, not as a list.

**Backends, in order, all behind one shared review contract:**

| Backend | Driver | Paid for by |
|---|---|---|
| Codex CLI - the default | `scripts/codex-review.sh` | the ChatGPT subscription (never an API key) |
| `agy` (Gemini) - first fallback, edit-capable via `--mode accept-edits` | `scripts/agy-review.sh` | its own subscription |
| Qwen Code - second fallback, the regular in-shell `qwen` CLI | `scripts/qwen-review.sh` | the user's own Qwen plan |
| A Claude review subagent (Backend D) | none - dispatched by the host with edit tools | the host's Claude plan |
| Cursor agent (Backend E) - only on explicit request | no driver script yet; the skill documents the headless invocation | the Cursor subscription |

**No host-supplied API keys.** The host never calls a model API itself: no `curl` to an inference
endpoint, no vendor SDK, and no host-supplied `*_API_KEY`. Every backend manages its own agent
credentials and model access. The test is how the tokens are invoiced, not the vendor.

Supporting scripts:

- `scripts/await-log.sh` - the in-turn blocking wait. A round is launched detached to a log, and
  the host blocks on it in a foreground call, re-issuing on exit 10 until the round finishes.
  Ending the turn to wait for a background notification loses the verdict.
- `scripts/review-runtime.sh` - runtime shared by the reviewer drivers: liveness-based timeouts
  (silence stops a round, not duration), heartbeats, signal cleanup, empty-diff refusal.
- `scripts/codex-implement.sh` - drives Codex as a sandboxed IMPLEMENTER (the mirror of the
  review driver), for hosts that hand the coding to Codex.
- `scripts/confidentiality-guard.sh` - preflight for backends that may send a diff off-machine
  (wired into `qwen-review.sh`). It blocks, with exit 6 and without sending anything, when (A) the
  repo's git remote matches a pattern you declared confidential, (B) the repo sits under a path
  root you declared confidential, or (C) the outgoing prompt contains credential-shaped text
  (`sk-` keys, GitHub tokens, AWS keys, PEM keys, JWTs, bearer tokens...). For credential-shaped
  matches, it reports the pattern and line number, never the matched text. Overrides are separate
  and explicit:
  `REVSHELL_ALLOW_CONFIDENTIAL_SOURCE=1`, `REVSHELL_ALLOW_SECRETS_IN_PROMPT=1`. Checks A and B are
  empty until you declare them (see Configuration); check C always applies.

### `coreview/` - two sessions, one plan file

A cross-model plan + implementation review loop. An IMPLEMENTER and a REVIEWER (for example Claude
and Codex, in two terminals) collaborate over one on-disk plan file; footer markers plus
background watchers are the whole handoff protocol. Modes:

- `coreview` - both sides may write corrections to each other's work.
- `coreviewlight` - the reviewer only steers (findings and instructions); the implementer writes
  all code.
- `shellrev` - single session; delegates to `revshell`.

You choose the mode, who implements and who reviews up front; the loop then runs to the end and
finishes on its own (reviewer audit, commit on the working branch, no push, save learnings).
`coreview/scripts/TOOLS.md` maps the abstract steps (watchers, agent dispatch, marker appends) to
each runtime's tools.

### `coreviewlight/` - pointer skill for the light mode (the implementation lives in `coreview/`).

## The commit discipline

Review rounds **never create commits**: the working tree is the review artifact and the diff base
is `git merge-base <target> HEAD`. A session lands as:

1. curated, approved commits only (messages describe the change, never the review process),
2. one `--no-ff` merge of the temp branch into the integration branch, then the branch is deleted,
3. one `docs(memory):` commit with the session's goal, resolution and learnings.

This is enforced by scripts, not only prose: `coreview/scripts/finish.sh` refuses to merge
branches carrying `wip` / `checkpoint` / `fixup` / named review-process subjects (`--squash` or
`--allow-noisy` are the escape hatches), and `coreview/scripts/save-learnings.sh` writes the memory
note and makes the single memory commit.

## Install

```bash
git clone <this-repo-url> ~/skills/revshell-coreview
cd ~/skills/revshell-coreview

# Claude Code
ln -s "$PWD/revshell" "$PWD/coreview" "$PWD/coreviewlight" ~/.claude/skills/
# Codex CLI
ln -s "$PWD/revshell" "$PWD/coreview" "$PWD/coreviewlight" ~/.codex/skills/
# Gemini CLI (adjust to your config's skills dir)
ln -s "$PWD/revshell" "$PWD/coreview" "$PWD/coreviewlight" ~/.gemini/config/skills/
```

Symlink, never copy: the checkout stays the single source of truth. Each skill's `SKILL.md` is the
contract. You also need the CLI of each backend you intend to use, signed in on its own plan.

## Configuration

Key settings are overridable by environment; defaults are sensible and nothing is tied to an account.

- Reviewer drivers: `AGY_REVIEW_MODEL`, `AGY_REVIEW_TIMEOUT`, `COREVIEW_CODEX_MODEL`,
  `COREVIEW_CODEX_SANDBOX`, `COREVIEW_CODEX_TIMEOUT`, `QWEN_REVIEW_MODEL`,
  `REVSHELL_HEARTBEAT_SECONDS`, `COREVIEW_CANONICAL_RECALL_MCP_SERVER` (the project index MCP a
  reviewer should query for prior art).
- Confidentiality: `REVSHELL_CONFIDENTIAL_PATHS` (colon-separated path roots) and
  `REVSHELL_CONFIDENTIAL_REMOTES` (an ERE matched against `git remote -v`), set in the environment
  or in `~/.config/revshell/guard.conf` (a shell file; the environment wins). Both default to empty.

The default reviewer is Codex; see `revshell/SKILL.md` -> "Reviewer backend selection".

## Tests

```bash
bash revshell/scripts/test-review-drivers.sh
bash revshell/scripts/test-guard-sk-boundary.sh
```

Deterministic and network-free (stubbed backends): concurrency isolation, verdict parsing, timeout
escalation, signal cleanup, and the credential-pattern boundary.
