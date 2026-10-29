#!/usr/bin/env bash
# Deterministic, network-free checks for the revshell driver runtime and verdict contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=review-runtime.sh
. "$SCRIPT_DIR/review-runtime.sh"

TEST_ROOT="$(mktemp -d -t revshell-driver-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -F "$expected" "$file" >/dev/null || fail "expected '$expected' in $file"
}

assert_last_line() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(tail -n 1 "$file")"
  [ "$actual" = "$expected" ] || fail "expected last line '$expected' in $file, got '$actual'"
}

process_is_live_non_zombie() {
  local pid="$1"
  local state
  kill -0 "$pid" 2>/dev/null || return 1
  state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  case "$state" in
    ''|Z*) return 1 ;;
    *) return 0 ;;
  esac
}

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/repo" "$TEST_ROOT/barrier"
printf '# Plan A\n' > "$TEST_ROOT/plan-a.md"
printf '# Plan B\n' > "$TEST_ROOT/plan-b.md"

cat > "$TEST_ROOT/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
last_message=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) last_message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$last_message" ] || exit 91
touch "$REVSHELL_TEST_BARRIER_DIR/$REVSHELL_TEST_STUB_NAME.ready"
attempt=0
while [ ! -f "$REVSHELL_TEST_BARRIER_DIR/$REVSHELL_TEST_STUB_PEER.ready" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 50 ] || exit 92
  sleep 0.1
done
sleep 2
printf '%s\n' \
  'REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none' \
  'VERDICT: ready for implementation'
printf '%s\n' \
  'REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none' \
  'VERDICT: ready for implementation' > "$last_message"
STUB

cat > "$TEST_ROOT/bin/agy" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
sleep 2
printf '%s\n' \
  'REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none' \
  'VERDICT: ready for implementation'
STUB

cat > "$TEST_ROOT/bin/qwen" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# The driver passes a prompt INLINE with `-p "<prompt>"` when it is short, and on stdin
# with `-p ""` when it is long. This stub used to read stdin only, so once inline prompts
# landed it captured an empty prompt and the prompt assertions below failed.
inline=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) inline="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "${REVSHELL_TEST_QWEN_PROMPT:-}" ]; then
  if [ -n "$inline" ]; then printf '%s' "$inline" > "$REVSHELL_TEST_QWEN_PROMPT"; else cat > "$REVSHELL_TEST_QWEN_PROMPT"; fi
elif [ -z "$inline" ]; then
  cat >/dev/null
fi
[ -z "${REVSHELL_TEST_QWEN_PIDFILE:-}" ] || printf '%s\n' "$$" > "$REVSHELL_TEST_QWEN_PIDFILE"
sleep "${REVSHELL_TEST_QWEN_SLEEP:-2}"
printf '%s\n' '{"type":"result","is_error":false,"result":"REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none\nVERDICT: ready for implementation"}'
STUB

