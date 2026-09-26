# Migrating to the `agent-infra` marketplace (INNOV-320)

The marketplace was renamed from `brain-marketplace` to `agent-infra`. It ships more than
`brain` now (`wave` too), and the old name no longer described it. Claude Code keys every
install as `plugin@marketplace`, so an existing install does not follow the rename. Everyone
re-adds once.

**There are two audiences, and their steps differ. Find yours:**

| You install from | Marketplace URL after the rename | Plugin prefix |
|---|---|---|
| **The source repo**, registered as `brain-marketplace` | `karch4162/agent-infra`. The repo was renamed from `karch4162/brain-plugin` on 2026-09-26; the old URL redirects. | `/brain:` (unchanged) |
| **The Tray fork** (`vendsy/tray-brain-plugin`), plugin `tray-brain` | **New URL:** `vendsy/agent-infra` | `/tray-brain:` becomes `/brain:` |

Source-repo users do **not** point at `vendsy/agent-infra`. That mirror exists only because
the Tray fork is being archived.

**Add one of the two URLs, never both.** Both repos serve a manifest named `agent-infra`, and
a marketplace registers under its manifest name (confirmed in the rehearsal). So the two URLs
compete for the same registration. Pick the one from your row of the table.

**Migrate soon after the rename reaches your URL, not on the next update.** Git-sourced
marketplaces refresh in the background at startup. After a refresh, the registration still
named `brain-marketplace` holds a manifest named `agent-infra`. **⚠ UNCONFIRMED but
expected:** the host then fails to load `brain@brain-marketplace` ("Plugin not found in
marketplace"). If the plugin doesn't load, `/brain:doctor` can't run to tell you why. If
your brain commands have vanished, that's the likely cause, and the steps below still fix
it. `marketplace update brain-marketplace` / `plugin update` do **not** fix it: the names no
longer match, and only remove-and-re-add does.

**Your vault binding doesn't move.** The registry lives at `~/.claude/brain/registry.json`,
and bindings are per vault, not per plugin, so `BRAIN_ROOT` and `.brain/config.json` are
unchanged. **One vault file does change:** the `repos.json` entry for the plugin repo
itself. Your other projects' entries, and their graphs, are untouched. See section D.

**Uninstall first, then install.** Two brain-family plugins bound to the same vault both
fire their hooks and both write the same `hot.md`. `/brain:doctor` check 12 reports that
state, but it's cheaper not to create it.

> **Status of these steps.** Section A was walked on the maintainer's machine on 2026-09-26.
> Every step worked as written, and checks 7 and 12 both came back OK afterwards. Steps marked
> ✔ **observed** were seen working. Two behaviours are still **⚠ UNCONFIRMED**, because the
> rehearsal couldn't reach them: `uninstall` at a scope with nothing installed (B.1), and the
> old key breaking after a refresh (above).

## A. Source-repo user (`brain-marketplace` → `agent-infra`)

A typical `~/.claude/settings.json` before migrating:

```json
"extraKnownMarketplaces": { "brain-marketplace": { "source": { "source": "git", "url": "https://github.com/karch4162/brain-plugin.git" } } },
"enabledPlugins": { "brain@brain-marketplace": true, "wave@brain-marketplace": true }
```

1. ✔ **observed.** Uninstall the old keys. Add `--scope project` for any repo where you
   installed at project scope. Uninstall also removes the keys from `enabledPlugins`, so
   there's nothing to clean up by hand.
   ```bash
   claude plugin uninstall brain@brain-marketplace --scope user
   claude plugin uninstall wave@brain-marketplace  --scope user
   ```
2. ✔ **observed.** Remove the old marketplace registration, and the fork's if you ever added
   it (section C). With no `--scope`, this removes the declaration from every settings scope.
   ```bash
   claude plugin marketplace remove brain-marketplace
   claude plugin marketplace remove tray-brain-marketplace   # only if registered
   ```
3. ✔ **observed.** Add the source repo under its new URL. It registers as `agent-infra`,
   the name in the manifest, and reports "declared in user settings".
   ```bash
   claude plugin marketplace add https://github.com/karch4162/agent-infra
   ```
4. ✔ **observed.** Install under the new key:
   ```bash
   claude plugin install brain@agent-infra
   claude plugin install wave@agent-infra      # if you use wave
   ```
5. ✔ **observed.** Restart Claude Code (or `/reload-plugins`), then run `/brain:doctor`.
   Check 7 should report `brain@agent-infra`, and check 12 should report exactly one brain
   install.
6. If you recloned the source repo instead of running `git remote set-url` on your existing
   checkout, also do section D: the vault's `repos.json`, **and a graph build in the new
   clone**.

Old cache directories (`~/.claude/plugins/cache/brain-marketplace/`, `…/tray-brain-marketplace/`)
stay on disk after the uninstall. Check 12 doesn't count them as installs. Delete them once no
session or wave worker started before the migration is still running, because those still
point into them.

## B. Tray user (`tray-brain` fork → `vendsy/agent-infra`)

Don't start until the `vendsy/agent-infra` mirror serves the renamed manifest: its
`.claude-plugin/marketplace.json` on `main` should say `"name": "agent-infra"`. If it still
says `brain-marketplace`, the mirror predates the rename. Adding it then registers the old
name, and you'd have to migrate a second time.

1. ✔ Uninstall `tray-brain` at **both** scopes. A project-scoped copy left behind shadows
   the user-scoped one without any warning (SPO-324). Run the project-scope command from
   each repo that had it installed:
   ```bash
   claude plugin uninstall tray-brain@tray-brain-marketplace --scope user
   claude plugin uninstall tray-brain@tray-brain-marketplace --scope project
   ```
   **⚠ UNCONFIRMED:** what `uninstall` does at a scope where nothing is installed. It is
   expected to fail harmlessly.
2. ✔ Remove the fork's marketplace registration. See section C:
   ```bash
   claude plugin marketplace remove tray-brain-marketplace
   ```
3. ✔ Add the new mirror and install:
   ```bash
   claude plugin marketplace add https://github.com/vendsy/agent-infra
   claude plugin install brain@agent-infra
   ```
4. Restart Claude Code (or `/reload-plugins`), then run `/brain:doctor`. The commands have
   lost the `tray-` prefix: `/tray-brain:save` is now `/brain:save`. Check 13 finds any
   `/tray-brain:` still named in your vault's `CLAUDE.md`, and repair R10 rewrites it.
   Check 12 should report exactly one brain install.

## C. A stale `tray-brain-marketplace` registration

This applies to anyone who ever added the fork, including a source-repo user who never
installed from it. After the archive, the entry points at a read-only repo that will never
update.

✔ **observed.** Remove it:
```bash
claude plugin marketplace remove tray-brain-marketplace
```

**`/brain:doctor` will not find this for you.** Check 12 counts installed and enabled plugins,
not marketplace registrations, so an entry with no plugin enabled from it is invisible to it.
Look for `tray-brain-marketplace` in `claude plugin marketplace list` (or under
`extraKnownMarketplaces` in `~/.claude/settings.json`). Tracked as INNOV-336.

## D. The vault's `repos.json` entry for the plugin repo

A vault finds a repo's checkout through `repos.json`, which maps each repo **name** to one git
**remote**, e.g. `"tray-brain-plugin": { "remote": "github.com/vendsy/tray-brain-plugin" }`.
Anchors (`source: tray-brain-plugin/...`) and the graph mirror (`graphify/tray-brain-plugin/`)
use the name. A checkout is matched to that entry only by its `origin` URL
(`brain/bin/resolve-repos.mjs`); folder names don't count.

So when the plugin repo's URL changes, **update the `remote` and keep the name:**

| Vault | Entry | New `remote` |
|---|---|---|
| `tray-brain` | `tray-brain-plugin` | `github.com/vendsy/agent-infra` |
| `personal-brain` | `brain-plugin` | `github.com/karch4162/agent-infra` (done 2026-09-26) |

**Keep the key.** Renaming it (`tray-brain-plugin` → `agent-infra`) is what actually strands
every anchor and orphans the existing graph mirror.

**Why this matters beyond anchors.** When a checkout doesn't resolve, `sync-graph.sh` names its
mirror after the checkout's **folder**. A fresh clone of `vendsy/agent-infra` lands in a folder
named `agent-infra`. With a stale `remote` it would publish a *second* mirror,
`graphify/agent-infra/`, next to the real `graphify/tray-brain-plugin/`, and nothing reports it.

`repos.json` is deliberately left out of `.saveinclude`, so no brain command commits it.
Change it on a branch and open a PR, like a trusted wiki note.

**Order, and who does what:**
1. The vault maintainer changes the `remote` in the vault's `repos.json` and commits it.
   **One edit for everyone.** Do it at the cutover, not before: a checkout still cloned from
   `vendsy/tray-brain-plugin` stops resolving the moment it changes.
2. Each user either runs `git remote set-url origin <new URL>` in their existing checkout, or
   reclones. On the next run, the cached path in `repos.local.json` fails its remote check,
   and the resolver finds the checkout again by remote. It only looks inside the directories
   it is set to scan, so clone into the same parent directory as your other repos.
3. **If you recloned, build the graph once in the new clone** (`/graphify` there).
   `graphify-out/` is not in git, so a fresh clone has no graph. The vault's mirror is
   *copied from* that checkout's graph, so until you build one the mirror stays frozen at its
   last copy. `/brain:doctor` reports a missing local graph as optional ("only if you want the
   cwd query hook"); for this repo it isn't (INNOV-338). **Don't** copy the old folder's
   `graphify-out/` across as a shortcut: sync copies whenever the two differ, so an older
   graph would overwrite a newer mirror.

**⚠ Known limit.** An entry holds exactly one remote, and only `origin` is read. A machine whose
checkout comes from the *source* (`karch4162/…`) can't resolve the Tray vault's entry, and the
reverse is true too. A maintainer who needs both vaults to resolve needs two clones. This was
already the case before the rename. Tracked as INNOV-337.

**No other graph rebuilds.** Every other project's graph lives in its own `graphify-out/`, and
graphify's own post-commit hook rebuilds it. The hook calls the graphify CLI and never touches
the brain plugin's install, so uninstalling `tray-brain` leaves those graphs and hooks as they
were. Only a *fresh clone* of the plugin repo needs a build (step 3).
