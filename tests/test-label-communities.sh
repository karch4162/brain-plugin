#!/usr/bin/env bash
# test-label-communities.sh — deterministic quality gate for
# brain/bin/label-communities.mjs (+ its hand-off to build-community-notes.mjs).
#
# Covers two defects:
#
# INNOV-263 — --apply silently ignored a labels file keyed on the digest's
#   DISPLAY form ("Community 0") instead of the raw id ("0"). No error: the run
#   reported success and wrote file-derived filler names. On the NEXT run
#   classify() saw that filler as non-generic and marked it "preserved", so the
#   real labels could never land — the mistake became load-bearing on run two.
#   Contract now: both key forms accepted; an all-unmatched labels file is a
#   loud non-zero failure that writes nothing; the digest hands over a
#   ready-to-fill skeleton keyed the way --apply expects; and derived names
#   carry provenance so they are never re-read as human labels.
#
# INNOV-264 — transformReport() renamed the detail headings but never rewrote
#   the report's LINK LIST, so `[[_COMMUNITY_Community N|Community N]]` entries
#   survived and build-community-notes.mjs manufactured a generic stub for each
#   dangling target (125 across four mirrors on 2026-08-04; 68 of hub-frontend's
#   158 communities). Contract now: after --apply + stub regeneration,
#   `grep -c '_COMMUNITY_Community [0-9]' <repo>-GRAPH_REPORT.md` is 0 and the
#   communities dir holds no `_COMMUNITY_Community <n>.md`.
#
# Invariants re-asserted throughout: an existing non-generic label written by a
# human is never changed (preserved > agent > derived), and a derived name never
# silently merges into an already-taken name.
#
# Run:  bash tests/test-label-communities.sh   (from anywhere)
# No network, no real vault. Requires `node` (the scripts under test are ESM).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
LABEL="$REPO_ROOT/brain/bin/label-communities.mjs"
STUBS_MJS="$REPO_ROOT/brain/bin/build-community-notes.mjs"

PASSED=0
FAILED=0

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
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

assert_ne() { # name not_expected actual [evidence...]
  local name="$1" nexp="$2" act="$3"
  shift 3
  if [[ "$nexp" != "$act" ]]; then
    pass "$name"
  else
    fail "$name" "expected anything but: [$nexp]" "actual: [$act]" "$@"
  fi
}

assert_files_identical() { # name file_a file_b
  if cmp -s "$2" "$3"; then
    pass "$1"
  else
    fail "$1" "expected byte-identical files:" "  a: $2" "  b: $3" \
      "first difference: $(cmp "$2" "$3" 2>&1 | head -n 1)"
  fi
}

assert_grep() { # name pattern file [evidence...]
  local name="$1" pat="$2" f="$3"
  shift 3
  if grep -qF -- "$pat" "$f" 2>/dev/null; then
    pass "$name"
  else
    fail "$name" "expected to find: [$pat]" "in: $f" "$@"
  fi
}

assert_not_grep() { # name pattern file [evidence...]
  local name="$1" pat="$2" f="$3"
  shift 3
  if grep -qF -- "$pat" "$f" 2>/dev/null; then
    fail "$name" "expected NOT to find: [$pat]" "in: $f" \
      "matching lines: [$(grep -F -- "$pat" "$f" | head -n 3 | tr '\n' '/')]" "$@"
  else
    pass "$name"
  fi
}

# Node is a native Windows binary under Git Bash: MSYS rewrites path-shaped
# ARGUMENTS but env vars are less reliable, so convert explicitly.
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# Evaluate a JS expression against a JSON file. `d` is the parsed document.
jexpr() { # file expr
  node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(eval(process.argv[2])))' \
    "$(to_native "$1")" "$2" 2>/dev/null
}

if ! command -v node >/dev/null 2>&1; then
  fail "harness/node-available" "node is required to run label-communities.mjs but was not found on PATH"
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

