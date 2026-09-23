#!/usr/bin/env bash
# Checklist steps 1 and 3, scoped to THIS repo's Orca worktrees.
#
#   bash "$WAVE/status.sh"           # leftovers: name | status | PR
#   bash "$WAVE/status.sh" --sweep   # prints rm commands for merged worktrees; read, then pipe to bash
#
# `orca worktree ps` lists every repo Orca manages. Unfiltered, the sweep once offered
# to delete a merged worktree from an unrelated work monorepo - hence the repo filter.
# Selector is name:<displayName>: the documented id:<repo>::<path> form returns
# selector_not_found on Windows and fails silently per line when piped.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REPO_ID="$(orca_repo_id)"
[ -n "$REPO_ID" ] || { echo "$MAIN_CHECKOUT is not registered with Orca" >&2; exit 1; }

orca worktree ps --json | python -c "
import sys, json
repo, sweep = sys.argv[1], sys.argv[2] == '--sweep'
for w in json.load(sys.stdin)['result']['worktrees']:
    if w['isMainWorktree'] or not w['worktreeId'].startswith(repo + '::'): continue
    pr = w.get('linkedPR') or {}
    if not sweep:
        print(w['displayName'], '|', w.get('workspaceStatus'), '| PR', pr.get('number'), pr.get('state'))
    elif pr.get('state') == 'merged':
        print('orca worktree rm --worktree \"name:%s\" --force' % w['displayName'])
" "$REPO_ID" "${1:-}"
