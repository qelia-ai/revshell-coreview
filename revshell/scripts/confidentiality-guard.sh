#!/usr/bin/env bash
# confidentiality-guard.sh — preflight gate for revshell backends that send code
# OFF-MACHINE to a third-party inference API.
#
# Rationale: the `code` phase of a revshell round ships the COMPLETE unified diff
# to the reviewer. For a local backend (Ollama/MLX) that is harmless. For a hosted
# backend it is an egress event, and some of this machine's repos must never be
# the source of one.
#
# Currently wired into: qwen-review.sh when the machine's regular `qwen` CLI may send
# the prompt off-machine. codex-review.sh / agy-review.sh may adopt it by sourcing
# this file and calling revshell_guard_preflight the same way.
#
# Contract: call revshell_guard_preflight AFTER the prompt file is fully built and
# IMMEDIATELY BEFORE invoking the backend. It exits non-zero (6) on a violation;
# it never returns a "soft" warning, because a warning nobody reads is not a gate.
#
# Three independent checks:
#   A. repo REMOTE matches a confidential org      -> override REVSHELL_ALLOW_CONFIDENTIAL_SOURCE=1
#   B. repo PATH sits under a confidential root    -> override REVSHELL_ALLOW_CONFIDENTIAL_SOURCE=1
#   C. prompt body carries credential-shaped text  -> override REVSHELL_ALLOW_SECRETS_IN_PROMPT=1
#
# Overrides are deliberately separate: "this repo is fine to review remotely" is a
# very different judgement from "yes, really send that credential".

# Where this machine declares what is confidential. A shell file, sourced if present; it may set
# REVSHELL_CONFIDENTIAL_PATHS and REVSHELL_CONFIDENTIAL_REMOTES. The environment wins over the file,
# and the file wins over the (empty) defaults below, so a fresh install blocks nothing by path or
# remote until its owner says what is confidential. Credential patterns (check C) always apply.
REVSHELL_GUARD_CONF="${REVSHELL_GUARD_CONF:-$HOME/.config/revshell/guard.conf}"
_rg_env_paths_set=0; _rg_env_remotes_set=0
if [ "${REVSHELL_CONFIDENTIAL_PATHS+x}" = x ]; then
  _rg_env_paths_set=1; _rg_env_paths="$REVSHELL_CONFIDENTIAL_PATHS"
fi
if [ "${REVSHELL_CONFIDENTIAL_REMOTES+x}" = x ]; then
  _rg_env_remotes_set=1; _rg_env_remotes="$REVSHELL_CONFIDENTIAL_REMOTES"
fi
# shellcheck disable=SC1090
[ -f "$REVSHELL_GUARD_CONF" ] && . "$REVSHELL_GUARD_CONF"
[ "$_rg_env_paths_set" = 1 ] && REVSHELL_CONFIDENTIAL_PATHS="$_rg_env_paths"
[ "$_rg_env_remotes_set" = 1 ] && REVSHELL_CONFIDENTIAL_REMOTES="$_rg_env_remotes"

# Colon-separated path roots whose contents must never leave the machine (example:
# "$HOME/clients:$HOME/private"). Empty = no path root declared.
REVSHELL_CONFIDENTIAL_PATHS="${REVSHELL_CONFIDENTIAL_PATHS:-}"

# ERE matched against `git remote -v` output (example: 'git\.client\.example|[:/]client-repo(\.git)?').
# Match the REPO NAME as well as the host: a repo that moved to a personal remote stops matching an
# org pattern while still holding the same code (measured once: a round streamed a confidential diff
# to a hosted endpoint with "preflight OK" after exactly such a move). Worktrees inherit the remote,
# so a name match covers them too. Empty = no remote declared.
REVSHELL_CONFIDENTIAL_REMOTES="${REVSHELL_CONFIDENTIAL_REMOTES:-}"

# Credential-shaped patterns. Over-blocking is correct here: a false positive costs
# one env-var override, a false negative leaks a live secret to a third party.
# 2026-10-20: sk- needs a left boundary; it matched a file name ending in "sk-" followed by a long slug, blocking every round whose diff names it (see test-guard-sk-boundary.sh).
revshell_guard_secret_patterns() {
  cat <<'PATEOF'
(^|[^A-Za-z0-9])sk-[A-Za-z0-9_.-]{20,}
gh[pousr]_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{20,}
AKIA[0-9A-Z]{16}
xox[baprs]-[A-Za-z0-9-]{10,}
-----BEGIN [A-Z ]*PRIVATE KEY-----
"private_key"[[:space:]]*:
AIza[0-9A-Za-z_-]{35}
eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.
[Bb]earer[[:space:]]+[A-Za-z0-9._-]{24,}
PATEOF
}