# ---------------------------------------------------------------- fixture ---
#
# Six communities in graph.json; the report gives detail headings to 0, 1 and 2
# only, and 2 is already named by a human ("Payments Core" — untouchable).
# Communities 3, 4 and 5 are LINKED from the hub list with no heading: the
# INNOV-264 residue case. 4 and 5 have different directories but the same
# dominant basename (utils.ts), which exercises deriveName()'s collision
# handling.
GRAPH_JSON='{"nodes":[
  {"id":"a","label":"a","community":0,"source_file":"src/checkout/flow.ts"},
  {"id":"b","label":"b","community":0,"source_file":"src/checkout/flow.ts"},
  {"id":"c","label":"c","community":0,"source_file":"src/checkout/flow.ts"},
  {"id":"d","label":"d","community":1,"source_file":"src/auth/mw.ts"},
  {"id":"e","label":"e","community":1,"source_file":"src/auth/mw.ts"},
  {"id":"f","label":"f","community":2,"source_file":"src/pay/core.ts"},
  {"id":"g","label":"g","community":2,"source_file":"src/pay/core.ts"},
  {"id":"h","label":"h","community":3,"source_file":"src/sync/worker.ts"},
  {"id":"i","label":"i","community":4,"source_file":"src/a/utils.ts"},
  {"id":"j","label":"j","community":5,"source_file":"src/b/utils.ts"}
],"links":[{"source":"a","target":"b"},{"source":"d","target":"e"}]}'

# $1 = box dir. Writes vault/graphify/demo/{graph.json,demo-GRAPH_REPORT.md}.
# $2 (optional) = label to use for community 0's heading (default generic).
write_mirror() {
  local box="$1" c0="${2:-Community 0}" dir="$1/vault/graphify/demo"
  mkdir -p "$dir"
  printf '%s\n' "$GRAPH_JSON" >"$dir/graph.json"
  {
    printf '# Graph Report - graphify/demo/graph.json\n\n'
    printf '## Summary\n- 10 nodes - 2 edges - 6 communities\n\n'
    printf '## Community Hubs (Navigation)\n'
    printf -- '- [[_COMMUNITY_%s|%s]]\n' "$c0" "$c0"
    printf -- '- [[_COMMUNITY_Community 1|Community 1]]\n'
    printf -- '- [[_COMMUNITY_Payments Core|Payments Core]]\n'
    printf -- '- [[_COMMUNITY_Community 3|Community 3]]\n'
    printf -- '- [[_COMMUNITY_Community 4|Community 4]]\n'
    printf -- '- [[_COMMUNITY_Community 5|Community 5]]\n\n'
    printf '## Communities\n'
    printf '### Community 0 - "%s"\n' "$c0"
    printf 'Nodes (3): a, b, c\nNeighbors: [[_COMMUNITY_Community 1|Community 1]]\n\n'
    printf '### Community 1 - "Community 1"\n'
    printf 'Nodes (2): d, e\n\n'
    printf '### Community 2 - "Payments Core"\n'
    printf 'Nodes (2): f, g\n\n'
  } >"$dir/demo-GRAPH_REPORT.md"
}

new_box() { # -> echoes box path (fresh vault with the fixture mirror)
  local box
  box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  write_mirror "$box"
  echo "$box"
}

REPORT_REL="vault/graphify/demo/demo-GRAPH_REPORT.md"
SIDECAR_REL="vault/graphify/demo/.community-labels.json"

write_labels() { # box json  -> echoes labels file path
  local box="$1"
  printf '%s\n' "$2" >"$box/labels.json"
  echo "$box/labels.json"
}

run_label() { # box args...  -> echoes exit status; box/out.txt, box/err.txt
  local box="$1"
  shift
  (
    BRAIN_ROOT="$(to_native "$box/vault")" node "$(to_native "$LABEL")" "$@"
  ) >"$box/out.txt" 2>"$box/err.txt"
  local st=$?
  cat "$box/out.txt" "$box/err.txt" >"$box/all.txt" 2>/dev/null
  echo $st
}

run_apply() { # box json_labels [extra args...] -> echoes exit status
  local box="$1" json="$2"
  shift 2
  local lf
  lf="$(write_labels "$box" "$json")"
  run_label "$box" --apply demo --labels "$(to_native "$lf")" "$@"
}

run_stubs() { # box -> echoes exit status
  local box="$1"
  (
    BRAIN_ROOT="$(to_native "$box/vault")" node "$(to_native "$STUBS_MJS")" demo
  ) >"$box/stubs.out" 2>"$box/stubs.err"
  echo $?
}

# ================================================================= PART A ===
# --digest: the work order must state, unambiguously, the key --apply expects.

echo "--- A. --digest work order + key form (INNOV-263 c) ---"

box="$(new_box)"
status="$(run_label "$box" --digest demo)"
assert_eq "digest/exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
cp "$box/out.txt" "$box/digest.json"

