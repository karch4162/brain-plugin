#!/usr/bin/env bash
# Per-ticket token split: Claude worker session vs the Codex review.
#   bash "$WAVE/cost.sh" INNOV-309 INNOV-301
# Worker numbers come from ~/.claude/projects/<worktree>/*.jsonl; review numbers from
# the "tokens used" lines Codex leaves in .wave-review.codex-terra.err.
set -uo pipefail
WS="$(dirname "$(git rev-parse --show-toplevel)")"
for ISSUE in "$@"; do
  WT="$WS/$(tr 'A-Z' 'a-z' <<< "$ISSUE")"
  python - "$ISSUE" "$(cygpath -w "$WT" 2>/dev/null || echo "$WT")" "$WT" <<'PY'
import json,sys,os,glob,re,collections
issue,wt_win,wt=sys.argv[1:4]
proj=os.path.expanduser('~/.claude/projects/'+wt_win.replace(':','-').replace('/','-').replace(chr(92),'-'))
per=collections.defaultdict(collections.Counter)
for f in glob.glob(proj+'/*.jsonl'):
    for line in open(f,encoding='utf-8',errors='ignore'):
        try: m=json.loads(line).get('message') or {}
        except Exception: continue
        u=m.get('usage')
        if u and m.get('model'):
            for k,v in u.items():
                if isinstance(v,(int,float)): per[m['model']][k]+=v
print(issue)
for model,c in sorted(per.items(),key=lambda kv:-kv[1]['cache_read_input_tokens']):
    print(f"  worker {model:32} cache_read={c['cache_read_input_tokens']/1e6:.1f}M cache_write={c['cache_creation_input_tokens']/1e3:.0f}k out={c['output_tokens']/1e3:.0f}k")
err=os.path.join(wt,'.wave-review.codex-terra.err')
if os.path.exists(err):
    txt=open(err,encoding='utf-8',errors='ignore').read()
    used=sum(int(n.replace(',','')) for n in re.findall(r'tokens used\s*\n\s*([\d,]+)',txt))
    print(f"  review codex-terra{' '*15}total={used/1e3:.0f}k")
PY
done
