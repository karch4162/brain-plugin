#!/usr/bin/env bash
# check-command-prefix.sh — does the vault's CLAUDE.md name THIS plugin's commands?
# (INNOV-318, /brain:doctor check 13)
#
# WHY THIS EXISTS. The vault's CLAUDE.md tells every agent which commands to run
# (`/brain:save`, `/brain:resume`, ...). After a rename (tray-brain -> brain) it
# still says `/tray-brain:save` — a command that no longer exists, so the agent
# either fails or, worse, finds a leftover second install still answering to it
# (check 12). The installed namespace is read from THIS copy's own plugin.json
# and the command names from its own skills/ dir — no list to drift.
#
# A token is stale when it is `/<ns>:<skill>` with <skill> one of our skills and
# <ns> a brain-family name (`brain` or `*-brain`) other than ours. Anything else —
# another plugin's `/foo:save` — is left alone.
#
# Usage:
#   bash check-command-prefix.sh          # from the vault root, or with BRAIN_ROOT=<vault>
#   bash check-command-prefix.sh --fix    # rewrite stale prefixes in place
#
# --fix rewrites ONLY the stale tokens, in the raw text, so line endings (the
# vault is autocrlf) and every other byte survive. A file with nothing stale is
# not rewritten at all. It never commits: CLAUDE.md is a governance file outside
# .saveinclude, so vault-commit.sh would refuse it by design — commit it
# deliberately, like R7/R8.
#
# Contract:
#   exit 0  => OK (no stale prefix, or --fix just rewrote them), or SKIPPED
#   exit 1  => STALE — names each stale prefix and its count
# First line: "COMMAND-PREFIX: OK" / "COMMAND-PREFIX: SKIPPED" (stdout) or
# "COMMAND-PREFIX: STALE" (stderr).
set -uo pipefail

FIX=0
case "${1:-}" in
  --fix) FIX=1 ;;
  "") ;;
  *) echo "COMMAND-PREFIX: SKIPPED - unknown argument '$1'"; exit 0 ;;
esac

VAULT="${BRAIN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && { pwd -W 2>/dev/null || pwd; })"

command -v node >/dev/null 2>&1 || { echo "COMMAND-PREFIX: SKIPPED - node is not on PATH"; exit 0; }
[[ -d "$VAULT/wiki" ]] || { echo "COMMAND-PREFIX: SKIPPED - '$VAULT' is not a vault (no wiki/)"; exit 0; }
[[ -f "$VAULT/CLAUDE.md" ]] || { echo "COMMAND-PREFIX: SKIPPED - vault has no CLAUDE.md"; exit 0; }
VAULT="$(cd "$VAULT" && { pwd -W 2>/dev/null || pwd; })"

node -e '
  const fs = require("fs"), path = require("path");
  const [root, file, fix] = process.argv.slice(1);
  let ns = "";
  try { ns = JSON.parse(fs.readFileSync(path.join(root, ".claude-plugin", "plugin.json"), "utf8")).name || ""; } catch (e) {}
  let skills = [];
  try { skills = fs.readdirSync(path.join(root, "skills")).filter(d => fs.existsSync(path.join(root, "skills", d, "SKILL.md"))); } catch (e) {}
  if (!ns || !skills.length) {
    console.log("COMMAND-PREFIX: SKIPPED - cannot read this plugin'"'"'s name or skills under " + root);
    process.exit(0);
  }
  const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp("/([A-Za-z0-9_-]*brain):(" + skills.map(esc).join("|") + ")(?![A-Za-z0-9_-])", "g");
  const text = fs.readFileSync(file, "utf8");
  const stale = {};
  const out = text.replace(re, (m, p, s) => {
    if (p === ns || !/(^|-)brain$/.test(p)) return m;
    stale[p] = (stale[p] || 0) + 1;
    return "/" + ns + ":" + s;
  });
  const found = Object.entries(stale);
  if (!found.length) {
    console.log("COMMAND-PREFIX: OK - CLAUDE.md commands all use /" + ns + ":");
    process.exit(0);
  }
  const list = found.map(([p, n]) => "/" + p + ": x" + n).join(", ");
  if (fix === "1") {
    fs.writeFileSync(file, out);
    console.log("COMMAND-PREFIX: OK - rewrote " + list + " to /" + ns + ": in CLAUDE.md (not committed)");
    process.exit(0);
  }
  console.error("COMMAND-PREFIX: STALE - vault CLAUDE.md names " + list + ", but the installed plugin is /" + ns + ":");
  console.error("  Agents reading it run commands that no longer exist — or a leftover second");
  console.error("  install (check 12) answers them. Remedy: re-run with --fix, then commit");
  console.error("  CLAUDE.md deliberately (it is outside .saveinclude, by design).");
  process.exit(1);
' "$SELF_ROOT" "$VAULT/CLAUDE.md" "$FIX"