got="$(jexpr "$box/digest.json" "Object.keys(d[0]).filter(k=>['repo','total','preserved','derived','batches'].includes(k)).sort().join(',')")"
assert_eq "digest/keeps-existing-json-shape" "batches,derived,preserved,repo,total" "$got" \
  "digest: [$(head -c 400 "$box/digest.json")]"

assert_eq "digest/total-counts-all-communities" "6" "$(jexpr "$box/digest.json" 'd[0].total')"

# The human's label is preserved and must never enter the naming work order.
assert_eq "digest/human-label-reported-preserved" "Payments Core" \
  "$(jexpr "$box/digest.json" "d[0].preserved['2']")"

# (c) a ready-to-fill skeleton, keyed exactly as --apply expects: raw ids.
assert_eq "digest/emits-labels-template" "0,1,3,4,5" \
  "$(jexpr "$box/digest.json" 'Object.keys(d[0].labels_template).map(Number).sort((a,b)=>a-b).join(",")')"
assert_eq "digest/template-keys-are-raw-ids" "true" \
  "$(jexpr "$box/digest.json" 'Object.keys(d[0].labels_template).every(k=>/^\d+$/.test(k))')"
assert_eq "digest/template-excludes-preserved-id" "false" \
  "$(jexpr "$box/digest.json" "Object.prototype.hasOwnProperty.call(d[0].labels_template,'2')")"
assert_eq "digest/states-the-key-form" "true" \
  "$(jexpr "$box/digest.json" 'typeof d[0].labels_key_form === "string" && d[0].labels_key_form.length > 0')"

# The batch STRINGS stay human-readable prose (display form) for the LLM.
assert_grep "digest/batch-lines-keep-display-prose" 'Community 0 (3 nodes)' "$box/digest.json"

# ================================================================= PART B ===
# --apply must accept BOTH key forms, with surrounding whitespace tolerated.

echo "--- B. --apply key normalization (INNOV-263 a) ---"

# --- B1. display form ("Community 0"), padded, mixed with a raw id ----------
box="$(new_box)"
status="$(run_apply "$box" '{" Community 0 ":"Checkout Flow","1":"Auth Middleware","Community 3":"Sync Worker"}')"
assert_eq "apply/display-form-keys-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "apply/display-form-key-renames-heading" '### Community 0 - "Checkout Flow"' "$box/$REPORT_REL" \
  "report: [$(cat "$box/$REPORT_REL")]"
assert_grep "apply/raw-id-key-renames-heading" '### Community 1 - "Auth Middleware"' "$box/$REPORT_REL"
assert_grep "apply/display-form-key-names-appended-community" '### Community 3 - "Sync Worker"' "$box/$REPORT_REL"
assert_not_grep "apply/no-generic-heading-left" '- "Community 0"' "$box/$REPORT_REL"

# preserved > agent > derived: the human's label is byte-identical afterwards.
assert_grep "apply/human-label-untouched" '### Community 2 - "Payments Core"' "$box/$REPORT_REL"

# deriveName collision handling: 4 and 5 share basename utils.ts and must not
# silently merge into one name.
d4="$(sed -n 's/^### Community 4 - "\(.*\)"$/\1/p' "$box/$REPORT_REL")"
d5="$(sed -n 's/^### Community 5 - "\(.*\)"$/\1/p' "$box/$REPORT_REL")"
assert_ne "apply/derived-names-do-not-collide" "$d4" "$d5" "c4: [$d4] c5: [$d5]"
assert_ne "apply/derived-name-c4-non-empty" "" "$d4"
assert_ne "apply/derived-name-c5-non-empty" "" "$d5"

# --- B2. the digest's own template round-trips ------------------------------
box="$(new_box)"
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
ROUNDTRIP="$(jexpr "$box/digest.json" 'JSON.stringify(Object.fromEntries(Object.keys(d[0].labels_template).map(k=>[k,"Round Trip "+k])))')"
status="$(run_apply "$box" "$ROUNDTRIP")"
assert_eq "roundtrip/digest-template-applies-cleanly" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "roundtrip/heading-named-from-template" '### Community 1 - "Round Trip 1"' "$box/$REPORT_REL"
assert_not_grep "roundtrip/no-unmatched-key-warning" "did not match" "$box/err.txt"

# ================================================================= PART C ===
# A labels file that matches nothing is a mistake, never an intent.

echo "--- C. unmatched keys warn loudly / fail (INNOV-263 b) ---"

