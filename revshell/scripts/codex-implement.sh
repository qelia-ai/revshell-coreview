#!/usr/bin/env bash
{ # The whole file is one group, so bash parses all of it before running any of it: a rewrite in place
  # cannot corrupt a running round (2026-10-21: a cp over this file killed a 75-minute review at line 517).
# codex-implement.sh — spawn a sandboxed codex CODING session that can commit.
#
# WHY THIS EXISTS (measured 2026-07-31, and the first diagnosis was WRONG):
#
# Symptom: codex sessions under `-s workspace-write` cannot commit. Three of
# four parallel sessions hit it. Their work was complete and intact, but a
# caller that trusted "commit when done" and only checked for commits would
# have discarded finished work as failed.
#
# First theory (WRONG, recorded so nobody re-derives it): the sessions ran in
# `git worktree`s, whose `.git` is a FILE pointing at
# `<main-repo>/.git/worktrees/<name>` — outside the sandbox. Plausible, and
# false. A self-test with a real `.git` DIRECTORY inside the workspace failed
# identically.
#
# Actual cause: codex's workspace-write sandbox mounts `.git` READ-ONLY by
# design, so the model cannot rewrite history. No clone/worktree arrangement
# changes that, and widening the sandbox is not acceptable — these sessions
# must never be able to reach the shared primary checkout.
#
# Therefore: the session is EXPECTED not to commit, and this harness commits on
# its behalf, then fetches the branch back into the source repo. The shared
# clone is still worth it for isolation (the session physically cannot touch
# the primary checkout) and is cheap because objects are borrowed via
# alternates. Never treat "no commit" as "no work".
#
# SANDBOX (default workspace-write — widen only deliberately):
#
# The sandbox denies `iokit-open`, so `MTLCreateSystemDefaultDevice()` returns
# nil and ANY import of MLX (mlx / mlx_audio / mlx_whisper — e.g. voiceclone's
# test suite) dies with SIGABRT: the C++ `[metal::load_device] No Metal device
# available` throw escapes as std::terminate and takes the interpreter with it.
# It is not catchable in-process, so pytest reports nothing at all. Measured
# 2026-08-03: 26 macOS crash reports in two days, all parented by `codex`.
#
# `--sandbox danger-full-access` (or COREVIEW_CODEX_SANDBOX) restores GPU
# access for such repos. It also DROPS the isolation this script's header
# argues for: a full-access session can reach outside its temp clone, including
# the shared primary checkout. Use it only for repos that genuinely need the
# GPU, never as a blanket default.
#
# Usage:
#   codex-implement.sh --repo <source-repo> --branch <new-branch> \
#       --prompt <file> [--base <ref>] [--model <m>] [--effort <e>] \
#       [--sandbox <mode>] [--keep]
# PROMPT ON STDIN, NEVER ARGV (2026-09-23, bavardia): the prompt used to be passed as a
# command-line argument, so the whole brief was part of the codex process's command line.
# Other agents stopping their own test runs/emulators with `pkill -f "node --test"` /
# `pkill -f 'emulators firestore start'` matched text INSIDE the brief and SIGTERMed three
# unrelated codex sessions (A02b, A05, A06b — exit 143, work kept only by the commit trap).
# `codex exec -` reads the prompt from stdin; `ps` now shows no brief text.
set -euo pipefail

REPO="" BRANCH="" PROMPT="" BASE="dev" MODEL="gpt-5.6-sol" EFFORT="high" KEEP=0
SANDBOX="${COREVIEW_CODEX_SANDBOX:-workspace-write}"
# --canonical-recall (added 2026-08-29, mirrors codex-review.sh): run `codex exec
# --approve-for-me` instead of `-s "$SANDBOX"` so the session can call the
# project's index MCP (acme-agent-index). Under `-s …` every MCP call fails
# with "MCP tool call requires approval, but approval policy is never".
# `--approve-for-me` forces the workspace-write sandbox [workdir, /tmp, $TMPDIR]
# — the same isolation this script defaults to — and is mutually exclusive
# with -s/--sandbox in the Codex CLI, so an explicit --sandbox plus this flag is
# a usage error here, not a silent choice.
# The index server a --canonical-recall session must have before its first model
# request; must match the server id in ~/.codex/config.toml (`codex mcp list`).
# Overridable so another project can point this driver at its own index server.
CANONICAL_RECALL_MCP_SERVER="${COREVIEW_CANONICAL_RECALL_MCP_SERVER:-acme-agent-index}"
# PROJECT DOCS (added 2026-09-21). codex concatenates every AGENTS.md from the git
# root down to the session's cwd into its instructions. In a repo whose AGENTS.md is
# a large catalogue that is NOT what the implementer should read (a product repo is 242 KB;
# its seats measured ~190 KB of dev docs per cold start, fixed there by
# project_doc_max_bytes=0), that spends the session's context on text the brief
# already names. Opt-in, default UNCHANGED for every other repo:
#   CODEX_IMPLEMENT_PROJECT_DOC_MAX_BYTES=0 codex-implement.sh ...
# Any value is passed through verbatim as -c project_doc_max_bytes=<value>.
# EMPTY-ARRAY EXPANSION, fixed 2026-09-21 (a product repo): under `set -u` macOS's bash 3.2 treats
# "${PROJECT_DOC_C[@]}" on an EMPTY array as an unbound variable and aborts BEFORE codex starts, after
# which this script's own reporting says "NO COMMITS - session produced no changes" - a driver crash
# wearing a model's failure. Expanded as ${ARR[@]+"${ARR[@]}"} so an empty array expands to nothing.
PROJECT_DOC_C=()
if [[ -n "${CODEX_IMPLEMENT_PROJECT_DOC_MAX_BYTES:-}" ]]; then
  PROJECT_DOC_C=(-c "project_doc_max_bytes=${CODEX_IMPLEMENT_PROJECT_DOC_MAX_BYTES}")
fi
CANONICAL_RECALL=0 SANDBOX_EXPLICIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --sandbox) SANDBOX="$2"; SANDBOX_EXPLICIT=1; shift 2 ;;
    --canonical-recall) CANONICAL_RECALL=1; shift ;;
    --keep) KEEP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$REPO" && -n "$BRANCH" && -n "$PROMPT" ]] || {
  echo "usage: --repo <dir> --branch <name> --prompt <file> [--base ref] [--model m] [--effort e] [--sandbox mode] [--keep]" >&2
  exit 2
}
[[ -f "$PROMPT" ]] || { echo "prompt file not found: $PROMPT" >&2; exit 2; }
git -C "$REPO" rev-parse --verify --quiet "$BASE" >/dev/null || {
  echo "base ref '$BASE' not found in $REPO" >&2; exit 2; }
