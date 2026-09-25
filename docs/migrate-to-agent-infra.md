# Migrating to the `agent-infra` marketplace (INNOV-320)

The marketplace was renamed from `brain-marketplace` to `agent-infra`. It ships more than
`brain` now (`wave` too), and the old name no longer described it. Claude Code keys every
install as `plugin@marketplace`, so an existing install does not follow the rename. Everyone
re-adds once.

**There are two audiences, and their steps differ. Find yours:**

| You install from | Marketplace URL after the rename | Plugin prefix |
|---|---|---|
| **The source repo** (`karch4162/brain-plugin`), registered as `brain-marketplace` | **Same URL.** Only the registered name changes. | `/brain:` (unchanged) |
| **The Tray fork** (`vendsy/tray-brain-plugin`), plugin `tray-brain` | **New URL:** `vendsy/agent-infra` | `/tray-brain:` becomes `/brain:` |

Source-repo users do **not** point at `vendsy/agent-infra`. That mirror exists only because
the Tray fork is being archived. The source repo is deliberately never renamed, because
renaming it would strand every `source: brain-plugin/...` anchor in the vault.

**Nothing in your vault moves.** The registry lives at `~/.brain`, and bindings are per
vault, not per plugin, so `BRAIN_ROOT` and `.brain/config.json` are unchanged.

**Uninstall first, then install.** Two brain-family plugins bound to the same vault both
fire their hooks and both write the same `hot.md`. `/brain:doctor` check 12 reports that
state, but it's cheaper not to create it.

> **Status of these steps.** Each command below is confirmed against `claude plugin … --help`
> (Claude Code's own CLI help), and marked ✔. Steps marked **⚠ UNCONFIRMED** describe
> behaviour nobody has observed yet. The first walk-through on the maintainer's machine should
> confirm or correct them before anyone else follows this note.

## A. Source-repo user (`brain-marketplace` → `agent-infra`, same URL)

A typical `~/.claude/settings.json` before migrating:

```json
"extraKnownMarketplaces": { "brain-marketplace": { "source": { "source": "git", "url": "https://github.com/karch4162/brain-plugin.git" } } },
"enabledPlugins": { "brain@brain-marketplace": true, "wave@brain-marketplace": true }
```

1. ✔ Uninstall the old keys (add `--scope project` for any repo where you installed at
   project scope):
   ```bash
   claude plugin uninstall brain@brain-marketplace --scope user
   claude plugin uninstall wave@brain-marketplace  --scope user
   ```
2. ✔ Remove the old marketplace registration. With no `--scope`, this removes the
   declaration from every settings scope:
   ```bash
   claude plugin marketplace remove brain-marketplace
   ```
   **⚠ UNCONFIRMED:** whether this also drops the `brain@brain-marketplace` /
   `wave@brain-marketplace` entries from `enabledPlugins`. Check `settings.json` afterwards,
   and if they are still there, delete them by hand. They point at a marketplace that no
   longer exists.
3. ✔ Re-add the **same** URL:
   ```bash
   claude plugin marketplace add https://github.com/karch4162/brain-plugin
   ```
   **⚠ UNCONFIRMED:** that the re-added marketplace registers as `agent-infra` (the name in
   the manifest it serves) and not under some other key. Confirm with
   `claude plugin marketplace list` before step 4.
4. ✔ Install under the new key:
   ```bash
   claude plugin install brain@agent-infra
   claude plugin install wave@agent-infra      # if you use wave
   ```
5. Restart Claude Code (or `/reload-plugins`), then run `/brain:doctor`. Check 7 should report
   the install as `brain@agent-infra`, and check 12 should report exactly one brain install.

## B. Tray user (`tray-brain` fork → `vendsy/agent-infra`)

Don't start until the `vendsy/agent-infra` mirror has been published. It doesn't exist
when this note is written.

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

✔ Remove it:
```bash
claude plugin marketplace remove tray-brain-marketplace
```

**`/brain:doctor` will not find this for you.** Check 12 counts installed and enabled plugins,
not marketplace registrations, so an entry with no plugin enabled from it is invisible to it.
Look for `tray-brain-marketplace` in `claude plugin marketplace list` (or under
`extraKnownMarketplaces` in `~/.claude/settings.json`).