# --- C1. zero intersection => non-zero exit, nothing written ---------------
box="$(new_box)"
cp "$box/$REPORT_REL" "$box/report.before"
status="$(run_apply "$box" '{"cluster 0":"Checkout Flow","Payments":"Nope"}')"
assert_ne "empty-intersection/exit-is-non-zero" "0" "$status" \
  "stdout: [$(cat "$box/out.txt")]" "stderr: [$(cat "$box/err.txt")]"
assert_files_identical "empty-intersection/report-not-written" "$box/report.before" "$box/$REPORT_REL"
if grep -qi "LABELS NOT APPLIED" "$box/err.txt"; then
  pass "empty-intersection/stderr-is-unmistakable"
else
  fail "empty-intersection/stderr-is-unmistakable" \
    "expected an unmistakable 'LABELS NOT APPLIED' banner on stderr" \
    "stderr: [$(cat "$box/err.txt")]"
fi
if [[ -f "$box/$SIDECAR_REL" ]]; then
  fail "empty-intersection/no-sidecar-written" "a failed apply must not leave a provenance sidecar behind"
else
  pass "empty-intersection/no-sidecar-written"
fi
assert_not_grep "empty-intersection/does-not-report-success" "communities —" "$box/out.txt"

# --- C2. an empty labels file is the same mistake --------------------------
box="$(new_box)"
cp "$box/$REPORT_REL" "$box/report.before"
status="$(run_apply "$box" '{}')"
assert_ne "empty-file/exit-is-non-zero" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_files_identical "empty-file/report-not-written" "$box/report.before" "$box/$REPORT_REL"

# --- C3. SOME keys unmatched => proceed, but name the offenders ------------
box="$(new_box)"
status="$(run_apply "$box" '{"0":"Checkout Flow","99":"No Such Community","Community 7":"Nor This"}')"
assert_eq "partial-match/exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "partial-match/matched-key-applied" '### Community 0 - "Checkout Flow"' "$box/$REPORT_REL"
if grep -q "did not match" "$box/err.txt" && grep -q '99' "$box/err.txt"; then
  pass "partial-match/warns-and-samples-unmatched-keys"
else
  fail "partial-match/warns-and-samples-unmatched-keys" \
    "expected a stderr warning naming the unmatched key 99" \
    "stderr: [$(cat "$box/err.txt")]"
fi

# ================================================================= PART D ===
# Provenance: derived filler must not masquerade as a human label on run two.

echo "--- D. derived vs. human provenance (INNOV-263 d) ---"

box="$(new_box)"
# Run 1: only community 0 is named; 1, 3, 4, 5 get derived filler.
status="$(run_apply "$box" '{"0":"Checkout Flow"}')"
assert_eq "provenance/run1-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
derived1="$(sed -n 's/^### Community 1 - "\(.*\)"$/\1/p' "$box/$REPORT_REL")"
assert_ne "provenance/run1-community-1-got-filler" "" "$derived1"
assert_ne "provenance/run1-filler-is-not-generic" "Community 1" "$derived1"

if [[ -f "$box/$SIDECAR_REL" ]]; then
  pass "provenance/sidecar-written"
  assert_eq "provenance/sidecar-marks-filler-derived" "derived" \
    "$(jexpr "$box/$SIDECAR_REL" "d.labels['1'].provenance")"
  assert_eq "provenance/sidecar-marks-agent-label" "agent" \
    "$(jexpr "$box/$SIDECAR_REL" "d.labels['0'].provenance")"
  assert_eq "provenance/sidecar-marks-human-label-preserved" "preserved" \
    "$(jexpr "$box/$SIDECAR_REL" "d.labels['2'].provenance")"
else
  fail "provenance/sidecar-written" "expected a provenance record at $box/$SIDECAR_REL"
  fail "provenance/sidecar-marks-filler-derived" "no sidecar"
  fail "provenance/sidecar-marks-agent-label" "no sidecar"
  fail "provenance/sidecar-marks-human-label-preserved" "no sidecar"
fi

# Run 2 digest: the filler must be back in the work order, NOT in preserved.
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest2.json"
assert_eq "provenance/run2-digest-filler-not-preserved" "false" \
  "$(jexpr "$box/digest2.json" "Object.prototype.hasOwnProperty.call(d[0].preserved,'1')")" \
  "digest: [$(head -c 600 "$box/digest2.json")]"