git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null && {
  echo "branch '$BRANCH' already exists in $REPO — pick a fresh name" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cxi-${BRANCH//\//-}-XXXXXX")"
# THE CLONE IS IN THE MACHINE'S WORKTREE REGISTRY (2026-10-28): one row now, owned by this
# script's pid ($$, recorded with its kernel start time), and one when the clone is removed or
# kept. A SIGKILL skips the EXIT trap below; the first row then stays as the explicit recovery
# state, and `claude-sub-slots disk worktrees --orphans` lists the clone once this pid is gone.
# Nothing removes it automatically. Without the tool (another machine) this says so once and
# carries on.
SLOTS_TOOL="${CLAUDE_SLOTS_TOOL:-$HOME/.claude/bin/claude-sub-slots}"
REGISTRY_SAID=0
register_work() {   # <status> <purpose>
  if [[ -x "$SLOTS_TOOL" ]] && "$SLOTS_TOOL" disk register-path --path "$WORK" --kind scratch \
      --pid $$ --owner "codex-implement $BRANCH (from $REPO@$BASE)" --status "$1" \
      --purpose "$2" </dev/null >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$REGISTRY_SAID" == "0" ]]; then
    REGISTRY_SAID=1
    echo "[codex-implement] clone not in the worktree registry ($SLOTS_TOOL disk register-path unavailable); carrying on" >&2
  fi
  return 0
}
register_work registered "codex-implement clone for branch $BRANCH"
# THE CLONE IS DELETED ONLY WHEN ITS WORK IS SAFE SOMEWHERE ELSE (2026-09-21).
# `LANDED=1` is set at exactly one place: after the branch has been fetched into
# $REPO. Anything that ends this script before that -- codex failing, the harness
# failing, this file being edited underneath a running shell -- keeps the clone and
# PRINTS its path, which is what this script's own header already promised:
# "a session that produced work but did not commit is a SUCCESS whose handoff failed
# -- never discard it". MEASURED the same day, three sessions, two packages lost: a
# shared-script edit landed mid-run, the shell resumed at a stale byte offset and died
# AFTER codex had finished, and this trap then rm -rf'd the clone holding the finished
# work. Deleting on the happy path only costs a temp directory; deleting on the sad
# path costs the session.
LANDED=0
cleanup() {
  if [[ "$KEEP" == "1" ]]; then
    echo "[codex-implement] --keep: clone left at $WORK" >&2
    register_work kept "--keep: clone left for inspection; remove it when done: rm -rf \"$WORK\""
  elif [[ "$LANDED" == "1" ]]; then
    rm -rf "$WORK"
    [[ -e "$WORK" ]] || register_work removed "branch $BRANCH fetched into $REPO; clone removed"
  else
    register_work kept-unlanded "recover with: git -C \"$REPO\" fetch \"$WORK\" \"$BRANCH:$BRANCH\""
    echo "[codex-implement] WORK KEPT (the branch was never fetched): $WORK" >&2
    echo "[codex-implement]   recover with: git -C \"$REPO\" fetch \"$WORK\" \"$BRANCH:$BRANCH\"" >&2
    echo "[codex-implement]   (or inspect it there; nothing else will clean it up)" >&2
  fi
}
trap cleanup EXIT

echo "[codex-implement] cloning $REPO@$BASE -> $WORK (shared objects)" >&2
# --shared borrows objects from the parent instead of copying them: fast, small,
# and the clone still gets a REAL .git dir that the sandbox can write to.
# --no-checkout + explicit branch so we never carry the parent's HEAD state.
git clone --shared --quiet --no-checkout "$REPO" "$WORK"
# `clone` only creates a local branch for $REPO's own HEAD (its default
# branch); every other branch of $REPO -- including a non-default $BASE --
# lands in the clone only as origin/$BASE. Try $BASE directly first (covers
# the common --base dev case with zero behavior change), fall back to
# origin/$BASE (covers any other branch). $BASE already passed the
# rev-parse check against $REPO above, so one of the two must resolve here.
CLONE_BASE="$BASE"
git -C "$WORK" rev-parse --verify --quiet "$CLONE_BASE" >/dev/null \
  || CLONE_BASE="origin/$BASE"
git -C "$WORK" checkout --quiet -b "$BRANCH" "$CLONE_BASE"

echo "[codex-implement] codex exec model=$MODEL effort=$EFFORT (sandbox=$SANDBOX)" >&2
[[ "$SANDBOX" == "workspace-write" ]] || \
  echo "[codex-implement] WARNING: sandbox=$SANDBOX — this session is NOT isolated from the primary checkout" >&2
if [[ "$CANONICAL_RECALL" == "1" && "$SANDBOX_EXPLICIT" == "1" ]]; then
  echo "[codex-implement] --canonical-recall and an explicit --sandbox are mutually exclusive (Codex CLI: '--sandbox' cannot be used with '--approve-for-me')" >&2
  exit 2
fi
set +e
if [[ "$CANONICAL_RECALL" == "1" ]]; then
  echo "[codex-implement] canonical-recall: ENABLED — codex exec --approve-for-me (index MCP callable; sandbox forced to workspace-write; -s not passed); prompt names [\$$CANONICAL_RECALL_MCP_SERVER](mcp://$CANONICAL_RECALL_MCP_SERVER) so the turn waits for that server instead of sampling with an empty catalog" >&2
  # --approve-for-me makes the MCP CALLABLE; it does not make the server READY.
  # Codex >= 0.147 gives optional MCP servers a one-second startup grace and omits
  # whatever is still pending from that step's tool catalog (openai/codex#35742),
  # and this index needs 5.7-7.1s to answer `initialize` — so without the mention
  # below the session's first step sees no index tools and reports degraded recall
  # (measured 2026-09-19 on codex-review.sh, same mechanism, same flag).
  # READY is still not VISIBLE: code mode DEFERS MCP tools (absent from the exec
  # tool's description, present in ALL_TOOLS / tools.*), and a round told only that
  # the tools were "in your catalog" reported them unavailable without looking
  # (S2 R02, 2026-09-19) — so the note says where they are, as codex-review.sh does.
  TOOL_PREFIX="mcp__${CANONICAL_RECALL_MCP_SERVER//-/_}__"
  ( cd "$WORK" && { printf '%s\n' "Canonical-index MCP for this session: [\$$CANONICAL_RECALL_MCP_SERVER](mcp://$CANONICAL_RECALL_MCP_SERVER)
Its tools are DEFERRED: not listed in your exec tool's description, but callable. Find them inside exec with
  text(ALL_TOOLS.filter(x => x.name.startsWith(\"$TOOL_PREFIX\")).map(x => x.name));
and call them there, e.g. await tools.${TOOL_PREFIX}search_specs({query: \"...\", limit: 5}).
Only an empty result from that filter, or a failed call, means the index is unavailable.
"; cat "$PROMPT"; } | codex exec --skip-git-repo-check --approve-for-me \
      -c model="$MODEL" -c model_reasoning_effort="$EFFORT" ${PROJECT_DOC_C[@]+"${PROJECT_DOC_C[@]}"} - )
else
  echo "[codex-implement] canonical-recall: disabled (default) — codex exec -s $SANDBOX; index MCP calls will be refused" >&2
  ( cd "$WORK" && codex exec --skip-git-repo-check -s "$SANDBOX" \
      -c model="$MODEL" -c model_reasoning_effort="$EFFORT" ${PROJECT_DOC_C[@]+"${PROJECT_DOC_C[@]}"} \
      - < "$PROMPT" )
fi
RC=$?
set -e

# Commit anything the session left unstaged. A session that finished its work
# but did not commit is a SUCCESS whose handoff failed — never discard it.
if [[ -n "$(git -C "$WORK" status --porcelain)" ]]; then
  echo "[codex-implement] session left uncommitted changes; committing them" >&2
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "wip(${BRANCH}): codex session output (uncommitted at exit)"
fi

if [[ "$(git -C "$WORK" rev-parse HEAD)" == "$(git -C "$WORK" rev-parse "$CLONE_BASE")" ]]; then
  echo "[codex-implement] NO COMMITS — session produced no changes (rc=$RC)" >&2
  exit "${RC:-1}"
fi

# Land the branch back in the source repo. Objects are shared, so this is a
# ref update, not a copy. The source repo's working tree is never touched.
git -C "$REPO" fetch --quiet "$WORK" "$BRANCH:$BRANCH"
LANDED=1   # the work is in $REPO now; only from here may cleanup delete the clone
echo "[codex-implement] branch '$BRANCH' fetched into $REPO:" >&2
git -C "$REPO" log --oneline "$BASE..$BRANCH" >&2
echo "[codex-implement] codex rc=$RC" >&2
exit "$RC"
exit
}
