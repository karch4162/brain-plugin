#!/usr/bin/env bash
# test-repo-aliases.sh — sync-graph.sh resolves mirrors through repos.json.
#
# WHY THIS EXISTS. sync-graph.sh looked its source checkouts up as
# `$REPOS_DIR/<mirror-name>`, which quietly assumes two things at once: that every
# covered repo sits DIRECTLY under one shared parent, and that its FOLDER NAME
# equals its mirror name. Neither holds in the vault this plugin was built for:
#
#   store-hub  is the repo vendsy/edge, cloned as `edge/`        — name ≠ folder
#   KDS        is monorepo/android/applications/KDS              — not a direct child
#   hub-*      are hub/frontend, hub/services/core-service, …    — both at once
#
# The failure is SILENT, which is what makes it worth a suite. When the flat
# lookup misses, there is no source graph at the path it guessed, so the mirror
# is simply not selected — indistinguishable from "nobody rebuilt it". tray-brain's
# store-hub mirror sat unsyncable this way. Test 5 is the negative control that
# pins it: the same fixture, minus repos.json, must NOT sync.
#
# repos.json (identity: name → remote + subPath) and repos.local.json (this
# machine's absolute paths) already existed for the anchor/freshness path. This is
# the sync learning to read the same map.
#
# THE COMPATIBILITY CONTRACT: a vault with no repos.json must behave EXACTLY as
# before. That is pinned here (tests 5, 10) and, more strongly, by
# tests/test-sync-graph.sh passing completely unchanged.
#
# Run:  bash tests/test-repo-aliases.sh   (from anywhere)
# No network, no real vault. `python` is stubbed; `node` delegates the two modules
# genuinely under test (resolve-repos.mjs, label-guard.mjs) to a real interpreter
# and no-ops the rest, so a real `node` on PATH is required.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SYNC="$REPO_ROOT/brain/bin/sync-graph.sh"
RESOLVE="$REPO_ROOT/brain/bin/resolve-repos.mjs"

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

REAL_NODE="$(command -v node || true)"
if [[ -z "$REAL_NODE" ]]; then
  echo "SKIP: no node on PATH — this suite exercises real node modules." >&2
  exit 0
fi

# --- stubs ------------------------------------------------------------------
# node delegates the modules under test to the real interpreter; everything else
# (build-community-notes.mjs, scope-audit.mjs) no-ops, exactly as the sibling
# sync-graph suite does. A no-op scope audit makes the gate report UNKNOWN, which
# warns and publishes — deliberate: this suite is about resolution, not the gate.
STUBS="$TMPROOT/stubs"
mkdir -p "$STUBS"
for prog in python python3; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/$prog"
  chmod +x "$STUBS/$prog"
done
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do\n'
  printf '  case "$a" in\n'
  printf '    *resolve-repos.mjs) exec %q "$@" ;;\n' "$REAL_NODE"
  printf '    *label-guard.mjs)   exec %q "$@" ;;\n' "$REAL_NODE"
  printf '  esac\n'
  printf 'done\n'
  printf 'exit 0\n'
} >"$STUBS/node"
chmod +x "$STUBS/node"

# `gh` absent => vault-commit.sh cannot check for an open PR and proceeds.
GH_NONE="$TMPROOT/gh-none"
mkdir -p "$GH_NONE"

# The path form a native (non-Git-Bash) node would receive. `-m` gives the
# mixed form (C:/Users/...), which is valid in JSON without escaping.
native_path() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

make_report() { # path headings
  local f="$1" n="$2" i
  mkdir -p "$(dirname "$f")"
  : >"$f"
  for ((i = 1; i <= n; i++)); do printf '## Community %d — Real Name %d\n\n' "$i" "$i" >>"$f"; done
}

git_init_commit() { # dir msg
  git -C "$1" init -q 2>/dev/null
  git -C "$1" config user.email t@t.t
  git -C "$1" config user.name t
  git -C "$1" add -A 2>/dev/null
  git -C "$1" commit -q -m "$2" 2>/dev/null
}

# A sandbox whose mirror name deliberately does NOT match its checkout folder —
# the store-hub shape. Mirror `store-hub`; checkout `repos/edge`.
new_alias_sandbox() {
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  local v="$BOX/vault" r="$BOX/repos"
  mkdir -p "$v/wiki" "$v/graphify/store-hub" "$r/edge/graphify-out"
  : >"$v/wiki/log.md"
  printf 'graphify/\nwiki/log.md\n' >"$v/.saveinclude"
  printf '{"nodes":["edge"],"links":[]}\n' >"$r/edge/graphify-out/graph.json"
  printf '{"repo":"edge"}\n' >"$r/edge/graphify-out/manifest.json"
  make_report "$r/edge/graphify-out/GRAPH_REPORT.md" 3
  cp "$r/edge/graphify-out/graph.json" "$v/graphify/store-hub/graph.json"
  cp "$r/edge/graphify-out/manifest.json" "$v/graphify/store-hub/manifest.json"
  cp "$r/edge/graphify-out/GRAPH_REPORT.md" "$v/graphify/store-hub/store-hub-GRAPH_REPORT.md"
  # Identity carries NO remote here: resolveRepos accepts a cached path without a
  # remote to verify against, which keeps the fixture free of extra git clones.
  printf '{"repos":{"store-hub":{}}}\n' >"$v/repos.json"
  # repos.local.json holds NATIVE paths — on Windows that is `C:/Users/...`, which
  # is what the real tray-brain vault contains and what Windows node can actually
  # stat. Writing the Git Bash `/tmp/...` form here would make node's existsSync
  # fail and the alias silently not resolve. cygpath is absent off Windows, where
  # the POSIX path is already native.
  printf '{"store-hub":"%s"}\n' "$(native_path "$r/edge")" >"$v/repos.local.json"
  git_init_commit "$v" "initial vault"
  git -C "$v" checkout -q -b brain/alias-harness >/dev/null 2>&1
}