# revshell_guard_preflight <backend-label> <repo-dir> <prompt-file>
revshell_guard_preflight() {
  local backend="$1" repo="$2" prompt_file="$3"
  local blocked=0

  # ---- A. confidential remote ------------------------------------------------
  local remotes=""
  if [ -d "$repo" ]; then
    remotes="$(git -C "$repo" remote -v 2>/dev/null || true)"
  fi
  if [ -n "$remotes" ] && [ -n "$REVSHELL_CONFIDENTIAL_REMOTES" ] && printf '%s' "$remotes" \
       | grep -qiE "$REVSHELL_CONFIDENTIAL_REMOTES"; then
    if [ "${REVSHELL_ALLOW_CONFIDENTIAL_SOURCE:-0}" = "1" ]; then
      echo "guard[$backend]: WARNING — confidential remote, sending anyway (REVSHELL_ALLOW_CONFIDENTIAL_SOURCE=1)" >&2
    else
      echo "guard[$backend]: BLOCKED — repo remote matches a confidential org." >&2
      echo "guard[$backend]:   repo: $repo" >&2
      echo "guard[$backend]:   This code must not be sent to a hosted third-party model." >&2
      echo "guard[$backend]:   Use a Claude subagent (no hosted third-party hop)." >&2
      blocked=1
    fi
  fi

  # ---- B. confidential path root ---------------------------------------------
  local repo_abs root
  repo_abs="$(cd "$repo" 2>/dev/null && pwd -P || printf '%s' "$repo")"
  local saved_ifs="$IFS"
  IFS=':'
  for root in $REVSHELL_CONFIDENTIAL_PATHS; do
    [ -n "$root" ] || continue
    local root_abs
    root_abs="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"
    case "$repo_abs/" in
      "$root_abs"/*)
        IFS="$saved_ifs"
        if [ "${REVSHELL_ALLOW_CONFIDENTIAL_SOURCE:-0}" = "1" ]; then
          echo "guard[$backend]: WARNING — confidential path, sending anyway (REVSHELL_ALLOW_CONFIDENTIAL_SOURCE=1)" >&2
        else
          echo "guard[$backend]: BLOCKED — repo lives under confidential root: $root_abs" >&2
          echo "guard[$backend]:   repo: $repo_abs" >&2
          blocked=1
        fi
        IFS=':'
        ;;
    esac
  done
  IFS="$saved_ifs"

  # ---- C. credential-shaped content in the outgoing prompt --------------------
  # Report the pattern that fired and the line number ONLY — never the match itself,
  # or the guard would leak the very thing it is protecting into the console/logs.
  local hits=0 pat lines
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # `|| true` is load-bearing: callers run under `set -euo pipefail`, and a
    # NON-matching grep returns 1, which would abort the scan at the first pattern
    # that finds nothing — silently skipping every later pattern.
    lines="$(grep -nE "$pat" "$prompt_file" 2>/dev/null | cut -d: -f1 | tr '\n' ',' | sed 's/,$//' || true)"
    if [ -n "$lines" ]; then
      echo "guard[$backend]: credential-shaped match /$pat/ at prompt line(s): $lines" >&2
      hits=$((hits + 1))
    fi
  done <<EOF
$(revshell_guard_secret_patterns)
EOF

  if [ "$hits" -gt 0 ]; then
    if [ "${REVSHELL_ALLOW_SECRETS_IN_PROMPT:-0}" = "1" ]; then
      echo "guard[$backend]: WARNING — $hits credential pattern(s) present, sending anyway (REVSHELL_ALLOW_SECRETS_IN_PROMPT=1)" >&2
    else
      echo "guard[$backend]: BLOCKED — $hits credential-shaped pattern(s) in the outgoing prompt." >&2
      echo "guard[$backend]:   Scrub the diff, or set REVSHELL_ALLOW_SECRETS_IN_PROMPT=1 if these are fixtures." >&2
      blocked=1
    fi
  fi

  if [ "$blocked" -ne 0 ]; then
    echo "guard[$backend]: preflight FAILED — nothing was sent." >&2
    exit 6
  fi

  echo "guard[$backend]: preflight OK (remote+path clean, no credential patterns)." >&2
}