cat > "$TEST_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# With REVSHELL_TEST_STATUS_SCRIPT set, the failover proxy's status URL is served from
# that file: one line per call, the last line repeating; a line reading DOWN means the
# proxy did not answer. Every other request keeps the original behaviour.
url=""
for arg in "$@"; do case "$arg" in http*) url="$arg" ;; esac; done
case "$url" in
  *__failover/status*)
    if [ -n "${REVSHELL_TEST_STATUS_SCRIPT:-}" ]; then
      calls="${REVSHELL_TEST_STATUS_SCRIPT}.calls"
      n=$(( $(cat "$calls" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$n" > "$calls"
      total="$(wc -l < "$REVSHELL_TEST_STATUS_SCRIPT" | tr -d '[:space:]')"
      [ "$n" -le "$total" ] || n="$total"
      line="$(sed -n "${n}p" "$REVSHELL_TEST_STATUS_SCRIPT")"
      [ "$line" != "DOWN" ] || exit 7
      printf '%s\n' "$line"
      exit 0
    fi
    ;;
esac
sleep 2
printf '%s\n' '{"response":"REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none\nVERDICT: ready for implementation"}'
STUB

chmod +x "$TEST_ROOT/bin/codex" "$TEST_ROOT/bin/agy" "$TEST_ROOT/bin/qwen" "$TEST_ROOT/bin/curl"

# Two complete Codex-driver calls must overlap without shared locks or output files.
set +e
env PATH="$TEST_ROOT/bin:$PATH" \
  REVSHELL_HEARTBEAT_SECONDS=1 \
  REVSHELL_TEST_BARRIER_DIR="$TEST_ROOT/barrier" \
  REVSHELL_TEST_STUB_NAME=a \
  REVSHELL_TEST_STUB_PEER=b \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" --timeout 8 \
    > "$TEST_ROOT/codex-a.out" 2> "$TEST_ROOT/codex-a.err" &
codex_a_pid=$!
env PATH="$TEST_ROOT/bin:$PATH" \
  REVSHELL_HEARTBEAT_SECONDS=1 \
  REVSHELL_TEST_BARRIER_DIR="$TEST_ROOT/barrier" \
  REVSHELL_TEST_STUB_NAME=b \
  REVSHELL_TEST_STUB_PEER=a \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-b.md" --phase plan --repo "$TEST_ROOT/repo" --timeout 8 \
    > "$TEST_ROOT/codex-b.out" 2> "$TEST_ROOT/codex-b.err" &
codex_b_pid=$!
codex_a_rc=0
codex_b_rc=0
wait "$codex_a_pid" || codex_a_rc=$?
wait "$codex_b_pid" || codex_b_rc=$?
set -e
[ "$codex_a_rc" -eq 0 ] || fail "first concurrent Codex driver exited $codex_a_rc"
[ "$codex_b_rc" -eq 0 ] || fail "second concurrent Codex driver exited $codex_b_rc"

assert_contains "$TEST_ROOT/codex-a.err" "reviewer started"
assert_contains "$TEST_ROOT/codex-a.err" "other invocations remain concurrent"
assert_contains "$TEST_ROOT/codex-a.err" "reviewer still running"
assert_contains "$TEST_ROOT/codex-a.err" "reviewer finished"
assert_contains "$TEST_ROOT/codex-b.err" "reviewer still running"
assert_last_line "$TEST_ROOT/codex-a.out" "VERDICT: ready for implementation"
assert_last_line "$TEST_ROOT/codex-b.out" "VERDICT: ready for implementation"
if grep -F '[revshell:' "$TEST_ROOT/codex-a.out" "$TEST_ROOT/codex-b.out" >/dev/null; then
  fail "progress leaked into verdict stdout"
fi

codex_a_id="$(sed -n 's/^\[revshell:\([^]]*\)\] reviewer started.*/\1/p' "$TEST_ROOT/codex-a.err" | sed -n '1p')"
codex_b_id="$(sed -n 's/^\[revshell:\([^]]*\)\] reviewer started.*/\1/p' "$TEST_ROOT/codex-b.err" | sed -n '1p')"
[ -n "$codex_a_id" ] || fail "first Codex invocation ID missing"
[ -n "$codex_b_id" ] || fail "second Codex invocation ID missing"
[ "$codex_a_id" != "$codex_b_id" ] || fail "concurrent Codex invocation IDs collided"
if grep -F "$codex_b_id" "$TEST_ROOT/codex-a.err" >/dev/null; then
  fail "second Codex invocation leaked into first progress stream"
fi
if grep -F "$codex_a_id" "$TEST_ROOT/codex-b.err" >/dev/null; then
  fail "first Codex invocation leaked into second progress stream"
fi

# The sibling drivers share the same stderr progress runtime and verdict contract.
env PATH="$TEST_ROOT/bin:$PATH" REVSHELL_HEARTBEAT_SECONDS=1 \
  bash "$SCRIPT_DIR/agy-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" --timeout 8 \
    > "$TEST_ROOT/agy.out" 2> "$TEST_ROOT/agy.err"
assert_contains "$TEST_ROOT/agy.err" "reviewer started"
assert_contains "$TEST_ROOT/agy.err" "reviewer still running"
assert_last_line "$TEST_ROOT/agy.out" "VERDICT: ready for implementation"

env PATH="$TEST_ROOT/bin:$PATH" REVSHELL_HEARTBEAT_SECONDS=1 \
  REVSHELL_TEST_QWEN_PROMPT="$TEST_ROOT/qwen.prompt" \
  bash "$SCRIPT_DIR/qwen-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" --timeout 8 \
    > "$TEST_ROOT/qwen.out" 2> "$TEST_ROOT/qwen.err"
assert_contains "$TEST_ROOT/qwen.err" "reviewer started"
assert_contains "$TEST_ROOT/qwen.err" "reviewer still running"
assert_last_line "$TEST_ROOT/qwen.out" "VERDICT: ready for implementation"
assert_contains "$TEST_ROOT/qwen.prompt" '`create_sub_session`, `loop_wakeup`'
assert_contains "$TEST_ROOT/qwen.prompt" "Do NOT attempt, request,"

# ---- the metered kill switch (the owner, 2026-09-16: "Qwen, with a kill switch") ----
status_json() {
  printf '{"activeUpstream":"%s","tiers":[{"name":"token-plan-2","requests":10},{"name":"on-demand","requests":%s}]}\n' "$1" "$2"
}
CASE_RC=0
run_qwen_case() {
  local name="$1"; shift
  set +e
  env PATH="$TEST_ROOT/bin:$PATH" REVSHELL_HEARTBEAT_SECONDS=0 REVSHELL_TERM_GRACE_SECONDS=1 \
    QWEN_METERED_KILL_POLL_SECONDS=1 \
    REVSHELL_TEST_STATUS_SCRIPT="$TEST_ROOT/$name.status" \
    REVSHELL_TEST_QWEN_PIDFILE="$TEST_ROOT/$name.qwen.pid" \
    "$@" \
    bash "$SCRIPT_DIR/qwen-review.sh" \
      --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" --timeout 60 \
      > "$TEST_ROOT/$name.out" 2> "$TEST_ROOT/$name.err"
  CASE_RC=$?
  set -e
}
assert_qwen_stopped() {
  local name="$1" pid attempt=0
  [ -s "$TEST_ROOT/$name.qwen.pid" ] || fail "$name: the qwen stub never started"
  pid="$(sed -n '1p' "$TEST_ROOT/$name.qwen.pid")"
  while process_is_live_non_zombie "$pid"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || fail "$name: the kill switch left qwen $pid alive"
    sleep 0.1
  done
}

# A metered request mid-round stops the round (exit 7) and leaves no reviewer alive.
{ status_json token-plan-2 5; status_json token-plan-2 5; status_json token-plan-2 6; } > "$TEST_ROOT/rise.status"
run_qwen_case rise REVSHELL_TEST_QWEN_SLEEP=30
[ "$CASE_RC" -eq 7 ] || fail "metered request mid-round: expected exit 7, got $CASE_RC"
assert_contains "$TEST_ROOT/rise.err" "STOPPED MID-ROUND by the metered kill switch"
assert_contains "$TEST_ROOT/rise.err" "rose from 5 to 6"
assert_qwen_stopped rise

# The active upstream turning metered mid-round stops it too.
{ status_json token-plan-2 5; status_json on-demand 5; } > "$TEST_ROOT/flip.status"
run_qwen_case flip REVSHELL_TEST_QWEN_SLEEP=30
[ "$CASE_RC" -eq 7 ] || fail "active upstream turned metered: expected exit 7, got $CASE_RC"
assert_contains "$TEST_ROOT/flip.err" "the active upstream became 'on-demand'"
assert_qwen_stopped flip

# A status that stops answering mid-round is not a free pass: stopped after 3 polls.
{ status_json token-plan-2 5; printf 'DOWN\n'; } > "$TEST_ROOT/down.status"
run_qwen_case down REVSHELL_TEST_QWEN_SLEEP=30
[ "$CASE_RC" -eq 7 ] || fail "status unreadable mid-round: expected exit 7, got $CASE_RC"
assert_contains "$TEST_ROOT/down.err" "unreadable for 3 polls in a row"
assert_qwen_stopped down

# Refused before starting: the metered tier is already active.
status_json on-demand 5 > "$TEST_ROOT/active.status"
run_qwen_case active
[ "$CASE_RC" -eq 3 ] || fail "metered tier active at start: expected exit 3, got $CASE_RC"
assert_contains "$TEST_ROOT/active.err" "REFUSING TO RUN"
[ ! -s "$TEST_ROOT/active.qwen.pid" ] || fail "a refused round still started qwen"

# Refused before starting: the proxy answers but its metered count cannot be read.
printf 'not json\n' > "$TEST_ROOT/garbage.status"
run_qwen_case garbage
[ "$CASE_RC" -eq 3 ] || fail "unreadable status at start: expected exit 3, got $CASE_RC"
assert_contains "$TEST_ROOT/garbage.err" "cannot be read"
[ ! -s "$TEST_ROOT/garbage.qwen.pid" ] || fail "a refused round still started qwen"

# A steady subscription tier: the switch arms, never fires, and the verdict stands.
status_json token-plan-2 5 > "$TEST_ROOT/steady.status"
run_qwen_case steady REVSHELL_TEST_QWEN_SLEEP=3
[ "$CASE_RC" -eq 0 ] || fail "steady subscription tier: expected exit 0, got $CASE_RC"
assert_contains "$TEST_ROOT/steady.err" "metered kill switch armed"
assert_last_line "$TEST_ROOT/steady.out" "VERDICT: ready for implementation"

# The deliberate override still works, and is the only way past the switch.
{ status_json token-plan-2 5; status_json token-plan-2 9; } > "$TEST_ROOT/bypass.status"
run_qwen_case bypass QWEN_ALLOW_METERED=1 REVSHELL_TEST_QWEN_SLEEP=3
[ "$CASE_RC" -eq 0 ] || fail "QWEN_ALLOW_METERED=1: expected exit 0, got $CASE_RC"

# Every backend prompt includes the shared no-delegation constraint. Qwen's prompt is
# captured end-to-end above; these source checks ensure the other drivers inject it too.
for driver in codex-review.sh agy-review.sh qwen-review.sh; do
  assert_contains "$SCRIPT_DIR/$driver" "Do NOT spawn, delegate to, or wait on agents,"
done

# write_canonical_recall_contract() is deliberately duplicated verbatim across all three
# drivers rather than assembled from a shared fragment (the "one prompt is one authored
# file" rule's own sanctioned resolution for shared prompt text: byte-identical copies,
# enforced by a test). Extract each copy's function body and assert all three match.
extract_canonical_recall_contract() {
  local file="$1"
  awk '/^write_canonical_recall_contract\(\) \{/{flag=1} flag{print} flag && /^}/{exit}' "$file"
}

codex_contract="$(extract_canonical_recall_contract "$SCRIPT_DIR/codex-review.sh")"
agy_contract="$(extract_canonical_recall_contract "$SCRIPT_DIR/agy-review.sh")"
qwen_contract="$(extract_canonical_recall_contract "$SCRIPT_DIR/qwen-review.sh")"

[ -n "$codex_contract" ] || fail "write_canonical_recall_contract() not found in codex-review.sh"
[ -n "$agy_contract" ]   || fail "write_canonical_recall_contract() not found in agy-review.sh"
[ -n "$qwen_contract" ]  || fail "write_canonical_recall_contract() not found in qwen-review.sh"

[ "$codex_contract" = "$agy_contract" ]  || fail "write_canonical_recall_contract() diverged: codex-review.sh != agy-review.sh"
[ "$codex_contract" = "$qwen_contract" ] || fail "write_canonical_recall_contract() diverged: codex-review.sh != qwen-review.sh"
[ "$agy_contract" = "$qwen_contract" ]   || fail "write_canonical_recall_contract() diverged: agy-review.sh != qwen-review.sh"

# A --canonical-recall Codex round MUST name the index server as `[$name](mcp://name)` in
# its prompt. That mention is the only thing that makes Codex finish starting an optional
# MCP server before the round's first model request: without it the server is still
# pending when the tool catalog is captured (one-second grace, openai/codex#35742) and the
# reviewer reports "the canonical-index MCP was unavailable" and reviews on the fallback —
# measured twice on 2026-09-19. A default round must NOT carry it, because its MCP calls
# are refused by the approval policy anyway.
mkdir -p "$TEST_ROOT/bin-mcp"
cat > "$TEST_ROOT/bin-mcp/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
last_message=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) last_message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$last_message" ] || exit 91
cat > "${REVSHELL_TEST_CODEX_PROMPT:-/dev/null}"
# Real codex exec prints one "mcp: <server>/<tool> …" progress line per MCP call.
[ -z "${REVSHELL_TEST_CODEX_MCP_LINE:-}" ] || printf '%s\n' "$REVSHELL_TEST_CODEX_MCP_LINE" >&2
printf '%s\n' 'VERDICT: ready for implementation' | tee "$last_message"
STUB
chmod +x "$TEST_ROOT/bin-mcp/codex"

env PATH="$TEST_ROOT/bin-mcp:$PATH" REVSHELL_HEARTBEAT_SECONDS=0 \
  REVSHELL_TEST_CODEX_PROMPT="$TEST_ROOT/codex-recall.prompt" \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" \
    --canonical-recall > "$TEST_ROOT/codex-recall.out" 2> "$TEST_ROOT/codex-recall.err" \
  || fail "--canonical-recall round exited non-zero"
assert_contains "$TEST_ROOT/codex-recall.prompt" '](mcp://acme-agent-index)'
assert_contains "$TEST_ROOT/codex-recall.err" 'mcp://acme-agent-index'

env PATH="$TEST_ROOT/bin-mcp:$PATH" REVSHELL_HEARTBEAT_SECONDS=0 \
  REVSHELL_TEST_CODEX_PROMPT="$TEST_ROOT/codex-default.prompt" \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" \
    > "$TEST_ROOT/codex-default.out" 2> "$TEST_ROOT/codex-default.err" \
  || fail "default round exited non-zero"
grep -q 'mcp://' "$TEST_ROOT/codex-default.prompt" \
  && fail "a default (no --canonical-recall) round must not name an mcp:// server"

# The mention makes the server READY; it does not make its tools VISIBLE. In Codex code
# mode MCP tools are DEFERRED — omitted from the exec tool's description, reachable only
# through ALL_TOOLS / `tools.*` — so a reviewer that looks at its tool list sees nothing.
# Measured 2026-09-19, S2's R02 code round (session 01a0b9f7, 704 KB diff): Codex waited
# for the server (first request at +6.4s, the mention's signature), the reviewer never
# ran ALL_TOOLS, and replied "Canonical-index MCP was unavailable in the callable
# catalog" — which the previous wording invited ("Its tools are in your catalog … If you
# still cannot see them, say so"). The prompt must say WHERE the tools are, and it must
# say so BEFORE the diff: an oversized diff pushes the prompt past the model's window and
# Codex compacts the middle away, so only text near the top reliably survives.
mkdir -p "$TEST_ROOT/bigrepo"
git -C "$TEST_ROOT/bigrepo" init -q
git -C "$TEST_ROOT/bigrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
python3 -c 'import sys; sys.stdout.write("".join(f"row {i}: " + "x" * 90 + "\n" for i in range(7200)))' \
  > "$TEST_ROOT/bigrepo/big.txt"
git -C "$TEST_ROOT/bigrepo" add big.txt
env PATH="$TEST_ROOT/bin-mcp:$PATH" REVSHELL_HEARTBEAT_SECONDS=0 \
  REVSHELL_TEST_CODEX_PROMPT="$TEST_ROOT/codex-big.prompt" \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase code --repo "$TEST_ROOT/bigrepo" --base HEAD \
    --canonical-recall > "$TEST_ROOT/codex-big.out" 2> "$TEST_ROOT/codex-big.err" \
  || fail "--canonical-recall code round over an oversized diff exited non-zero"
big_bytes="$(wc -c < "$TEST_ROOT/codex-big.prompt" | tr -d '[:space:]')"
[ "$big_bytes" -gt 600000 ] || fail "oversized-diff fixture produced only $big_bytes prompt bytes"
assert_contains "$TEST_ROOT/codex-big.prompt" 'ALL_TOOLS.filter(x => x.name.startsWith("mcp__acme_agent_index__"))'
assert_contains "$TEST_ROOT/codex-big.prompt" 'tools.mcp__acme_agent_index__search_specs('
grep -q 'in your catalog from your FIRST step' "$TEST_ROOT/codex-big.prompt" \
  && fail "the recall note must not tell the reviewer its deferred tools are in its visible catalog"
python3 - "$TEST_ROOT/codex-big.prompt" <<'PY' || fail "the recall mention and discovery line must precede the diff"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
diff_at = text.index("=== UNIFIED DIFF")
for needle in ("](mcp://acme-agent-index)", 'ALL_TOOLS.filter(x => x.name.startsWith("mcp__acme_agent_index__"))'):
    at = text.find(needle)
    if at < 0 or at > diff_at:
        sys.exit(f"{needle!r} at {at}, diff at {diff_at}")
PY

# The server named in the mention is a parameter, not a hardcoded project.
env PATH="$TEST_ROOT/bin-mcp:$PATH" REVSHELL_HEARTBEAT_SECONDS=0 \
  COREVIEW_CANONICAL_RECALL_MCP_SERVER=other-index \
  REVSHELL_TEST_CODEX_PROMPT="$TEST_ROOT/codex-other.prompt" \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" \
    --canonical-recall > "$TEST_ROOT/codex-other.out" 2> "$TEST_ROOT/codex-other.err" \
  || fail "--canonical-recall round with an overridden server exited non-zero"
assert_contains "$TEST_ROOT/codex-other.prompt" '](mcp://other-index)'

# REPORT-ONLY: a prompt larger than the reviewer's context window is dispatched (never
# refused) but SAYS, on stderr and in the round's stdout, that Codex will compact it and
# the middle will go unreviewed. Measured 2026-09-19, S2's R02 (session 01a0b9f7):
# 279,536 input tokens against a 258,400 window; Codex compacted the user message to
# 284,969 of 802,880 chars and the review ran on what was left. The window is read from
# Codex's own model metadata ($CODEX_HOME/models_cache.json: context_window x
# effective_context_window_percent), so the fixture gives the test model a small one.
mkdir -p "$TEST_ROOT/codex-home-small"
cat > "$TEST_ROOT/codex-home-small/models_cache.json" <<'JSON'
{"models": [{"slug": "test-model", "context_window": 100000, "effective_context_window_percent": 95}]}
JSON
set +e
env PATH="$TEST_ROOT/bin-mcp:$PATH" REVSHELL_HEARTBEAT_SECONDS=0 \
  CODEX_HOME="$TEST_ROOT/codex-home-small" \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase code --repo "$TEST_ROOT/bigrepo" --base HEAD \
    --model test-model > "$TEST_ROOT/codex-window.out" 2> "$TEST_ROOT/codex-window.err"
window_rc=$?
set -e
[ "$window_rc" -eq 0 ] || fail "an over-window prompt must be dispatched and report, never refused (exit $window_rc)"
assert_contains "$TEST_ROOT/codex-window.err" "DIFF EXCEEDS THE REVIEWER'S WINDOW"
assert_contains "$TEST_ROOT/codex-window.err" "> 95000): Codex will compact it and the middle will go unreviewed. Split the diff."
assert_contains "$TEST_ROOT/codex-window.out" "DIFF EXCEEDS THE REVIEWER'S WINDOW"
assert_contains "$TEST_ROOT/codex-window.out" "VERDICT: ready for implementation"
env PATH="$TEST_ROOT/bin-mcp:$PATH" REVSHELL_HEARTBEAT_SECONDS=0 \
  CODEX_HOME="$TEST_ROOT/codex-home-small" \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" \
    --model test-model > "$TEST_ROOT/codex-small.out" 2> "$TEST_ROOT/codex-small.err" \
  || fail "a small round exited non-zero"
grep -q "EXCEEDS THE REVIEWER'S WINDOW" "$TEST_ROOT/codex-small.err" "$TEST_ROOT/codex-small.out" \
  && fail "a prompt inside the window must not report an overflow"

# REPORT-ONLY: a --canonical-recall round whose output has no "mcp: <server>/" line
# never called the index, whatever it says — S2's R02 replied "Canonical-index MCP was
# unavailable in the callable catalog" and nothing mechanical said so. The finished
# round reports it on stderr and in its stdout; it is never failed for it.
env PATH="$TEST_ROOT/bin-mcp:$PATH" REVSHELL_HEARTBEAT_SECONDS=0 \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" \
    --canonical-recall > "$TEST_ROOT/codex-blind.out" 2> "$TEST_ROOT/codex-blind.err" \
  || fail "a blind --canonical-recall round must still finish (report-only)"
assert_contains "$TEST_ROOT/codex-blind.err" "canonical recall requested but the round ran WITHOUT the index"
assert_contains "$TEST_ROOT/codex-blind.out" "canonical recall requested but the round ran WITHOUT the index"
env PATH="$TEST_ROOT/bin-mcp:$PATH" REVSHELL_HEARTBEAT_SECONDS=0 \
  REVSHELL_TEST_CODEX_MCP_LINE="mcp: acme-agent-index/search_specs (completed)" \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" \
    --canonical-recall > "$TEST_ROOT/codex-sighted.out" 2> "$TEST_ROOT/codex-sighted.err" \
  || fail "a --canonical-recall round that called the index exited non-zero"
grep -q "ran WITHOUT the index" "$TEST_ROOT/codex-sighted.err" "$TEST_ROOT/codex-sighted.out" \
  && fail "a round that called the index must not be reported blind"
grep -q "ran WITHOUT the index" "$TEST_ROOT/codex-default.err" "$TEST_ROOT/codex-default.out" \
  && fail "a default round (no --canonical-recall) must not be reported blind"

# Timeout escalation must return 124 and leave no live child in its process group.
child_pid_file="$TEST_ROOT/timeout-child.pid"
set +e
REVSHELL_HEARTBEAT_SECONDS=0 REVSHELL_TERM_GRACE_SECONDS=1 \
  revshell_run_with_timeout "timeout-cleanup-test" 1 \
    bash -c 'trap "" TERM; sleep 30 & child=$!; printf "%s\n" "$child" > "$1"; while :; do sleep 1; done' \
    _ "$child_pid_file" \
    > "$TEST_ROOT/timeout.out" 2> "$TEST_ROOT/timeout.err"
timeout_rc=$?
set -e
[ "$timeout_rc" -eq 124 ] || fail "timeout helper returned $timeout_rc instead of 124"
# The runner stopped saying "timed out" when it began stopping on SILENCE with an optional
# absolute ceiling; a one-second ceiling is reported as the ceiling.
assert_contains "$TEST_ROOT/timeout.err" "reviewer hit the ABSOLUTE CEILING"
[ -s "$child_pid_file" ] || fail "timeout child PID was not recorded"
timeout_child_pid="$(sed -n '1p' "$child_pid_file")"
attempt=0
while process_is_live_non_zombie "$timeout_child_pid"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail "timeout left child $timeout_child_pid alive"
  sleep 0.1
done

# Caller interruption must clean only this invocation's process group and return 143.
signal_child_pid_file="$TEST_ROOT/signal-child.pid"
(
  set +e
  REVSHELL_HEARTBEAT_SECONDS=0 REVSHELL_TERM_GRACE_SECONDS=1 \
    revshell_run_with_timeout "signal-cleanup-test" 20 \
      bash -c 'sleep 30 & child=$!; printf "%s\n" "$child" > "$1"; wait' \
      _ "$signal_child_pid_file" \
      > "$TEST_ROOT/signal.out" 2> "$TEST_ROOT/signal.err"
  exit $?
) &
signal_runner_pid=$!
attempt=0
while [ ! -s "$signal_child_pid_file" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 50 ]; then
    kill -TERM "$signal_runner_pid" 2>/dev/null || true
    fail "signal child PID was not recorded"
  fi
  sleep 0.1
done
kill -TERM "$signal_runner_pid"
signal_rc=0
wait "$signal_runner_pid" || signal_rc=$?
[ "$signal_rc" -eq 143 ] || fail "interrupted helper returned $signal_rc instead of 143"
assert_contains "$TEST_ROOT/signal.err" "reviewer failed"
signal_child_pid="$(sed -n '1p' "$signal_child_pid_file")"
attempt=0
while process_is_live_non_zombie "$signal_child_pid"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail "interruption left child $signal_child_pid alive"
  sleep 0.1
done

# Interruption in the launch window: the reviewer itself sends TERM to the helper's shell the
# instant it starts (a function child: no exec delay), i.e. before the unfixed helper had
# installed its traps. Every iteration must still return 143, log "reviewer failed" and leave
# nothing alive (2026-10-22: 6 of 40 interrupts lost the log and orphaned the reviewer group).
race_dir="$TEST_ROOT/launch-race"
mkdir -p "$race_dir"
for race_i in 1 2 3 4 5 6 7 8 9 10; do
  (
    set +e
    runner="$(exec sh -c 'echo $PPID')"  # bash 3.2 has no BASHPID
    race_reviewer() {
      kill -TERM "$runner"
      sleep 30 &
      printf '%s %s\n' "$(exec sh -c 'echo $PPID')" "$!" > "$race_dir/pids.$race_i"
      wait
    }
    REVSHELL_HEARTBEAT_SECONDS=0 REVSHELL_TERM_GRACE_SECONDS=1 \
      revshell_run_with_timeout "launch-race-$race_i" 20 race_reviewer \
      > "$race_dir/out.$race_i" 2> "$race_dir/err.$race_i"
    exit $?
  ) &
  race_runner_pid=$!
  race_rc=0
  wait "$race_runner_pid" || race_rc=$?
  [ "$race_rc" -eq 143 ] || { fail "launch-race $race_i: helper returned $race_rc instead of 143"; }
  assert_contains "$race_dir/err.$race_i" "reviewer failed"
done
sleep 0.5
for race_i in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$race_dir/pids.$race_i" ] || continue
  for race_pid in $(cat "$race_dir/pids.$race_i"); do
    if process_is_live_non_zombie "$race_pid"; then
      kill -KILL $(cat "$race_dir/pids.$race_i") 2>/dev/null || true
      fail "launch-race $race_i: interruption left reviewer process $race_pid alive"
    fi
  done
done

# ---- code phase: the diff is captured BEFORE the proxy pin rewrites a TRACKED .qwen/settings.json ----
# (2026-09-23, a product repo: the pin's own rewrite reached every code-phase prompt as a bogus deletion.)
pin_repo="$TEST_ROOT/pin-repo"
mkdir -p "$pin_repo/.qwen"
git -C "$pin_repo" init -q
printf '{"mcpServers":{"index":{"httpUrl":"https://example.invalid/mcp"}}}\n' > "$pin_repo/.qwen/settings.json"
printf 'one\n' > "$pin_repo/change.txt"
git -C "$pin_repo" add .qwen/settings.json change.txt
git -C "$pin_repo" -c user.email=t@example.invalid -c user.name=t commit -q -m base
printf 'two\n' > "$pin_repo/change.txt"
git -C "$pin_repo" -c user.email=t@example.invalid -c user.name=t commit -q -am change
status_json token-plan-2 5 > "$TEST_ROOT/pin.status"
set +e
env PATH="$TEST_ROOT/bin:$PATH" REVSHELL_HEARTBEAT_SECONDS=0 QWEN_METERED_KILL_POLL_SECONDS=1 \
  REVSHELL_TEST_STATUS_SCRIPT="$TEST_ROOT/pin.status" REVSHELL_TEST_QWEN_PROMPT="$TEST_ROOT/pin.prompt" \
  bash "$SCRIPT_DIR/qwen-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase code --repo "$pin_repo" --base HEAD~1 --timeout 60 \
    > "$TEST_ROOT/pin.out" 2> "$TEST_ROOT/pin.err"
set -e
assert_contains "$TEST_ROOT/pin.err" "workspace provider entry pinned to the proxy"
assert_contains "$TEST_ROOT/pin.prompt" "+two"
if grep -F ".qwen/settings.json" "$TEST_ROOT/pin.prompt" >/dev/null; then
  fail "code-phase diff contains the proxy pin's own rewrite of a tracked .qwen/settings.json"
fi
git -C "$pin_repo" diff --quiet -- .qwen/settings.json || fail "the pin did not restore the tracked .qwen/settings.json"

# A code review of an EMPTY diff is never a pass (2026-10-29, a product repo r2): a --base that is a CHILD of HEAD
# resolves to HEAD as the fork point; every driver must stop with exit 2 before launching a reviewer.
empty_repo="$TEST_ROOT/empty-diff-repo"
git init -q "$empty_repo"
printf 'one\n' > "$empty_repo/f"
git -C "$empty_repo" add f
git -C "$empty_repo" -c user.email=t@t -c user.name=t commit -qm one
empty_child="$(git -C "$empty_repo" commit-tree -p HEAD -m child 'HEAD^{tree}')"
for driver in codex-review.sh agy-review.sh qwen-review.sh; do
  set +e
  env PATH="$TEST_ROOT/bin:$PATH" REVSHELL_HEARTBEAT_SECONDS=0 \
    bash "$SCRIPT_DIR/$driver" --plan "$TEST_ROOT/plan-a.md" --phase code --repo "$empty_repo" --base "$empty_child" \
    > "$TEST_ROOT/empty-$driver.out" 2> "$TEST_ROOT/empty-$driver.err"
  empty_rc=$?
  set -e
  [ "$empty_rc" -eq 2 ] || fail "$driver reviewed an empty diff (exit $empty_rc, expected 2)"
  assert_contains "$TEST_ROOT/empty-$driver.err" "nothing to review"
done

printf 'PASS: revshell drivers (codex, agy, qwen) are observable, concurrent, verdict-safe, and timeout-clean\n'
