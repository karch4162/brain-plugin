#!/usr/bin/env bash
# test-wave.sh — the wave plugin's per-repo config contract.
#
# Wave runs in any repo, so everything project-specific comes from the target
# repo's .claude/wave/config.env (+ optional notes.md). This suite pins that:
# no config fails loudly; the worker prompt carries the configured tracker,
# states, base branch and project notes; the review/tiebreak paths it hands the
# worker are absolute and exist (a worker runs in another session, where a
# repo-relative path to a plugin script is empty); triage reads Jira JSON.
#
# Run:  bash tests/test-wave.sh   (from anywhere)
# No network, no Orca: only DRY_RUN and triage's no-model path are exercised.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
WAVE="$REPO_ROOT/wave/skills/wave"

PASSED=0
FAILED=0
TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1"
  shift
  local l
  for l in "$@"; do echo "     $l"; done
}
assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]"; fi
}
assert_contains() { # name haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to contain: [$3]" "actual: [$2]"; fi
}
assert_not_contains() { # name haystack needle
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "expected NOT to contain: [$3]"; fi
}

if ! command -v python >/dev/null 2>&1; then
  echo "SKIP: no python on PATH — wave's scripts use it for JSON." >&2
  exit 0
fi

# A scratch repo whose origin/HEAD points at origin/trunk, with the given config.
new_sandbox() { # config-body
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  git -C "$BOX" init -q -b trunk
  git -C "$BOX" config user.email t@t.t
  git -C "$BOX" config user.name t
  git -C "$BOX" commit -q --allow-empty -m initial
  git -C "$BOX" update-ref refs/remotes/origin/trunk HEAD
  git -C "$BOX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  if [[ -n "$1" ]]; then
    mkdir -p "$BOX/.claude/wave"
    printf '%s\n' "$1" >"$BOX/.claude/wave/config.env"
  fi
}

JIRA_CONFIG="WAVE_TRACKER=jira
WAVE_JIRA_SITE=example.atlassian.net
WAVE_QUEUE='project = ABC AND labels = agent-ready'
WAVE_STATE_START='In Progress'
WAVE_STATE_DONE='Validate'
WAVE_FILE_TO='Jira project ABC'"

spawn_dry() { # extra-env...
  (cd "$BOX" && env DRY_RUN=1 "$@" bash "$WAVE/spawn.sh" ABC-7) >"$BOX/out.txt" 2>&1
  echo $?
}

echo "--- 1. no config fails loudly and names the file ---"
new_sandbox ""
st="$(spawn_dry)"
assert_eq "no-config/exit-1" "1" "$st"
assert_contains "no-config/names-file" "$(cat "$BOX/out.txt")" ".claude/wave/config.env"

echo "--- 2. a missing required key is named ---"
new_sandbox "WAVE_TRACKER=jira"
st="$(spawn_dry)"
assert_eq "missing-key/exit-1" "1" "$st"
assert_contains "missing-key/names-key" "$(cat "$BOX/out.txt")" "WAVE_QUEUE"

echo "--- 3. jira config drives the worker prompt ---"
new_sandbox "$JIRA_CONFIG"
st="$(spawn_dry AUTO_SUCCESSOR=1)"
out="$(cat "$BOX/out.txt")"
assert_eq "jira/exit-0" "0" "$st"
assert_contains "jira/tracker-ops" "$out" "Atlassian MCP Jira tools (site example.atlassian.net)"
assert_contains "jira/start-state" "$out" "In Progress"
assert_contains "jira/done-state" "$out" "set the issue Validate"
assert_contains "jira/base-from-origin-head" "$out" "PR against trunk"
assert_contains "jira/queue-in-refill" "$out" "project = ABC AND labels = agent-ready"
assert_contains "jira/file-to" "$out" "File follow-ups to Jira project ABC"
assert_not_contains "jira/no-linear-verbs" "$out" "orca linear"

echo "--- 4. worker script paths are absolute and exist ---"
review_path="$(grep -o 'bash "[^"]*/review.sh"' <<<"$out" | head -1 | sed 's/^bash "//; s/"$//')"
assert_eq "paths/review-absolute" "/" "${review_path:0:1}"
if [[ -f "$review_path" ]]; then pass "paths/review-exists"; else fail "paths/review-exists" "not a file: [$review_path]"; fi

echo "--- 5. notes.md is appended as project rules ---"
printf 'Never touch the shared Supabase.\n' >"$BOX/.claude/wave/notes.md"
spawn_dry >/dev/null
assert_contains "notes/appended" "$(cat "$BOX/out.txt")" "Never touch the shared Supabase."

echo "--- 6. linear config uses orca linear, no successor by default ---"
new_sandbox "WAVE_TRACKER=linear
WAVE_QUEUE='team SPO, label agent-ready'
WAVE_STATE_START='In Progress'
WAVE_STATE_DONE=Done
WAVE_FILE_TO='team SPO'
WAVE_BASE=origin/development"
spawn_dry >/dev/null
out="$(cat "$BOX/out.txt")"
assert_contains "linear/tracker-ops" "$out" "orca linear"
assert_contains "linear/base-override" "$out" "PR against development"
assert_contains "linear/no-successor" "$out" "Do NOT spawn a successor"

echo "--- 7. triage reads a saved Jira search result ---"
new_sandbox "$JIRA_CONFIG"
cat >"$BOX/issues.json" <<'EOF'
{"issues":{"nodes":[{"key":"ABC-1","fields":{"summary":"First thing","description":"no refs here","labels":["agent-ready"]}},
{"key":"ABC-2","fields":{"summary":"Second thing","description":"still none"}}]}}
EOF
out="$(cd "$BOX" && bash "$WAVE/triage.sh" --json issues.json 2>&1)"
assert_contains "triage/row-1" "$out" "| ABC-1 | - | no file:line cited | First thing |"
assert_contains "triage/row-2" "$out" "| ABC-2 | - | no file:line cited | Second thing |"

echo "--- 8. triage refuses to shell-fetch jira ids ---"
out="$(cd "$BOX" && bash "$WAVE/triage.sh" ABC-1 2>&1)"; st=$?
assert_eq "triage-jira-ids/exit-2" "2" "$st"
assert_contains "triage-jira-ids/says-json" "$out" "--json"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