assert_eq "provenance/run2-digest-filler-is-namable" "true" \
  "$(jexpr "$box/digest2.json" "Object.prototype.hasOwnProperty.call(d[0].labels_template,'1')")"
assert_eq "provenance/run2-digest-agent-label-preserved" "Checkout Flow" \
  "$(jexpr "$box/digest2.json" "d[0].preserved['0']")"
assert_eq "provenance/run2-digest-human-label-preserved" "Payments Core" \
  "$(jexpr "$box/digest2.json" "d[0].preserved['2']")"

# Run 2 apply: the real label lands over the filler.
status="$(run_apply "$box" '{"Community 1":"Auth Middleware","3":"Sync Worker"}')"
assert_eq "provenance/run2-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "provenance/run2-real-label-overwrites-filler" '### Community 1 - "Auth Middleware"' "$box/$REPORT_REL" \
  "report: [$(cat "$box/$REPORT_REL")]"
assert_not_grep "provenance/run2-filler-heading-gone" "### Community 1 - \"$derived1\"" "$box/$REPORT_REL"
assert_grep "provenance/run2-human-label-still-untouched" '### Community 2 - "Payments Core"' "$box/$REPORT_REL"
assert_grep "provenance/run2-earlier-agent-label-untouched" '### Community 0 - "Checkout Flow"' "$box/$REPORT_REL"

# --- D2. backward compatibility: no sidecar => non-generic label preserved --
box="$(new_box)"
write_mirror "$box" "Hand Written Name"   # non-generic, no sidecar anywhere
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
assert_eq "backcompat/unmarked-non-generic-label-is-preserved" "Hand Written Name" \
  "$(jexpr "$box/digest.json" "d[0].preserved['0']")" \
  "digest: [$(head -c 600 "$box/digest.json")]"
status="$(run_apply "$box" '{"0":"Should Not Win","1":"Auth Middleware"}')"
assert_eq "backcompat/apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "backcompat/unmarked-label-not-overwritten" '### Community 0 - "Hand Written Name"' "$box/$REPORT_REL"
assert_not_grep "backcompat/agent-could-not-clobber-it" "Should Not Win" "$box/$REPORT_REL"

# ================================================================= PART E ===
# INNOV-264 acceptance: no dangling _COMMUNITY_Community links, no generic stubs.

echo "--- E. report link list + stub regeneration (INNOV-264) ---"

count_generic_links() { # report file -> count
  grep -c '_COMMUNITY_Community [0-9]' "$1" 2>/dev/null || true
}

box="$(new_box)"
# Fixture guard: the untransformed report really does carry the placeholder links.
before="$(count_generic_links "$box/$REPORT_REL")"
if [[ "$before" -gt 0 ]]; then
  pass "acceptance/fixture-has-placeholder-links-before-apply"
else
  fail "acceptance/fixture-has-placeholder-links-before-apply" \
    "the fixture report must contain [[_COMMUNITY_Community N|...]] links or this test proves nothing"
fi

status="$(run_apply "$box" '{"0":"Checkout Flow","Community 1":"Auth Middleware","3":"Sync Worker","4":"Alpha Utils","5":"Beta Utils"}')"
assert_eq "acceptance/apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"

assert_eq "acceptance/report-has-zero-generic-community-links" "0" \
  "$(count_generic_links "$box/$REPORT_REL")" \
  "remaining: [$(grep -n '_COMMUNITY_Community [0-9]' "$box/$REPORT_REL" | head -n 5 | tr '\n' '/')]"

# The hub list must now point at the real names, not just the detail headings.
assert_grep "acceptance/hub-link-rewritten-to-new-name" '[[_COMMUNITY_Checkout Flow|Checkout Flow]]' "$box/$REPORT_REL"
assert_grep "acceptance/heading-less-community-link-rewritten" '[[_COMMUNITY_Sync Worker|Sync Worker]]' "$box/$REPORT_REL"
assert_grep "acceptance/inline-neighbor-link-rewritten" '[[_COMMUNITY_Auth Middleware|Auth Middleware]]' "$box/$REPORT_REL"
assert_grep "acceptance/preserved-hub-link-untouched" '[[_COMMUNITY_Payments Core|Payments Core]]' "$box/$REPORT_REL"

status="$(run_stubs "$box")"
assert_eq "acceptance/stub-regeneration-exit-0" "0" "$status" "stderr: [$(cat "$box/stubs.err")]"

