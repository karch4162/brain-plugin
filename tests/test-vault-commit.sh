#!/usr/bin/env bash
# test-vault-commit.sh — deterministic quality gate for brain/bin/vault-commit.sh
#
# vault-commit.sh is THE single commit path into a brain vault (INNOV-275). Every
# guard that used to live scattered across sync-graph.sh, plus the .saveinclude
# enforcement that used to be a line of prose in the /brain:save skill, is here.
# It exists because the guards were on the wrong side: sync-graph.sh carried six
# references' worth of protected-branch checking while /brain:save step 6 — the
# path that actually put a commit on protected `main` on 2026-08-05 — ran raw
# `git add` / `git commit` with nothing at all.
#
# Contract under test:
#   exit 0 => committed, or nothing to commit
#   exit 1 => REFUSED, and NOTHING was staged and NOTHING was committed
#   first line of output starts with `VAULT-COMMIT: OK`      (stdout)
#                                 or `VAULT-COMMIT: REFUSED` (stderr)
#   vault resolved from $BRAIN_ROOT -> $CLAUDE_PROJECT_DIR -> $PWD
#
# The refusals, and which flag (if any) overrides each:
#   protected/default branch  — NO override at all (INNOV-275 retired the old one)
#   open PR on this branch    — --force-commit overrides
#   HEAD moved since --pin    — NO override; a moved HEAD makes intent unknown
#   no/empty .saveinclude     — NO override; a vault with no allowlist has no
#                               permission model and there is no safe default
#   index holds a path the allowlist forbids — NO override; this is the one that
#                               makes "no command commits outside .saveinclude"
#                               a property rather than an intention, because the
#                               git index is shared by every session in the tree
#
# Run:  bash tests/test-vault-commit.sh   (from anywhere)
# No network. Real git repos in mktemp sandboxes; `gh` is a stub on PATH.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
GUARD="$REPO_ROOT/brain/bin/vault-commit.sh"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
cleanup() { chmod -R u+rwX "$TMPROOT" 2>/dev/null || true; rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------- helpers ---

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }

fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1"
  shift
  local line
  for line in "$@"; do
    echo "     $line"
  done
}

assert_eq() { # name expected actual [evidence...]
  local name="$1" exp="$2" act="$3"
  shift 3
  if [[ "$exp" == "$act" ]]; then
    pass "$name"
  else
    fail "$name" "expected: [$exp]" "actual:   [$act]" "$@"
  fi
}

assert_ne() { # name not-expected actual [evidence...]
  local name="$1" nexp="$2" act="$3"
  shift 3
  if [[ "$nexp" != "$act" ]]; then
    pass "$name"
  else
    fail "$name" "expected anything BUT: [$nexp]" "actual: [$act]" "$@"
  fi
}

assert_prefix() { # name prefix actual [evidence...]
  local name="$1" pre="$2" act="$3"
  shift 3
  if [[ "$act" == "$pre"* ]]; then
    pass "$name"
  else
    fail "$name" "expected line starting with: [$pre]" "actual line:                [$act]" "$@"
  fi
}

assert_contains() { # name needle haystack [evidence...]
  local name="$1" needle="$2" hay="$3"
  shift 3
  if [[ "$hay" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "expected to contain: [$needle]" "actual:              [$hay]" "$@"
  fi
}
assert_not_contains() { # name needle haystack [evidence...]
  local name="$1" needle="$2" hay="$3"
  shift 3
  if [[ "$hay" != *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected NOT to contain: [$needle]" "actual:                  [$hay]" "$@"; fi
}

# First line of a file, with any trailing CR stripped (Git Bash / CRLF safety).
first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

evidence() {
  echo "exit:   [$STATUS]"
  echo "stdout: [$(tr '\n' '|' <"$BOX/out.txt" 2>/dev/null)]"
  echo "stderr: [$(tr '\n' '|' <"$BOX/err.txt" 2>/dev/null)]"
}

# ------------------------------------------------------------ gh stubs -----
# `gh` is a safety net for the open-PR guard, never a dependency. Three PATHs:
#   GH_NONE — no gh at all ("cannot tell" must look exactly like "no PR")
#   GH_NOPR — gh answers, no open PR
#   GH_PR   — gh answers with open PR #4242 on any branch
GH_NONE="$TMPROOT/gh-none"
GH_NOPR="$TMPROOT/gh-nopr"
GH_PR="$TMPROOT/gh-pr"
mkdir -p "$GH_NONE" "$GH_NOPR" "$GH_PR"

cat >"$GH_NOPR/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  pr)   echo "" ;;
  repo) echo "" ;;
  *)    exit 1 ;;
esac
exit 0
SH
cat >"$GH_PR/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  pr)   echo "4242" ;;
  repo) echo "" ;;
  *)    exit 1 ;;
