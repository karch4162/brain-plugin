#!/usr/bin/env node
// resolve-repos.mjs — map canonical repo names to local checkouts, portably.
//
// THE PROBLEM THIS SOLVES
// A note's `source:` anchor names a repo ("nodejs/foo/bar.js"). Turning that into
// a file on disk used to mean `join(REPOS_DIR, 'nodejs', ...)`, which silently
// assumes every covered repo is a directory sitting directly under one shared
// parent. Two things break that:
//
//   1. Repos that live at a SUB-PATH of a checkout. Five of tray-brain's nine
//      covered "repos" (KDS, nodejs, POS, Tray-Library, tray-server) are all
//      inside a single `monorepo` clone. No value of REPOS_DIR resolves those
//      AND the standalone repos at the same time.
//   2. Engineers laying out checkouts differently — `monorepo` vs `monorepo-4`,
//      nested vs flat, or on another drive entirely. Standardising that across a
//      team does not scale.
//
// THE MODEL: the vault stores IDENTITY; each machine stores LOCATION.
//
//   repos.json        committed, machine-independent, zero local paths:
//                       { "repos": { "<name>": { "remote": "...", "subPath": "..." } } }
//   repos.local.json  gitignored, generated, per-repo absolute paths:
//                       { "<name>": "/abs/path/to/checkout[/subPath]" }
//
// Because locations are PER REPO, there is no requirement that they share a
// parent — REPOS_DIR demotes from a structural constraint to a search hint used
// only during discovery.
//
// Matching is by git REMOTE, never by folder name, so a rename or a different
// clone directory changes nothing.
//
// Pure Node, no deps. Read-only unless called with --write.

import { readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import { join, resolve, isAbsolute } from 'node:path';

/**
 * Canonicalize a git remote to `host/owner/name`, so these all compare equal:
 *   https://github.com/vendsy/monorepo.git
 *   git@github.com:vendsy/monorepo.git
 *   ssh://git@github.com/vendsy/monorepo
 * Nested GitLab groups (a/b/c) are preserved — they are part of the identity.
 */
export function normalizeRemote(url) {
  if (!url) return null;
  let s = String(url).trim().replace(/\.git$/, '').replace(/\/+$/, '');
  s = s.replace(/^[a-z+]+:\/\//i, '');   // strip scheme
  s = s.replace(/^[^@/]+@/, '');          // strip user@
  s = s.replace(/:(?!\d)/, '/');          // scp-style host:path → host/path (not a port)
  return s.toLowerCase() || null;
}

function readJson(file) {
  if (!existsSync(file)) return null;
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return null; // a corrupt cache must never be fatal — we just re-detect
  }
}

/** Read a checkout's origin remote (first url= wins), normalized. */
export function remoteOf(dir) {
  const cfg = join(dir, '.git', 'config');
  if (!existsSync(cfg)) return null;
  const m = readFileSync(cfg, 'utf8').match(/^\s*url\s*=\s*(\S+)\s*$/m);
  return m ? normalizeRemote(m[1]) : null;
}

/**
 * Find every git checkout under the search roots, keyed by normalized remote.
 * Depth 2 catches the common `~/Projects/<org>/<repo>` nesting without turning
 * into a full filesystem crawl.
 */
export function discoverCheckouts(searchRoots, maxDepth = 2) {
  const byRemote = new Map();
  const seen = new Set();
  const visit = (dir, depth) => {
    if (depth > maxDepth || seen.has(dir) || !existsSync(dir)) return;
    seen.add(dir);
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return; // unreadable dir (permissions, junction) — skip, never throw
    }
    for (const e of entries) {
      if (!e.isDirectory() || e.name === 'node_modules' || e.name.startsWith('.')) continue;
      const sub = join(dir, e.name);
      const remote = remoteOf(sub);
      if (remote) {
        if (!byRemote.has(remote)) byRemote.set(remote, sub);
        continue; // a checkout's children are not separate checkouts
      }
      visit(sub, depth + 1);
    }
  };
  for (const root of searchRoots) visit(root, 1);
  return byRemote;
}

/** Covered repo names = the graphify/ mirror folders in the vault. */
export function mirrorNames(vault) {
  const dir = join(vault, 'graphify');
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
}

/**
 * Resolve every repo named in repos.json to an absolute local path.
 *
 * Order per repo: trust the cached local path (only if it still exists AND its
 * remote still matches — a moved or repurposed directory must not silently keep
 * resolving), else re-discover by remote.
 *
 * Returns paths already including subPath, so callers can join anchor-relative
 * paths onto them directly.
 */