COMM_DIR="$box/vault/graphify/demo/communities"
generic_stubs="$(find "$COMM_DIR" -maxdepth 1 -name '_COMMUNITY_Community *.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "acceptance/no-generic-community-stub-files" "0" "$generic_stubs" \
  "found: [$(find "$COMM_DIR" -maxdepth 1 -name '_COMMUNITY_Community *.md' 2>/dev/null | tr '\n' ' ')]"

if [[ -f "$COMM_DIR/_COMMUNITY_Checkout Flow.md" ]]; then
  pass "acceptance/named-stub-exists"
else
  fail "acceptance/named-stub-exists" "expected a stub for the renamed community" \
    "dir: [$(ls "$COMM_DIR" 2>/dev/null | tr '\n' ' ')]"
fi

# --- E2. idempotence: a second apply+rebuild keeps the report clean ---------
status="$(run_apply "$box" '{"0":"Checkout Flow","1":"Auth Middleware","3":"Sync Worker","4":"Alpha Utils","5":"Beta Utils"}')"
assert_eq "acceptance/second-apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_eq "acceptance/second-apply-still-zero-generic-links" "0" \
  "$(count_generic_links "$box/$REPORT_REL")"
status="$(run_stubs "$box")"
generic_stubs="$(find "$COMM_DIR" -maxdepth 1 -name '_COMMUNITY_Community *.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "acceptance/second-rebuild-no-generic-stubs" "0" "$generic_stubs"

# --- E3. no report at all => generated fresh, still no generic links --------
box="$(new_box)"
rm -f "$box/$REPORT_REL"
status="$(run_apply "$box" '{"0":"Checkout Flow","1":"Auth Middleware","2":"Payments Core","3":"Sync Worker","4":"Alpha Utils","5":"Beta Utils"}')"
assert_eq "generated-report/exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_eq "generated-report/zero-generic-community-links" "0" \
  "$(count_generic_links "$box/$REPORT_REL")"
status="$(run_stubs "$box")"
generic_stubs="$(find "$box/vault/graphify/demo/communities" -maxdepth 1 -name '_COMMUNITY_Community *.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "generated-report/no-generic-stubs" "0" "$generic_stubs"

# ================================================================= PART F ===
# INNOV-274 — "what counts as a named label" and "when may an incoming report
# replace an existing one" are ONE module (brain/bin/label-guard.mjs), used by
# both /brain:label (here) and /brain:save (sync-graph.sh). These assertions pin
# the agreement between the two callers, and the one place they deliberately
# differ.

echo "--- F. shared label-guard module agreement (INNOV-274) ---"

GUARD="$REPO_ROOT/brain/bin/label-guard.mjs"

guard_count() { # report_file -> integer
  node "$(to_native "$GUARD")" --count "$(to_native "$1")" 2>/dev/null
}

# Number of ids --digest reports as preserved.
digest_preserved_count() { # box -> integer
  jexpr "$1/digest.json" 'Object.keys(d[0].preserved).length'
}

# --- F1. both callers agree: 1 human label among generic headings -----------
box="$(new_box)"
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
assert_eq "shared/module-counts-the-single-human-label" "1" "$(guard_count "$box/$REPORT_REL")"
assert_eq "shared/digest-preserves-exactly-what-module-counts" \
  "$(guard_count "$box/$REPORT_REL")" "$(digest_preserved_count "$box")" \
  "digest: [$(head -c 400 "$box/digest.json")]"

# --- F2. same fixture, one MORE non-generic label => both counts move together
box="$(new_box)"
write_mirror "$box" "Hand Written Name"
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
assert_eq "shared/module-counts-two-named-labels" "2" "$(guard_count "$box/$REPORT_REL")"
assert_eq "shared/callers-agree-with-a-second-named-label" \
  "$(guard_count "$box/$REPORT_REL")" "$(digest_preserved_count "$box")"
# ...and that provenance-absent label is preserved through an --apply that tries
# to rename it (the INNOV-263 backward-compatible reading, re-asserted here
# because the shared module now owns the "is it a name at all?" half of it).
status="$(run_apply "$box" '{"0":"Should Not Win","1":"Auth Middleware"}')"
assert_grep "shared/provenance-absent-label-still-preserved" \
  '### Community 0 - "Hand Written Name"' "$box/$REPORT_REL"

