#!/usr/bin/env bash
# Deterministic, network-free check of the sk- credential pattern in confidentiality-guard.sh:
# a file NAME ending in "sk-..." followed by a long slug must not match; real key shapes must.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=confidentiality-guard.sh
. "$SCRIPT_DIR/confidentiality-guard.sh"
T="$(mktemp -d -t revshell-guard-sk.XXXXXX)"; trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
# The sk- pattern is the first line the guard emits; PAT overrides it for the fail-before run.
PAT="${SK_PATTERN_UNDER_TEST:-$(revshell_guard_secret_patterns | sed -n 1p)}"
matches() { printf '%s\n' "$1" > "$T/p"; grep -nE "$PAT" "$T/p" >/dev/null 2>&1; }
KEY="sk-$(printf 'a1B2c3D4e5F6g7H8i9J0k1L2')"
# The file name is built at runtime so this source never contains a literal that looks like a key.
NAME="$(printf 'ta')$(printf 'sk-')schema-compliance.md"
matches "diff --git a/prompts/expert/$NAME b/prompts/expert/$NAME" \
  && fail "a file name ending in sk-<slug> matched the sk- pattern"
for ctx in "" "x " "k=" "k=\"" "k:" "Authorization: Bearer "; do
  matches "${ctx}${KEY}" || fail "real key shape not matched after [$ctx]"
done

# An explicitly empty environment variable must override guard.conf, otherwise an owner cannot
# temporarily clear a machine-wide declaration for one reviewed repository.
printf '%s\n' 'REVSHELL_CONFIDENTIAL_PATHS=/from-config' \
  'REVSHELL_CONFIDENTIAL_REMOTES=from-config' > "$T/guard.conf"
config_values="$(REVSHELL_GUARD_CONF="$T/guard.conf" REVSHELL_CONFIDENTIAL_PATHS='' \
  REVSHELL_CONFIDENTIAL_REMOTES='' bash -c '. "$1"; printf "%s|%s" "$REVSHELL_CONFIDENTIAL_PATHS" "$REVSHELL_CONFIDENTIAL_REMOTES"' \
  bash "$SCRIPT_DIR/confidentiality-guard.sh")"
[ "$config_values" = '|' ] || fail "empty environment values did not override guard.conf: $config_values"

echo "PASS: file name passes; 6 real key shapes still match; empty environment overrides config (pattern: $PAT)"