export function resolveRepos(vault, searchRoots = []) {
  const identity = readJson(join(vault, 'repos.json'))?.repos || null;
  const cache = readJson(join(vault, 'repos.local.json')) || {};
  const paths = new Map();
  // name → { root, subPath }. Callers verifying a pinned revision need the
  // CHECKOUT ROOT (to run git in) and the subPath (to rebuild a repo-relative
  // path) separately — the joined path in `paths` cannot be split back apart
  // reliably on Windows.
  const meta = new Map();
  const unresolved = [];
  let cacheChanged = false;

  if (!identity) return { identity: null, paths, meta, unresolved, cache, cacheChanged, discovered: null };

  let discovered = null; // built lazily — scanning is the expensive part
  const discover = () => (discovered ??= discoverCheckouts(searchRoots));

  for (const [name, spec] of Object.entries(identity)) {
    const want = normalizeRemote(spec?.remote);
    const sub = spec?.subPath || '';

    const cached = cache[name];
    if (cached && existsSync(cached)) {
      // Validate against the checkout root, not the subPath dir.
      const root = sub ? cached.slice(0, cached.length - sub.length - 1) : cached;
      if (!want || remoteOf(root) === want) {
        paths.set(name, cached);
        meta.set(name, { root, subPath: sub });
        continue;
      }
    }

    const root = want ? discover().get(want) : null;
    if (!root) {
      unresolved.push(name);
      if (cache[name]) { delete cache[name]; cacheChanged = true; }
      continue;
    }
    const full = sub ? join(root, sub) : root;
    if (!existsSync(full)) {
      // Checkout found, but the declared subPath is not in it — a real config
      // error (bad subPath, or a branch where that directory does not exist).
      unresolved.push(name);
      continue;
    }
    paths.set(name, full);
    meta.set(name, { root, subPath: sub });
    if (cache[name] !== full) { cache[name] = full; cacheChanged = true; }
  }

  return { identity, paths, meta, unresolved, cache, cacheChanged, discovered };
}

/**
 * Seed a repos.json from what is knowable automatically: every graphify/ mirror
 * whose name matches a discovered checkout's folder name or remote name.
 *
 * Everything else comes back in `needsMapping` for the caller to ask about ONCE
 * and then persist forever. Two distinct reasons a mirror lands there, and the
 * prompt must allow for both:
 *
 *   - **sub-path repo** — the mirror is a directory inside a larger checkout.
 *     Nothing on disk says the mirror "KDS" means `android/applications/KDS`
 *     inside the monorepo clone.
 *   - **renamed repo** — the mirror name matches neither the folder nor the
 *     remote. tray-brain's `store-hub` mirror is the repo `vendsy/edge`, cloned
 *     as `edge/`. Guessing here would be worse than asking.
 *
 * `candidates` lists the discovered checkouts that matched nothing, which is
 * almost always where the answer is.
 */
export function seedIdentity(vault, searchRoots = []) {
  const found = discoverCheckouts(searchRoots);
  const byFolder = new Map();
  for (const [remote, dir] of found) byFolder.set(dir.split(/[\\/]/).pop(), { remote, dir });

  const repos = {};
  const needsMapping = [];
  const claimed = new Set();
  for (const name of mirrorNames(vault)) {
    const key = name.toLowerCase();
    const byName = byFolder.get(name);
    const byRemote = byName ? null : [...found.keys()].find((r) => r.split('/').pop() === key);
    if (byName) {
      repos[name] = { remote: byName.remote };
      claimed.add(byName.remote);
    } else if (byRemote) {
      repos[name] = { remote: byRemote };
      claimed.add(byRemote);
    } else {
      needsMapping.push(name);
    }
  }
  const candidates = [...found].filter(([r]) => !claimed.has(r)).map(([remote, dir]) => ({ remote, dir }));
  return { repos, needsMapping, candidates };
}

export function writeIdentity(vault, repos) {
  writeFileSync(join(vault, 'repos.json'), JSON.stringify({ repos }, null, 2) + '\n', 'utf8');
}

export function writeCache(vault, cache) {
  writeFileSync(join(vault, 'repos.local.json'), JSON.stringify(cache, null, 2) + '\n', 'utf8');
}

// ---- CLI -----------------------------------------------------------------
// Used by /brain:init and /brain:doctor. Prints JSON so a skill can read the
// result and prompt for the subPaths detection cannot infer.
if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('resolve-repos.mjs')) {
  const argv = process.argv.slice(2);
  const argVal = (f) => (argv.indexOf(f) >= 0 ? argv[argv.indexOf(f) + 1] : undefined);
  const vault = argVal('--vault') || process.env.BRAIN_ROOT || process.cwd();
  const home = process.env.HOME || process.env.USERPROFILE || '';
  const hint = (argVal('--repos-dir') || process.env.REPOS_DIR || join(vault, '..')).replace(/^~/, home);
  const roots = [isAbsolute(hint) ? hint : resolve(hint), resolve(join(vault, '..'))];
  const write = argv.includes('--write');

  if (argv.includes('--seed')) {
    const { repos, needsMapping, candidates } = seedIdentity(vault, roots);
    if (write && Object.keys(repos).length) writeIdentity(vault, repos);
    console.log(JSON.stringify({ action: 'seed', written: write, repos, needsMapping, candidates }, null, 2));
    process.exit(0);
  }

  const r = resolveRepos(vault, roots);
  if (!r.identity) {
    console.log(JSON.stringify({ error: 'no repos.json in vault — run with --seed first' }, null, 2));
    process.exit(1);
  }
  if (write && r.cacheChanged) writeCache(vault, r.cache);
  console.log(
    JSON.stringify(
      { action: 'resolve', resolved: Object.fromEntries(r.paths), unresolved: r.unresolved, cacheUpdated: write && r.cacheChanged },
      null,
      2
    )
  );
  process.exit(0);
}