# --- F3. the deliberate asymmetry ------------------------------------------
# A derived filler name IS a named label to the module (so /brain:save's copy
# guard protects it from a generic rebuild), yet /brain:label may still re-name
# it, because provenance says this script invented it. Both facts at once.
box="$(new_box)"
status="$(run_apply "$box" '{"0":"Checkout Flow"}')"
assert_eq "shared/run1-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
# 6 communities, all named after run 1 (agent + preserved + derived filler).
assert_eq "shared/derived-filler-counts-as-named-to-the-guard" "6" \
  "$(guard_count "$box/$REPORT_REL")" \
  "report: [$(cat "$box/$REPORT_REL")]"
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
assert_eq "shared/derived-filler-is-still-renamable-by-label" "true" \
  "$(jexpr "$box/digest.json" "Object.prototype.hasOwnProperty.call(d[0].labels_template,'1')")" \
  "digest: [$(head -c 600 "$box/digest.json")]"
assert_eq "shared/derived-filler-not-in-preserved" "false" \
  "$(jexpr "$box/digest.json" "Object.prototype.hasOwnProperty.call(d[0].preserved,'1')")"

# --- F4. write-time invariant: --apply never REDUCES the named count --------
# The same rule sync-graph.sh applies at copy time, applied here at write time.
box="$(new_box)"
before_named="$(guard_count "$box/$REPORT_REL")"
status="$(run_apply "$box" '{"0":"Checkout Flow","1":"Auth Middleware"}')"
assert_eq "shared/apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
after_named="$(guard_count "$box/$REPORT_REL")"
if [[ "$after_named" -ge "$before_named" ]]; then
  pass "shared/apply-never-reduces-named-count"
else
  fail "shared/apply-never-reduces-named-count" \
    "named labels went DOWN across --apply: before [$before_named] after [$after_named]" \
    "report: [$(cat "$box/$REPORT_REL")]"
fi
# A fully-named mirror must survive: rerunning --apply with no usable labels
# still leaves every existing name in place (this is the /brain:label-side twin
# of integration/regression-440-named-not-clobbered-by-30-named).
fully_named="$(guard_count "$box/$REPORT_REL")"
status="$(run_apply "$box" '{"0":"Checkout Flow"}')"
assert_eq "shared/fully-named-mirror-survives-a-thin-labels-file" \
  "$fully_named" "$(guard_count "$box/$REPORT_REL")" \
  "exit: $status" "stderr: [$(cat "$box/err.txt")]"

# ================================================================= PART G ===
# INNOV-2xx — staleness is CLUSTER IDENTITY, not name genericness.
#
# graphify re-mints community ids on every rebuild, so a report can be fully
# non-generic while every name describes a cluster that no longer exists.
# Measured 2026-08-19: a mirror whose report had 470 headings against 185
# graph.json communities, 285 of them naming ids absent from graph.json, and
# community 34 named "route.test & related (3)" while holding an entirely
# different node set. The old "generic name => needs labeling" test called that
# state fully labeled, so /brain:label reported "already labeled, 0 batches" —
# the remedy its own guard prescribes was a guaranteed no-op.
#
# Contract: a heading whose id is absent from graph.json is stale; a heading
# whose stated members overlap graph.json's members for that id below the
# threshold is stale. Stale ids are NOT preserved and DO appear in the work
# order. A genuinely current non-generic label is still never overwritten.

echo "--- G. stale-cluster detection (id/member drift) ---"

# Every graph id carries a non-generic heading, but the member lists belong to
# a previous clustering; ids 90/91 are headings for communities that no longer
# exist at all. Nothing here is generic, so the old check saw "nothing to do".
write_stale_mirror() { # box
  local dir="$1/vault/graphify/demo"
  mkdir -p "$dir"
  printf '%s\n' "$GRAPH_JSON" >"$dir/graph.json"
  {
    printf '# Graph Report - graphify/demo/graph.json\n\n'
    printf '## Summary\n- 10 nodes - 2 edges - 6 communities\n\n'
    printf '## Community Hubs (Navigation)\n'
    printf -- '- [[_COMMUNITY_Legacy Zero|Legacy Zero]]\n\n'
    printf '## Communities\n'
    local i
    for i in 0 1 2 3 4 5 90 91; do
      printf '### Community %s - "Legacy Cluster %s"\n' "$i" "$i"
      printf 'Cohesion: 0.04\n'
      printf 'Nodes (3): zz%s_1, zz%s_2, zz%s_3\n\n' "$i" "$i" "$i"
    done
  } >"$dir/demo-GRAPH_REPORT.md"
}

