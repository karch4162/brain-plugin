# Project rules for wave workers — brain-plugin

Appended verbatim to every worker prompt. Keep it current: a stale line here is
worse than no line, because it tells a worker to ignore something real.

## The test gate: CI is the full gate, NOT your local machine

**Do not run the whole suite locally as your gate.** Measured 2026-09-24 on
Windows/Git Bash: process spawn costs ~1.3 s, `test-session.sh` alone took about
an hour, and a full pass of the 27 suites runs for hours. The same set takes
~38 s on an ubuntu runner. The suites fork `git` constantly, so this is a
process-spawn tax, not slow tests — and it gets worse as suites are added.

It also hits the Bash tool's 10-minute cap, which reads as a hang rather than a
gate, and that is how a wave ends up running all night with nothing to show.

**What to do instead:**

1. Run only the suite(s) covering the files you changed. The mapping is by name:
   `brain/bin/session.sh` → `tests/test-session.sh`, `brain/bin/write-hot.sh` →
   `tests/test-write-hot.sh`, `brain/bin/scope-audit.mjs` →
   `tests/test-scope-audit.sh`, and so on. If you touched a skill's `SKILL.md`,
   the doctor/save behaviour suites are usually the relevant ones.
2. Add `tests/test-bash32-portability.sh` whenever you touch any `.sh` — it is a
   fast static gate over the whole `brain/**.sh` tree.
3. Push the branch and let CI run all 27 on both runners. CI is the authority on
   "the full suite is green", not a local run.

**Actions ARE running.** The repo is public and GitHub Actions has been live
since 2026-09-25; `main` is green on both runners. They were billing-blocked
before that, and every job died at `steps=0` — that era is over. If your PR
shows no checks yet, they are queued or still running: the Windows job alone
takes 9-11 minutes. Wait for them. Do not conclude "checks will not start" and
fall back to local-only evidence, and do not write that into a ticket or a
summary — a red or missing check is now real signal about your branch.

**Never run the suites in parallel.** They contend and invent failures that do
not reproduce serially.

The slowest by a wide margin are `test-session.sh`, `test-sync-graph.sh` and
`test-vault-commit.sh`. If your diff does not touch those areas, do not run them
locally at all.

## Writing tests here

- **bash 3.2 only.** No `mapfile`, no `declare -A`, no `readarray` — macOS ships
  bash 3.2 and `tests/test-bash32-portability.sh` gates the whole class.
- **Add a CRLF fixture variant** for anything that parses vault files. The vault
  is `autocrlf`, so LF-only fixtures produce false greens.
- **Every fix ships with a negative control** — a case that fails if the logic
  is removed. A suite that cannot fail is the defect this repo keeps re-finding.

## Version bumps

Every behaviour change declares a bump, but **never edit a `version` field on a
feature branch** — parallel branches collide on that line (INNOV-311). Instead
add one fragment named after your ticket: `printf 'patch\n' > .bumps/brain/INNOV-123`
(or `minor`/`major`; `.bumps/wave/...` for the wave plugin). Distinct filenames
never conflict, and `tools/check-version-bump.sh` accepts the fragment. The human
applies all fragments at release with `node tools/bump-version.mjs brain`.

## Do not touch the real vault

Workers must not run `/brain:*` commands, `session.sh`, or anything that writes
to `$BRAIN_ROOT`. The vault is shared live state with its own commit guard;
a worker writing to it corrupts a sibling's session. Test against fixtures.