make_stale() { printf '{"nodes":["edge","edge2"],"links":[]}\n' >"$1/repos/edge/graphify-out/graph.json"; }

run_sync() { # box [args...]
  local box="$1"
  shift
  (
    PATH="$GH_NONE:$STUBS:$PATH"
    BRAIN_ROOT="$box/vault" REPOS_DIR="$box/repos" bash "$SYNC" "$@"
  ) >"$box/out.txt" 2>"$box/err.txt"
  local st=$?
  echo $st
}

echo "--- A. --print-paths: the map a shell can consume ---"

# 1-3. name<TAB>path, forward slashes, exit 0.
new_alias_sandbox
out="$(BRAIN_ROOT="$BOX/vault" node "$RESOLVE" --vault "$BOX/vault" --repos-dir "$BOX/repos" --print-paths 2>/dev/null)"
st=$?
assert_eq "print-paths/exit-0" "0" "$st"
assert_contains "print-paths/emits-name-tab-path" "$out" "store-hub	"
case "$out" in
  *'\'*) fail "print-paths/forward-slashes-only" "output must not contain backslashes" "actual: [$out]" ;;
  *) pass "print-paths/forward-slashes-only" ;;
esac

# 4. No repos.json => NOTHING on stdout and exit 0, so a shell caller reads it as
# "no aliases, use the flat layout" rather than as an error.
rm -f "$BOX/vault/repos.json"
out="$(node "$RESOLVE" --vault "$BOX/vault" --repos-dir "$BOX/repos" --print-paths 2>/dev/null)"
st=$?
assert_eq "print-paths/no-repos-json/exit-0" "0" "$st"
assert_eq "print-paths/no-repos-json/empty-output" "" "$out"

echo "--- B. the bug: a mirror whose folder name differs ---"

# 5. NEGATIVE CONTROL — without repos.json the flat lookup guesses
# $REPOS_DIR/store-hub, which does not exist, so the mirror is silently skipped.
# This is the defect, reproduced. If this ever starts passing, the test below is
# no longer proving anything.
new_alias_sandbox
rm -f "$BOX/vault/repos.json" "$BOX/vault/repos.local.json"
make_stale "$BOX"
st="$(run_sync "$BOX")"
before="$(cat "$BOX/vault/graphify/store-hub/graph.json")"
if [[ "$before" == *"edge2"* ]]; then
  fail "no-aliases/mirror-NOT-synced" "without repos.json the flat lookup cannot find repos/edge" "graph: $before"
else
  pass "no-aliases/mirror-NOT-synced"
fi
assert_contains "no-aliases/says-nothing-to-sync" "$(cat "$BOX/err.txt")" "nothing to sync"

# 6-8. WITH repos.json the same fixture resolves and syncs into graphify/store-hub.
new_alias_sandbox
make_stale "$BOX"
st="$(run_sync "$BOX")"
assert_eq "alias/exit-0" "0" "$st"
assert_contains "alias/mirror-synced" "$(cat "$BOX/vault/graphify/store-hub/graph.json")" "edge2"
assert_contains "alias/stderr-names-mirror-not-folder" "$(cat "$BOX/err.txt")" "store-hub"

# 9. The mirror directory is the ALIAS name; no bare-folder mirror is created.
if [[ -d "$BOX/vault/graphify/edge" ]]; then
  fail "alias/no-basename-mirror-created" "sync must not create graphify/edge alongside graphify/store-hub"
else
  pass "alias/no-basename-mirror-created"
fi

echo "--- C. explicit arguments ---"

# 10. An explicit PATH argument still publishes to the alias, not the basename.
new_alias_sandbox
make_stale "$BOX"
st="$(run_sync "$BOX" "$BOX/repos/edge")"
assert_contains "explicit-path/publishes-to-alias" "$(cat "$BOX/vault/graphify/store-hub/graph.json")" "edge2"
if [[ -d "$BOX/vault/graphify/edge" ]]; then
  fail "explicit-path/no-basename-mirror" "expected graphify/store-hub, got a graphify/edge"
else
  pass "explicit-path/no-basename-mirror"
fi

# 11. A bare ALIAS NAME is accepted as an argument — the form anyone reading the
# scope table will reach for.
new_alias_sandbox
make_stale "$BOX"
st="$(run_sync "$BOX" store-hub)"
assert_eq "alias-name-arg/exit-0" "0" "$st"
assert_contains "alias-name-arg/syncs" "$(cat "$BOX/vault/graphify/store-hub/graph.json")" "edge2"

echo "--- D. staleness and the scope gate use the RESOLVED path ---"

# 12. Staleness is judged on the resolved checkout. Comparing against a path that
# cannot exist always reads "not stale" — the silent-skip failure mode itself.
new_alias_sandbox
st="$(run_sync "$BOX")"
assert_contains "unchanged/nothing-to-sync" "$(cat "$BOX/err.txt")" "nothing to sync"

# 13. An alias pointing at a checkout with no graph is reported as a SKIP naming
# the mirror — not silently dropped.
new_alias_sandbox
rm -rf "$BOX/repos/edge/graphify-out"
st="$(run_sync "$BOX" store-hub)"
assert_contains "missing-graph/skip-names-mirror" "$(cat "$BOX/err.txt")" "store-hub"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