box="$(mktemp -d "$TMPROOT/boxXXXXXX")"
write_stale_mirror "$box"

# Fixture guard: the report really is fully non-generic (8 named headings).
assert_eq "stale/fixture-is-fully-non-generic" "8" "$(guard_count "$box/$REPORT_REL")" \
  "report: [$(cat "$box/$REPORT_REL")]"

status="$(run_label "$box" --digest demo)"
assert_eq "stale/digest-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
cp "$box/out.txt" "$box/digest.json"

assert_eq "stale/work-order-is-not-empty" "true" \
  "$(jexpr "$box/digest.json" 'd[0].batches.length > 0 && d[0].batches[0].length > 0')" \
  "digest: [$(head -c 800 "$box/digest.json")]"
assert_eq "stale/every-drifted-id-is-namable" "0,1,2,3,4,5" \
  "$(jexpr "$box/digest.json" 'Object.keys(d[0].labels_template).map(Number).sort((a,b)=>a-b).join(",")')" \
  "digest: [$(head -c 800 "$box/digest.json")]"
assert_eq "stale/drifted-labels-not-counted-preserved" "0" \
  "$(jexpr "$box/digest.json" 'Object.keys(d[0].preserved).length')" \
  "digest: [$(head -c 800 "$box/digest.json")]"
assert_eq "stale/headings-absent-from-graph-are-reported" "90,91" \
  "$(jexpr "$box/digest.json" '(d[0].stale_headings||[]).map(Number).sort((a,b)=>a-b).join(",")')" \
  "digest: [$(head -c 800 "$box/digest.json")]"

# ...and --apply actually re-names them (the stale label is gone).
status="$(run_apply "$box" '{"0":"Checkout Flow","1":"Auth Middleware","2":"Payments Core","3":"Sync Worker","4":"Alpha Utils","5":"Beta Utils"}')"
assert_eq "stale/apply-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
assert_grep "stale/stale-heading-renamed" '### Community 0 - "Checkout Flow"' "$box/$REPORT_REL" \
  "report: [$(cat "$box/$REPORT_REL")]"
assert_not_grep "stale/stale-label-gone" 'Legacy Cluster 0' "$box/$REPORT_REL"

# ...and run two must be idempotent: a heading renamed out of staleness must
# carry the CURRENT member list, or the next digest re-flags it forever.
status="$(run_label "$box" --digest demo)"
assert_eq "stale/run2-digest-exit-0" "0" "$status" "stderr: [$(cat "$box/err.txt")]"
cp "$box/out.txt" "$box/digest2.json"
assert_eq "stale/run2-fresh-label-preserved" "Checkout Flow" \
  "$(jexpr "$box/digest2.json" "d[0].preserved['0']")" \
  "digest: [$(head -c 800 "$box/digest2.json")]" "report: [$(cat "$box/$REPORT_REL")]"
assert_eq "stale/run2-work-order-empty" "0" \
  "$(jexpr "$box/digest2.json" 'd[0].batches.length + Object.keys(d[0].labels_template).length')" \
  "digest: [$(head -c 800 "$box/digest2.json")]"
assert_eq "stale/run2-absent-headings-still-reported" "90,91" \
  "$(jexpr "$box/digest2.json" '(d[0].stale_headings||[]).map(Number).sort((a,b)=>a-b).join(",")')"

# --- G2. a CURRENT non-generic label is still never overwritten -------------
# Same hard rule as before: the fixture mirror's members match graph.json, so
# "Payments Core" is current, not stale, and survives an --apply that renames it.
box="$(new_box)"
status="$(run_label "$box" --digest demo)"
cp "$box/out.txt" "$box/digest.json"
assert_eq "stale/current-label-still-preserved" "Payments Core" \
  "$(jexpr "$box/digest.json" "d[0].preserved['2']")" \
  "digest: [$(head -c 600 "$box/digest.json")]"
assert_eq "stale/current-mirror-has-no-stale-headings" "" \
  "$(jexpr "$box/digest.json" '(d[0].stale_headings||[]).join(",")')"
status="$(run_apply "$box" '{"2":"Should Not Win","1":"Auth Middleware"}')"
assert_grep "stale/current-label-survives-apply" '### Community 2 - "Payments Core"' "$box/$REPORT_REL"
assert_not_grep "stale/current-label-not-clobbered" "Should Not Win" "$box/$REPORT_REL"

# ================================================================= SUMMARY ==
echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
