#!/usr/bin/env bash
# check-shadow-install.sh — is more than one brain-family plugin live here?
# (INNOV-318, /brain:doctor check 12)
#
# WHY THIS EXISTS. Different plugin names are different plugins to Claude Code,
# and the same name at two scopes is two installs — nothing stops either, and
# nothing reported it. Both copies bind the same vault ($BRAIN_ROOT), so two sets
# of hooks fire and two `/…:save` commands write the same hot.md. SPO-324 cost a
# day this way: "the 0.2.34 fix doesn't work" was a stale PROJECT-scoped install
# shadowing a current USER-scoped one — three versions live at once, no warning.
# The tray-brain -> brain migration makes the same state for anyone who installs
# before uninstalling. The check is deliberately general ("more than one"), not
# migration-specific, so it stays useful after the migration is over.
#
# WHAT COUNTS AS LIVE for the project (CLAUDE_PROJECT_DIR, else cwd):
#   - installed_plugins.json records: scope "user" everywhere; scope
#     "project"/"local" only when the record's projectPath is this project;
#   - enabledPlugins === true in user ~/.claude/settings.json, the project's
#     .claude/settings.json, or its .claude/settings.local.json;
#   minus any key set enabledPlugins === false at that same scope.
# One entry per (key, scope). The marketplace cache is a VERSION source for a
# settings-only entry, never an install source — a leftover cache dir alone is
# not live. A project/local record with no projectPath is counted and flagged
# rather than dropped: a false ❌ costs a look, a false ✅ cost SPO-324.
#
# Brain-family: the plugin name is `brain` or ends in `-brain`, or its install
# carries bin/vault-commit.sh (the vault commit path only a brain ships).
#
# Contract (the /brain:doctor skill and its tests depend on exactly this):
#   exit 0  => at most one brain-family install is live (OK), or undeterminable (SKIPPED)
#   exit 1  => SHADOWED — two or more are live; each is named with version,
#              scope, and the exact uninstall command. Nothing is uninstalled.
# First line: "SHADOW-INSTALL: OK" / "SHADOW-INSTALL: SKIPPED" (stdout) or
# "SHADOW-INSTALL: SHADOWED" (stderr).
set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
[[ -d "$PROJECT" ]] || PROJECT="$PWD"
# `pwd -W` gives Git Bash a Windows-native path node can resolve.
PROJECT="$(cd "$PROJECT" && { pwd -W 2>/dev/null || pwd; })"
CLAUDE_DIR_N="$(cd "$CLAUDE_DIR" 2>/dev/null && { pwd -W 2>/dev/null || pwd; })"

if ! command -v node >/dev/null 2>&1; then
  echo "SHADOW-INSTALL: SKIPPED - node is not on PATH, cannot read the plugin registries"
  exit 0
fi
if [[ -z "$CLAUDE_DIR_N" ]]; then
  echo "SHADOW-INSTALL: SKIPPED - no Claude config dir at '$CLAUDE_DIR'"
  exit 0
fi

# Prints one TSV line per live brain-family entry: key, scope, version, where.
LIVE="$(node -e '
  const fs = require("fs"), path = require("path");
  const [claudeDir, project] = process.argv.slice(1);
  const norm = p => { const r = path.resolve(p).replace(/\\/g, "/").replace(/\/$/, "");
                      return process.platform === "win32" ? r.toLowerCase() : r; };
  const readJson = f => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { return null; } };
  const nameOf = k => k.slice(0, k.lastIndexOf("@") < 0 ? k.length : k.lastIndexOf("@"));
  const mpOf = k => k.lastIndexOf("@") < 0 ? "" : k.slice(k.lastIndexOf("@") + 1);
  const cacheDirs = k => { const d = path.join(claudeDir, "plugins", "cache", mpOf(k), nameOf(k));
    try { return fs.readdirSync(d).sort().map(v => path.join(d, v)); } catch (e) { return []; } };
  const isBrain = (k, installPath) => /(^|-)brain$/.test(nameOf(k)) ||
    [installPath, ...cacheDirs(k)].some(p => p && fs.existsSync(path.join(p, "bin", "vault-commit.sh")));

  const settings = {
    user: readJson(path.join(claudeDir, "settings.json")),
    project: readJson(path.join(project, ".claude", "settings.json")),
    local: readJson(path.join(project, ".claude", "settings.local.json")),
  };
  const enabled = (scope, k) => ((settings[scope] || {}).enabledPlugins || {})[k];

  const live = new Map(); // "key\tscope" -> {version, where}
  const add = (k, scope, version, where, installPath) => {
    if (!isBrain(k, installPath) || enabled(scope, k) === false) return;
    const id = k + "\t" + scope;
    if (!live.has(id) || (!live.get(id).version && version)) live.set(id, { version, where });
  };

  const installed = (readJson(path.join(claudeDir, "plugins", "installed_plugins.json")) || {}).plugins || {};
  for (const [k, recs] of Object.entries(installed)) {
    for (const r of Array.isArray(recs) ? recs : []) {
      const scope = r.scope || "user";
      if (scope === "user") add(k, scope, r.version, "", r.installPath);
      else if (!r.projectPath) add(k, scope, r.version, "project path not recorded", r.installPath);
      else if (norm(r.projectPath) === norm(project)) add(k, scope, r.version, r.projectPath, r.installPath);
    }
  }
  for (const scope of ["user", "project", "local"]) {
    for (const [k, on] of Object.entries((settings[scope] || {}).enabledPlugins || {})) {
      if (on !== true) continue;
      const recs = Array.isArray(installed[k]) ? installed[k] : [];
      const cached = cacheDirs(k).map(p => path.basename(p)).pop() || "";
      const v = (recs.find(r => (r.scope || "user") === scope) || {}).version || cached;
      add(k, scope, v, scope === "user" ? "" : project, "");
    }
  }
  for (const [id, { version, where }] of live) console.log([id, version || "?", where].join("\t"));
' "$CLAUDE_DIR_N" "$PROJECT" 2>/dev/null)"

COUNT=0
[[ -n "$LIVE" ]] && COUNT="$(printf '%s\n' "$LIVE" | grep -c .)"

if [[ "$COUNT" -eq 0 ]]; then
  echo "SHADOW-INSTALL: SKIPPED - no brain-family plugin recorded as installed or enabled"
  echo "  This machine may run the plugin from source (--plugin-dir), which cannot shadow." >&2
  exit 0
fi

if [[ "$COUNT" -eq 1 ]]; then
  IFS=$'\t' read -r key scope ver where <<<"$LIVE"
  echo "SHADOW-INSTALL: OK - one brain-family plugin live here: $key $ver ($scope scope)"
  exit 0
fi

{
  echo "SHADOW-INSTALL: SHADOWED - $COUNT brain-family plugin installs are live for this project, all bound to the same vault"
  while IFS=$'\t' read -r key scope ver where; do
    echo "  - $key $ver ($scope scope${where:+, $where})"
    if [[ "$scope" == "user" ]]; then
      echo "      uninstall: claude plugin uninstall $key --scope user"
    else
      echo "      uninstall: claude plugin uninstall $key --scope $scope   (run from ${where})"
    fi
  done <<<"$LIVE"
  echo "  Two copies means two sets of hooks and two save commands writing the same"
  echo "  hot.md — and whichever loads first decides which fixes are actually running."
  echo "  Keep ONE (normally the newest, user-scoped), uninstall the rest, then restart"
  echo "  the session. Doctor never uninstalls for you: this touches global config."
} >&2
exit 1
