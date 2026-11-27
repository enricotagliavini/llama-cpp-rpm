# Carry-over workflow: pull Fedora updates → sync our changes over

Full repository context (layout, build backends, modularity plan, `fedpkg`/git
interaction, cheap vs. full build testing) lives in **`AGENTS.md`** — read that
first. This skill is the concise, command-by-command walkthrough of the single
recurring task: **pull upstream Fedora changes and carry our local patches
forward.**

It exists so an AI agent gets focused steps (with expected outputs, including
what to do when a patch stops applying) without reading the whole AGENTS.md.

---

## Mental model (one line)

The working tree = pristine `fedora-src/` files **+** `patches/*.diff`. Pulling
upstream means advancing the `fedora-src` submodule pointer; our edits must be
captured as patches, never committed out-of-band into the derived tree.

## Command reference

| Goal | Command |
| --- | --- |
| Sync (auto message) | `./tools/sync.sh` |
| Sync (custom msg) | `./tools/sync.sh "…"` |
| Regen one stale patch (in place) | `./tools/regen-patch.sh patches/0003-something.diff` |
| Regen one stale patch (inspect first) | `./tools/regen-patch.sh patches/0003-something.diff --to /tmp/p` |
| Refresh all existing patches | `./tools/regen-patch.sh` |
| Read failure report | `cat tools/.sync-failure.json` (git-ignored) |
| Submodule health | `git submodule status` → ` ` ok, `-` uncloned, `+` drifted, `U` conflict |
| Build from local/uncommitted | `fedpkg srpm` (cheap, no compile, ignores repo state) |

See `AGENTS.md` for *why* these scripts behave as they do.

## The happy-path loop

```bash
./tools/sync.sh          # or: ./tools/sync.sh "explicit commit message"
```

What happens (each phase self-documents via its own header comment):

1. Ensure `fedora-src` is ready (`git submodule status`); clone it if missing.
2. Fetch `rawhide`, advance the submodule pointer to its tip.
3. Re-materialize the root from pristine `fedora-src/`, then re-apply `patches/`.
4. Commit the delta (submodule pointer + root files), then remind you to push.

Expected outputs:

- **Success:** `[sync] committed <sha>` (+ a `git show --stat`) → run
  `git push origin main`. No changes → `[sync] … nothing to commit`.
- **Failure:** see **§Stale-patch recovery** below — it stops *before*
  committing, so nothing destructive happened.

## A patch does NOT apply cleanly — recovery ⚠️

When upstream moved something our patch no longer matches, `sync.sh` aborts and
commits nothing. Recover in four steps:

```bash
# A. Read the report + peek at the file region the old hunk expected
cat tools/.sync-failure.json                 # names the patch, target file, new Fedora commit, + inline file contents
sed -n '115,135p' llama-cpp.spec             # look at where the old hunk sat

# B. Edit the working-tree file to the new intent. Do NOT re-run sync.sh yet —
#    an out-of-band edit would be wiped by materialize_root on the next run.

# C. Regenerate the patch; it self-verifies against your edits
./tools/regen-patch.sh patches/0003-something.diff   # overwrites in place
#    ...or inspect first with --to /tmp/p before committing

# D. Resync
./tools/sync.sh
```

If it fails again, back to A and iterate — the loop is meant to be repeated.

Details on what the report contains, regen's internal logic, patch numbering,
and guard behaviors are in `AGENTS.md` (`### Stale-patch regeneration`).

## Quick gotchas

- Never hand-edit `fedora-src/` tracked files; never bump the version by moving
  the pointer by hand — go through `./tools/sync.sh`.
- Keep patches small, version-guarded, free of hard line numbers (see AGENTS.md).
- Drop stray helper files (`.spec.bak`, temp patches) before `fedpkg build`;
  use `fedpkg srpm` for local/uncommitted builds.
- Prefer cheap checks (`fedpkg srpm`, BuildRequires resolution) over full builds
  unless testing `%cmake`/`%files` gating — see AGENTS.md.

## Golden rules

Do: run `./tools/sync.sh`; treat `patches/` as the single source of truth; after
a stale failure do read-report → edit → regen → resync; push only to `origin`.
Don't: hand-edit the pristine submodule or move its pointer; re-run `sync.sh`
right after a stale failure before regenerating; use `git add -A`; attempt a
full build on your own initiative.