esac
exit 0
SH
chmod +x "$GH_NOPR/gh" "$GH_PR/gh"

# ------------------------------------------------------------ sandboxing ---

# Assigns the globals BOX / VAULT. Deliberately NOT run in a command
# substitution — the assignments would be lost and state would leak between
# cases (a previous harness in this repo made exactly that mistake).
BOX=""
VAULT=""

# A vault on branch $1 (default: a normal working branch) with one commit, a
# default .saveinclude, and wiki/ + logs/ + graphify/ populated.
sb_new() { # [branch]
  local branch="${1:-brain/work}"
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  VAULT="$BOX/vault"
  mkdir -p "$VAULT/wiki" "$VAULT/logs" "$VAULT/graphify/alpha"
  printf 'logs/\nwiki/hot.md\nwiki/log.md\ngraphify/\ngraphify-out/graph.json\n' >"$VAULT/.saveinclude"
  echo "hot" >"$VAULT/wiki/hot.md"
  echo "log" >"$VAULT/wiki/log.md"
  git -C "$VAULT" init -q -b main >/dev/null 2>&1
  git -C "$VAULT" config user.email t@example.com
  git -C "$VAULT" config user.name "T"
  git -C "$VAULT" config commit.gpgsign false
  git -C "$VAULT" add -A >/dev/null 2>&1
  git -C "$VAULT" commit -qm "initial vault" >/dev/null 2>&1
  [[ "$branch" == "main" ]] || git -C "$VAULT" checkout -q -B "$branch" >/dev/null 2>&1
}

# Makes an allowlisted file dirty so there is something to commit.
make_dirty() { echo "change $RANDOM" >>"$VAULT/wiki/log.md"; }

head_sha()     { git -C "$VAULT" rev-parse HEAD 2>/dev/null || true; }
head_subject() { git -C "$VAULT" log -1 --format=%s 2>/dev/null || true; }
staged_list()  { git -C "$VAULT" diff --cached --name-only 2>/dev/null; }
staged_count() { staged_list | grep -c . || true; }

