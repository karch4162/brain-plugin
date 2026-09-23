#!/usr/bin/env bash
# Sourced by every wave script. Loads the target repo's wave config and derives
# what the repo already knows (main checkout, base ref, Orca repo id).
#
# Per-project config lives in the TARGET repo, committed:
#   .claude/wave/config.env   required - tracker + queue (see config.example.env)
#   .claude/wave/notes.md     optional - project rules appended to the worker prompt
# Bash 3.2-safe (INNOV-284): see tests/test-bash32-portability.sh.

WAVE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)" || { echo "wave: not inside a git repo" >&2; exit 1; }
# The common dir is the main checkout's .git, even from inside a worktree.
MAIN_CHECKOUT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
WAVE_CONFIG="$ROOT/.claude/wave/config.env"
WAVE_NOTES_FILE="$ROOT/.claude/wave/notes.md"

[ -f "$WAVE_CONFIG" ] || {
  echo "wave: no $WAVE_CONFIG - copy $WAVE_HOME/config.example.env there and fill it in" >&2
  exit 1
}
# shellcheck disable=SC1090
. "$WAVE_CONFIG"

for v in WAVE_TRACKER WAVE_QUEUE WAVE_STATE_START WAVE_STATE_DONE WAVE_FILE_TO; do
  eval "[ -n \"\${$v:-}\" ]" || { echo "wave: $v is not set in $WAVE_CONFIG" >&2; exit 1; }
done

case "$WAVE_TRACKER" in
  linear)
    TRACKER_NAME="Linear"
    TRACKER_OPS="\`orca linear\`"
    TRACKER_ATTACH="attach it with \`orca linear attach\`" ;;
  jira)
    TRACKER_NAME="Jira"
    TRACKER_OPS="the Atlassian MCP Jira tools (site ${WAVE_JIRA_SITE:?set WAVE_JIRA_SITE in $WAVE_CONFIG})"
    TRACKER_ATTACH="add the PR URL to the issue as a comment" ;;
  *) echo "wave: WAVE_TRACKER must be linear or jira, got '$WAVE_TRACKER'" >&2; exit 1 ;;
esac

# Base ref: explicit override, else whatever origin/HEAD points at.
if [ -z "${WAVE_BASE:-}" ]; then
  WAVE_BASE="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || {
    echo "wave: origin/HEAD is unset - run 'git remote set-head origin -a' or set WAVE_BASE" >&2
    exit 1
  }
fi
BASE_BRANCH="${WAVE_BASE#origin/}"

WAVE_NOTES=""
[ -f "$WAVE_NOTES_FILE" ] && WAVE_NOTES="$(cat "$WAVE_NOTES_FILE")"

# Orca's repo id for this checkout. Called lazily - DRY_RUN and tests never need Orca.
orca_repo_id() {
  orca repo list --json | python -c "
import sys, json, os
want = os.path.normcase(os.path.realpath(sys.argv[1]))
for r in json.load(sys.stdin)['result']['repos']:
    if os.path.normcase(os.path.realpath(r['path'])) == want: print(r['id']); break
" "$(cygpath -m "$MAIN_CHECKOUT" 2>/dev/null || echo "$MAIN_CHECKOUT")"   # Windows python cannot read /c/...
}
