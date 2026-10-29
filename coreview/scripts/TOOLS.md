# coreview — per-runtime tool mapping

`coreview` is one common skill (this folder) symlinked into every runtime's skills dir.
The *protocol* is identical everywhere; only the **background-watcher mechanism** and the
**parallel-agent dispatch** differ per host runtime. Bind the abstract steps in `SKILL.md`
to your runtime using this table.

| Abstract step in SKILL.md | Claude Code | Codex | Gemini CLI |
|---|---|---|---|
| Arm a background plan-file watcher (surfaces each stdout line as a notification) | `Monitor` tool, `command: bash <dir>/scripts/<phaseN>-watcher.sh "$PLAN"`, `persistent: true`, `timeout_ms: 3600000` | Codex has no push-notification watcher. Prefer running the watcher in the foreground/blocking until it exits. **Reviewer role:** `scripts/watch_plan.py <plan> --phase plan --after-latest-review` in Phase 1, or `--phase implementation --after-latest-review` in Phase 2. **Implementer role:** after each implementation/fix marker, run `scripts/watch_reviewer.py <plan>`; it exits immediately if a reviewer marker already landed below the latest implementer marker. Never use `watch_plan.py` or an ad-hoc regex watcher to wait for reviewer markers. If any watcher is launched as an `exec_command` PTY session, poll it before every user-visible status/final response. | background exec of `bash <dir>/scripts/<phaseN>-watcher.sh "$PLAN"` (or `watch_plan.py` only when waiting for implementer markers); poll its output |
| Check a watcher is still alive | `TaskGet <watcher-id>` (re-arm with `Monitor` if "Task not found") | poll the active watcher session/PID for the role-specific script; relaunch if gone. A detected marker may already be waiting in buffered stdout, so polling is mandatory before saying "counterpart's turn" or finishing. | check the bg job; relaunch if gone |
| Stop a watcher | `TaskStop <watcher-id>` | SIGINT the active watcher only after explicit stop/pause; `watch_plan.py` ignores signals unless `--allow-interrupt` | kill the bg job |
| Dispatch parallel sub-agents (review slices, final audit, impl streams) | `Agent` tool (multiple in one message; `run_in_background: true` where useful) | native sub-agent / parallel task mechanism | native sub-agent mechanism |
| Append your own marker | `bash <dir>/scripts/append-marker.sh "$PLAN" <impl\|review> ...` | same script | same script |
| **`shellrev` mode** — reviewer in-shell (single session, NO watcher/markers) — see the standalone **`revshell`** skill | `bash <revshell-dir>/scripts/agy-review.sh --plan "$PLAN" --phase <plan\|code> --repo "$WORKTREE" [--base <ref>] [--context <file>]` (default backend; fall back to `qwen-review.sh`, or `codex-review.sh` only on explicit user request — see revshell/SKILL.md → "Reviewer backend selection") — blocking; reads the parseable `VERDICT:` last line. `<revshell-dir>` = `~/.claude/skills/revshell` (or your runtime's) | n/a (host-driven by definition) | n/a |
| Land + delete temp branch | `bash <dir>/scripts/finish.sh --repo R --target dev --temp-branch B ...` | same script | same script |
| Save goal/resolution/learnings as ONE docs(memory) commit + refresh vectors | `bash <dir>/scripts/save-learnings.sh --repo R --slug s ...` | same script | same script |

`<dir>` = this repo's `coreview/` directory, reached via your runtime's
symlink at `~/.claude/skills/coreview`, `~/.codex/skills/coreview`, or
`~/.gemini/config/skills/coreview`.

**`shellrev` is the exception to everything below:** it runs in a single host session and drives the
reviewer with blocking subprocess calls via the standalone **`revshell`** skill — default backend
`agy-review.sh`, Codex/`codex-review.sh` only on explicit user request (see revshell/SKILL.md →
"Reviewer backend selection"). No background watcher, no markers, no second session — so the watcher
invariants do not apply. The plan file is still the one shared artifact (the backend reads it, and
edits it directly only for backends that can — agy/DeepSeek are findings-only), but the handoff is
the synchronous subprocess return. See SKILL.md "Mode: shellrev".

**Key invariants regardless of runtime (regular `coreview` / `coreviewlight`):**
- Use a background mechanism that surfaces output as notifications — NOT a fire-and-forget
  background process whose stdout is buffered to a file you never read. (On Claude that means
  `Monitor`, never `Bash run_in_background`.)
- In Codex, `exec_command` PTY sessions do not surface stdout asynchronously. They are waiters that
  must be polled with `write_stdin`; do not leave a Codex turn while a watcher needed for the task is
  still running unpolled. Codex implementers should use `watch_reviewer.py` so a missed reviewer marker
  is discovered immediately on the next invocation.
- The watcher must outlive long idle gaps (a loop spans 30–60+ min). Set a 1h-class ceiling and
  re-arm if it dies.
- The watcher scripts match BOTH the canonical role lexemes (`impl:` / `review:`) and the legacy
  runtime lexemes (`claude:` / `codex:`), so a mixed/in-flight plan still works.
- **All sentinels in ONE canonical plan file** — never split the handoff across artifacts (design in
  one file, its review in another). A watcher armed on the wrong single file silently misses the
  counterpart's turn (this happened 2026-06-19). If a round legitimately spans multiple marker-bearing
  files, pass ALL of them — every watcher now accepts multiple plan paths:
  `phase1-watcher.sh <a> <b> …`, `phase2-watcher.sh <a> <b> …`, `watch_plan.py <a> <b> …`,
  `watch_reviewer.py <a> <b> …`. Prefer the single canonical file (see SKILL.md "ONE canonical marker
  file"); multi-file is the safety net. The legacy `coreviewlight-watcher.sh` is deprecated (it now
  warns + still runs); use the phase / `watch_*.py` watchers.