STATUS=""
GH_PATH=""
# Runs the guard, capturing streams into $BOX/out.txt / $BOX/err.txt and the exit
# code into $STATUS. $GH_PATH (if set) is prepended to PATH for the gh stub.
run_guard() { # [args...]
  (
    cd "$VAULT" 2>/dev/null || cd "$BOX" || exit 127
    unset CLAUDE_PROJECT_DIR
    [[ -n "$GH_PATH" ]] && export PATH="$GH_PATH:$PATH"
    BRAIN_ROOT="$VAULT" bash "$GUARD" "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  STATUS=$?
}

out_all() { cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | tr '\n' ' ' | tr -d '\r'; }

if [[ ! -f "$GUARD" ]]; then
  echo "note: $GUARD does not exist yet — every case below is expected to FAIL until it lands."
fi

echo "--- A. the happy path and the contract ---"

# --- 1. commits on a normal branch ----------------------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "save: test session"
assert_eq "happy/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "happy/stdout-verdict-line" "VAULT-COMMIT: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_ne "happy/head-moved" "$before" "$(head_sha)" "$(evidence)"
assert_eq "happy/commit-message-used" "save: test session" "$(head_subject)" "$(evidence)"
assert_contains "happy/names-the-committed-path" "wiki/log.md" "$(out_all)" "$(evidence)"
assert_contains "happy/names-the-branch" "brain/work" "$(out_all)" "$(evidence)"

# --- 2. nothing to commit is exit 0, not a failure ------------------------
# A clean save is a normal outcome, not an error: a session that changed nothing
# allowlisted must not fail the whole /brain:save.
sb_new "brain/work"
GH_PATH="$GH_NONE"
before="$(head_sha)"
run_guard -m "nothing here"
assert_eq "empty/exit-0" "0" "$STATUS" "$(evidence)"
assert_prefix "empty/verdict-is-OK" "VAULT-COMMIT: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"
assert_contains "empty/says-nothing-to-commit" "nothing to commit" "$(out_all)" "$(evidence)"
assert_eq "empty/head-unmoved" "$before" "$(head_sha)" "$(evidence)"

# --- 3. --print-allowlist reports the resolved list, changes nothing ------
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard --print-allowlist
assert_eq "print-allowlist/exit-0" "0" "$STATUS" "$(evidence)"
assert_eq "print-allowlist/head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_eq "print-allowlist/stages-nothing" "0" "$(staged_count)" "$(evidence)"
assert_contains "print-allowlist/lists-an-entry" "wiki/hot.md" "$(out_all)" "$(evidence)"

# --- 4. comments and blank lines in .saveinclude are ignored --------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf '# a comment\n\n   \nwiki/log.md\n\t# indented comment\n  logs/  \n' >"$VAULT/.saveinclude"
run_guard --print-allowlist
allow_lines="$(grep -c . "$BOX/out.txt" 2>/dev/null || echo 0)"
assert_eq "parse/only-real-entries-survive" "2" "$allow_lines" "$(evidence)"
assert_contains "parse/whitespace-trimmed" "logs/" "$(out_all)" "$(evidence)"

echo "--- B. the protected-branch refusal (no override) ---"

# --- 5. refuses on main ---------------------------------------------------
# This is the 2026-08-05 incident, reproduced through the path that caused it.
for branch in main master; do
  sb_new "$branch"
  GH_PATH="$GH_NONE"
  make_dirty
  before="$(head_sha)"
  run_guard -m "should not land"
  assert_eq "protected/$branch/exit-1" "1" "$STATUS" "$(evidence)"
  assert_prefix "protected/$branch/stderr-verdict-line" "VAULT-COMMIT: REFUSED" "$(first_line "$BOX/err.txt")" "$(evidence)"
  assert_eq "protected/$branch/head-unmoved" "$before" "$(head_sha)" "$(evidence)"
  assert_contains "protected/$branch/names-the-branch" "$branch" "$(out_all)" "$(evidence)"
done

# --- 6. a refusal stages NOTHING -----------------------------------------
# INNOV-275 changed this from the old sync-graph.sh behaviour ("left STAGED").
# The git index is global to the checkout, so a refusal that leaves a payload in
# it hands the next session a commit it never chose.
sb_new "main"
GH_PATH="$GH_NONE"
make_dirty
run_guard -m "should not land"
assert_eq "protected/index-untouched" "0" "$(staged_count)" "staged: [$(staged_list | tr '\n' ' ')]" "$(evidence)"
assert_contains "protected/says-nothing-was-staged" "Nothing was staged" "$(out_all)" "$(evidence)"

# --- 7. --force-commit does NOT override it ------------------------------
# INNOV-270 shipped --force-commit as a bypass here; INNOV-275 retires it. An
# overridable guard on the vault's most damaging operation is exactly the
# "rule shipped as prose" failure mode this workstream exists to remove.
sb_new "main"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "forced" --force-commit
assert_eq "protected/force-commit-still-refuses" "1" "$STATUS" "$(evidence)"
assert_eq "protected/force-commit-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "protected/force-commit-says-no-override" "no flag to override" "$(out_all)" "$(evidence)"

# --- 8. the DETECTED default branch is protected even when it isn't main ---
# 'trunk' is outside the literal main/master net, so only origin/HEAD catches it.
sb_new "trunk"
GH_PATH="$GH_NONE"
git -C "$VAULT" update-ref refs/remotes/origin/trunk "$(head_sha)" >/dev/null 2>&1
git -C "$VAULT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk >/dev/null 2>&1
make_dirty
before="$(head_sha)"
run_guard -m "should not land"
assert_eq "protected/detected-default-refused" "1" "$STATUS" "$(evidence)"
assert_eq "protected/detected-default-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "protected/detected-default-named" "trunk" "$(out_all)" "$(evidence)"

# --- 9. a branch that merely LOOKS like a default is not protected --------
# The safety net is the literal names main/master, not "anything main-ish".
sb_new "brain/mainline-work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "fine"
assert_eq "protected/lookalike-branch-still-commits" "0" "$STATUS" "$(evidence)"
assert_ne "protected/lookalike-head-moved" "$before" "$(head_sha)" "$(evidence)"

echo "--- C. the open-PR refusal (--force-commit DOES override) ---"

# --- 10. refuses on a branch with an open PR ------------------------------
sb_new "brain/work"
GH_PATH="$GH_PR"
make_dirty
before="$(head_sha)"
run_guard -m "would pile onto a PR"
assert_eq "pr/refused" "1" "$STATUS" "$(evidence)"
assert_eq "pr/head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "pr/names-the-pr-number" "4242" "$(out_all)" "$(evidence)"
assert_eq "pr/index-untouched" "0" "$(staged_count)" "$(evidence)"

# --- 11. --force-commit overrides THIS one --------------------------------
# Unlike the protected branch, "yes, add this to my own open PR" is a coherent
# intent worth being able to express.
sb_new "brain/work"
GH_PATH="$GH_PR"
make_dirty
before="$(head_sha)"
run_guard -m "deliberately into the PR" --force-commit
assert_eq "pr/force-commit-overrides" "0" "$STATUS" "$(evidence)"
assert_ne "pr/force-commit-head-moved" "$before" "$(head_sha)" "$(evidence)"

# --- 12. no gh => "cannot tell" must look exactly like "no PR" ------------
# A vault with no GitHub remote, or a machine with no gh, keeps working. The
# guard is a safety net, never a dependency.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "no gh here"
assert_eq "pr/missing-gh-still-commits" "0" "$STATUS" "$(evidence)"
assert_ne "pr/missing-gh-head-moved" "$before" "$(head_sha)" "$(evidence)"

# --- 13. gh present, no open PR => commits --------------------------------
sb_new "brain/work"
GH_PATH="$GH_NOPR"
make_dirty
before="$(head_sha)"
run_guard -m "clean branch"
assert_eq "pr/no-open-pr-commits" "0" "$STATUS" "$(evidence)"
assert_ne "pr/no-open-pr-head-moved" "$before" "$(head_sha)" "$(evidence)"

echo "--- D. the HEAD pin (no override) ---"

# --- 14. a matching pin commits normally ----------------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "pinned" --pin "brain/work:$before"
assert_eq "pin/matching-pin-commits" "0" "$STATUS" "$(evidence)"
assert_ne "pin/matching-pin-head-moved" "$before" "$(head_sha)" "$(evidence)"

# --- 15. a moved SHA refuses ----------------------------------------------
# The concurrent-session case: another session merged a PR underneath this run,
# so the commit would land on a base its author never selected.
sb_new "brain/work"
GH_PATH="$GH_NONE"
stale_sha="$(head_sha)"
echo "other session" >>"$VAULT/wiki/log.md"
git -C "$VAULT" add -A >/dev/null 2>&1
git -C "$VAULT" commit -qm "concurrent session commit" >/dev/null 2>&1
now_sha="$(head_sha)"
make_dirty
run_guard -m "mine" --pin "brain/work:$stale_sha"
assert_eq "pin/moved-sha-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pin/moved-sha-head-unmoved" "$now_sha" "$(head_sha)" "$(evidence)"
assert_eq "pin/moved-sha-index-untouched" "0" "$(staged_count)" "$(evidence)"
assert_contains "pin/reports-pinned-sha" "$stale_sha" "$(out_all)" "$(evidence)"
assert_contains "pin/reports-current-sha" "$now_sha" "$(out_all)" "$(evidence)"

# --- 16. a moved BRANCH refuses -------------------------------------------
# HEAD is global to the checkout: another session's `checkout` moves it for
# everyone, and a long-running session cannot notice on its own.
sb_new "brain/work"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
make_dirty
run_guard -m "mine" --pin "brain/somewhere-else:$sha"
assert_eq "pin/moved-branch-refused" "1" "$STATUS" "$(evidence)"
assert_contains "pin/reports-both-branches" "brain/somewhere-else" "$(out_all)" "$(evidence)"

# --- 17. --force-commit does NOT bypass the pin ---------------------------
# --force-commit means "I know about the open PR and want it anyway". A moved
# HEAD makes the caller's intent genuinely unknown — there is nothing to force.
sb_new "brain/work"
GH_PATH="$GH_NONE"
sha="$(head_sha)"
make_dirty
run_guard -m "forced" --pin "brain/work:0000000000000000000000000000000000000000" --force-commit
assert_eq "pin/force-commit-does-not-bypass" "1" "$STATUS" "$(evidence)"
assert_contains "pin/force-commit-says-so" "does NOT override" "$(out_all)" "$(evidence)"

# --- 18. a malformed pin refuses; it is never treated as "unpinned" -------
# A caller that meant to pin and typo'd the format must not silently get an
# unguarded commit — that is the fail-open direction, and it is the dangerous one.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "typo" --pin "not-a-valid-pin"
assert_eq "pin/malformed-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pin/malformed-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "pin/malformed-explains" "BRANCH:SHA" "$(out_all)" "$(evidence)"

# --- 18b. session.sh --print-pin's whole banner is malformed, not "HEAD moved" --
# INNOV-315: save passed --print-pin's stdout through unchanged. The banner has
# colons, so it passed the *:* check, split into branch "SESSION" and a sha of
# prose, and was reported as the moved-HEAD refusal — for a HEAD that never moved.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
banner="$(printf 'SESSION: OK - pin for session s1 as recorded\n  pin: brain/work:%s' "$before")"
run_guard -m "banner" --pin "$banner"
assert_eq "pin/banner-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pin/banner-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_eq "pin/banner-index-untouched" "0" "$(staged_count)" "$(evidence)"
assert_contains "pin/banner-explains" "BRANCH:SHA" "$(out_all)" "$(evidence)"
assert_not_contains "pin/banner-not-head-moved" "HEAD moved" "$(out_all)" "$(evidence)"

# --- 18c. an explicitly EMPTY --pin refuses; it is never "unpinned" ----------
# save extracts the pin with `--print-pin | sed`; if --print-pin refuses, the sed
# still succeeds and yields "". That must fail closed, not commit unguarded.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "empty pin" --pin ""
assert_eq "pin/empty-refused" "1" "$STATUS" "$(evidence)"
assert_eq "pin/empty-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "pin/empty-explains" "BRANCH:SHA" "$(out_all)" "$(evidence)"
run_guard -m "empty pin" --pin=
assert_eq "pin/empty-eq-form-refused" "1" "$STATUS" "$(evidence)"

echo "--- E. the allowlist: staging AND index verification ---"

# --- 19. only allowlisted paths are staged --------------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/chats"
echo "private transcript" >"$VAULT/chats/secret.md"
echo "trusted knowledge" >"$VAULT/wiki/some-note.md"
make_dirty
run_guard -m "save"
assert_eq "allowlist/commits" "0" "$STATUS" "$(evidence)"
tracked="$(git -C "$VAULT" ls-files 2>/dev/null | tr '\n' ' ')"
assert_eq "allowlist/private-chats-not-committed" "0" "$(git -C "$VAULT" ls-files chats/ 2>/dev/null | grep -c . || true)" "tracked: [$tracked]" "$(evidence)"
assert_eq "allowlist/untrusted-wiki-note-not-committed" "0" "$(git -C "$VAULT" ls-files wiki/some-note.md 2>/dev/null | grep -c . || true)" "tracked: [$tracked]" "$(evidence)"
assert_contains "allowlist/allowlisted-path-was-committed" "wiki/log.md" "$tracked" "$(evidence)"

# --- 20. THE INDEX CHECK: another session's staged file refuses the commit --
# This is the case that makes the guarantee real. Staging discipline only
# governs what THIS command adds; the index is shared by every session in the
# checkout, so anything at all can already be sitting in it.
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/chats"
echo "private transcript" >"$VAULT/chats/secret.md"
git -C "$VAULT" add -f chats/secret.md >/dev/null 2>&1   # "another session"
make_dirty
before="$(head_sha)"
run_guard -m "would publish a secret"
assert_eq "index/contaminated-refused" "1" "$STATUS" "$(evidence)"
assert_eq "index/contaminated-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_contains "index/names-the-offending-path" "chats/secret.md" "$(out_all)" "$(evidence)"

# --- 21. ...and it does NOT unstage the other session's work --------------
# Unstaging someone else's staged work would be its own kind of damage. Refusing
# is the whole remedy; the human decides what to do with the index.
assert_contains "index/other-sessions-work-left-alone" "chats/secret.md" "$(staged_list | tr '\n' ' ')" "$(evidence)"

# --- 22. no .saveinclude => REFUSE, never a permissive default ------------
# There is no safe fallback: committing everything publishes chats/, committing
# nothing makes every save a silent no-op. So it fails closed.
sb_new "brain/work"
GH_PATH="$GH_NONE"
rm -f "$VAULT/.saveinclude"
make_dirty
before="$(head_sha)"
run_guard -m "no allowlist"
assert_eq "allowlist/missing-refused" "1" "$STATUS" "$(evidence)"
assert_eq "allowlist/missing-head-unmoved" "$before" "$(head_sha)" "$(evidence)"
assert_eq "allowlist/missing-stages-nothing" "0" "$(staged_count)" "$(evidence)"
assert_contains "allowlist/missing-names-the-remedy" ".saveinclude" "$(out_all)" "$(evidence)"

# --- 23. an all-comments .saveinclude is an EMPTY allowlist, and refuses ---
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf '# everything is commented out\n\n' >"$VAULT/.saveinclude"
make_dirty
run_guard -m "empty allowlist"
assert_eq "allowlist/empty-refused" "1" "$STATUS" "$(evidence)"
assert_contains "allowlist/empty-explains" "no entries" "$(out_all)" "$(evidence)"

# --- 24. a caller asking for a non-allowlisted path is refused, not trimmed --
# Silently dropping it would make the caller's commit quietly incomplete, which
# is worse than a loud refusal: the caller believes it committed something it did not.
sb_new "brain/work"
GH_PATH="$GH_NONE"
mkdir -p "$VAULT/chats"
echo "x" >"$VAULT/chats/secret.md"
make_dirty
run_guard -m "explicit bad path" -- chats/
assert_eq "allowlist/explicit-bad-path-refused" "1" "$STATUS" "$(evidence)"
assert_contains "allowlist/explicit-bad-path-named" "chats" "$(out_all)" "$(evidence)"

# --- 25. a caller CAN ask for a subset of the allowlist -------------------
# sync-graph.sh does exactly this: it commits the two paths it wrote, not the
# whole allowlist, so it does not sweep up another command's session log.
sb_new "brain/work"
GH_PATH="$GH_NONE"
echo "a log entry" >"$VAULT/logs/2026-08-05-other.md"
make_dirty
run_guard -m "subset only" -- wiki/log.md
assert_eq "allowlist/subset-commits" "0" "$STATUS" "$(evidence)"
assert_eq "allowlist/subset-excluded-path-not-committed" "0" \
  "$(git -C "$VAULT" ls-files logs/ 2>/dev/null | grep -c . || true)" "$(evidence)"
assert_contains "allowlist/subset-included-path-committed" "wiki/log.md" \
  "$(git -C "$VAULT" ls-files 2>/dev/null | tr '\n' ' ')" "$(evidence)"

# --- 26. an allowlist entry with nothing on disk is skipped, not an error --
# A fresh vault has no graphify-out/ yet. An allowlist naming a path the vault
# does not have is normal and must never fail a save.
sb_new "brain/work"
GH_PATH="$GH_NONE"
printf 'wiki/log.md\ngraphify-out/graph.json\ngraphify-out/communities/\nlogs/\n' >"$VAULT/.saveinclude"
make_dirty
run_guard -m "missing entries are fine"
assert_eq "allowlist/absent-entry-not-an-error" "0" "$STATUS" "$(evidence)"
assert_prefix "allowlist/absent-entry-verdict-OK" "VAULT-COMMIT: OK" "$(first_line "$BOX/out.txt")" "$(evidence)"

echo "--- F. arguments, vault resolution, and other preconditions ---"

# --- 27. no message => refuse --------------------------------------------
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
run_guard
assert_eq "args/no-message-refused" "1" "$STATUS" "$(evidence)"
assert_contains "args/no-message-explains" "commit message" "$(out_all)" "$(evidence)"

# --- 28. an unknown flag is refused, never silently ignored ---------------
# A typo'd flag that is ignored is a guard that quietly did not apply.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
before="$(head_sha)"
run_guard -m "x" --no-such-flag
assert_eq "args/unknown-flag-refused" "1" "$STATUS" "$(evidence)"
assert_eq "args/unknown-flag-head-unmoved" "$before" "$(head_sha)" "$(evidence)"

# --- 29. flags may follow the path arguments -----------------------------
# Callers build these argv lists programmatically; argument order is a silly
# thing to have to get right.
sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
sha="$(head_sha)"
run_guard -m "flags after paths" --pin "brain/work:$sha"
assert_eq "args/flag-order-independent" "0" "$STATUS" "$(evidence)"

# --- 30. not a vault => refuse, and touch nothing ------------------------
# The guard must not be pointable at some unrelated repo by a wrong BRAIN_ROOT.
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/not-a-vault"
mkdir -p "$VAULT/src"
git -C "$VAULT" init -q -b feature >/dev/null 2>&1
git -C "$VAULT" config user.email t@example.com
git -C "$VAULT" config user.name "T"
echo "code" >"$VAULT/src/main.js"
GH_PATH="$GH_NONE"
run_guard -m "should never touch this repo"
assert_eq "vault/non-vault-refused" "1" "$STATUS" "$(evidence)"
assert_contains "vault/non-vault-explains" "brain vault" "$(out_all)" "$(evidence)"
assert_eq "vault/non-vault-index-untouched" "0" "$(staged_count)" "$(evidence)"

# --- 31. a vault that is not a git repo => refuse ------------------------
BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
VAULT="$BOX/vault"
mkdir -p "$VAULT/wiki"
printf 'wiki/log.md\n' >"$VAULT/.saveinclude"
echo "log" >"$VAULT/wiki/log.md"
GH_PATH="$GH_NONE"
run_guard -m "nowhere to commit"
assert_eq "vault/non-git-refused" "1" "$STATUS" "$(evidence)"
assert_contains "vault/non-git-explains" "not a git repo" "$(out_all)" "$(evidence)"

# --- 32. exactly one verdict line, on exactly one stream ------------------
# The contract is that a caller can branch on the first line without parsing
# prose. Two verdict lines, or a verdict on the wrong stream, breaks that.
sb_new "main"
GH_PATH="$GH_NONE"
make_dirty
run_guard -m "refused"
verdicts="$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -c '^VAULT-COMMIT: ' || true)"
assert_eq "contract/refusal-has-exactly-one-verdict-line" "1" "$verdicts" "$(evidence)"
assert_eq "contract/refusal-stdout-carries-no-verdict" "0" \
  "$(grep -c '^VAULT-COMMIT: ' "$BOX/out.txt" 2>/dev/null || true)" "$(evidence)"

sb_new "brain/work"
GH_PATH="$GH_NONE"
make_dirty
run_guard -m "committed"
assert_eq "contract/success-has-exactly-one-verdict-line" "1" \
  "$(cat "$BOX/out.txt" "$BOX/err.txt" 2>/dev/null | grep -c '^VAULT-COMMIT: ' || true)" "$(evidence)"
assert_eq "contract/success-stderr-carries-no-verdict" "0" \
  "$(grep -c '^VAULT-COMMIT: ' "$BOX/err.txt" 2>/dev/null || true)" "$(evidence)"

# ------------------------------------------------------------------ done ---
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
