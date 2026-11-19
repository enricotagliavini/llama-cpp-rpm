# AGENTS.md — llama-cpp RPM fork

This file documents this repository so contributors (including future sessions of
the assistant) understand what it is, how it is laid out, and the goals guiding
the work. It is a living document — update it as the modularity and CUDA work
progresses.

## What this repository is

A **personal fork of the Fedora `llama-cpp` RPM package** (a Fedora dist-git
repository). It packages Facebook's `llama.cpp` (the ggml-based C/C++ inference
engine) as RPMs for Fedora, with a few local modifications on top of upstream.

- **Upstream (pristine, pinned):** Fedora dist-git `llama-cpp` at
  `https://src.fedoraproject.org/rpms/llama-cpp`, checked out as a **git
  submodule** at `upstream/`. It is pristine — we never edit its files
  directly; we only move the submodule pointer to a new commit. (The git
  remote `upstream` is fetch-only.)
- **Our changes:** stored as patch files in `patches/`; the **root working
  tree** = `upstream/` + `patches/` applied, and that is what is committed.
- **Personal / home repo:** GitHub `enricotagliavini/llama-cpp-rpm` (git remote
  `origin`).
- **Current upstream version carried:** `b11232` (see `Version:` in the spec;
  `Release:` uses `%autorelease`).

## North-star objective

Carry **upstream changes over as easily as possible** while adding the local
work. Two concrete local goals:

1. **Modularity** — package the optional GPU backend libraries (`libggml-hip`,
   `libggml-vulkan`, `libggml-cuda`) as **separate top-level RPM packages**
   instead of bundling all backends into a single `llama-cpp` package.
2. **CUDA support** — add the CUDA GPU backend. (Partially present today; still
   being made modular.)

Upstream changes should be pulled in and our local changes re-applied without
friction — our diffs should stay isolated and reviewable against current
upstream.

## Repository layout (fmf dist-git, `.fmf/version = 1`)

- `upstream/` — the **pristine upstream git submodule** (pinned to a commit,
  currently `b11232`'s dist-git). We never edit its files directly. Moving this
  submodule pointer is how we "carry over" a new upstream version.
- `patches/` — our own patch files. **The canonical, reproducible record of
  "our changes";** the root working tree is derived from `upstream/` +
  `patches/`.
- `llama-cpp.spec` — the package spec. Currently a **single package** that
  bundles the CPU code plus all optional backends, gated with `%if` /
  `%bcond_with`. This is the starting point for the modularity refactor.
- `sources` — a file holding the **SHA512 checksum** of the upstream source
  tarball (`llama.cpp-b11232.tar.gz`). The spec's `Source0` fetches the tarball
  from upstream at build time; this file records the expected digest.
- `.fmf/` — fmf (Fedora Metadata) files: currently just `version`.
- `plans/` — tmt plans (e.g. `plans/full.fmf`, which runs the upstream test
  suite). The **build/test automation** is separate from the **change-carry-over
  workflow** described below.
- `README.md` — short package description.

## Remotes (push/fetch rules)

- `upstream` — **fetch only** (no push). Fedora source of truth. Its contents
  live in this repo as the `upstream/` submodule (see "Repository layout").
- `origin` — **push to this repo** (your home repo). This is where commits land.
- Working branch: `rawhide` (tracks `upstream/rawhide`).
- **The submodule pointer is a commit.** Bumping upstream means `git submodule
  update --remote upstream` (or pinning a known commit); commit that pointer
  change together with any regenerated patches — do not leave it uncommitted
  (fedpkg's dirty-check would fail; see "fedpkg / git interaction").

## Build backends (current, single-package state)

All backends are folded into one package, switched on/off via spec macros:

- **ROCm / HIP** — `%bcond_with rocm`, enabled only on non-x86_64 (AMD GPUs);
  sets `GGML_HIP`, a restricted `rocm_gpu_list` (excludes `gfx1250`).
- **Vulkan** — `%bcond_with vulkan`; sets `GGML_VULKAN`.
- **CUDA** — `GGML_CUDA=ON`, `cuda-toolkit` BuildRequires,
  `CMAKE_CUDA_COMPILER=/usr/local/cuda-13.5/bin/nvcc`.

These `%if` gates and the `%files` backend sections are the reference points for
the modularity refactor.

## Modularity plan (decision: separate top-level packages)

Target architecture — each backend becomes its own top-level RPM. The base
package installs the CPU-only artifacts; backend packages depend on the base.

| Package | Contents |
| --- | --- |
| `llama-cpp` | Base: CPU library (`libggml`/`libggml-base`/`libggml-cpu`), `libllama*`, CLI tools. |
| `llama-cpp-hip` | ROCm/HIP backend (`libggml-hip`) + its BuildRequires + runtime deps. |
| `llama-cpp-vulkan` | Vulkan backend (`libggml-vulkan`) + deps. |
| `llama-cpp-cuda` | CUDA backend (`libggml-cuda`) + deps. |

Each backend package requires the base package so its library is usable.

## Change-carry-over workflow (chosen: patch-based / layered repo)

Goal: keep this repo in sync with upstream and carry our own changes over with
minimal friction — pull upstream changes, then re-apply or carry over our own
changes as easily as possible, with our diffs isolated and reviewable against
current upstream.

**Model (layered repo):**

- `upstream/` is a **pristine git submodule** (Fedora dist-git pinned to a
  commit) — never edited directly.
- `patches/` holds our patch files — the **canonical, reproducible record of
  "our changes."**
- The **root working tree = `upstream/` + `patches/` applied**, and *that is
  what we commit.* `patches/` is the source of truth; the committed tree is
  derived from it. The upstream version is tracked by the **submodule
  pointer**, not by repo commits (so our history stays isolated and reviewable
  — `git diff upstream/rawhide`).

**Why:** patch-based converts stale-patch recovery into "regenerate a diff"
rather than resolving a conflict, which keeps the loop automatable and easy for
an AI agent to adjust.

**Carry-over = bump the submodule pointer (one-liner):**
`git submodule update --remote upstream` (or pin a known commit) → re-apply
`patches/` → commit the delta (pointer + regenerated patches) → `git push
origin`.

**Automation (as far as possible):**

- A repeatable **sync loop** (happy path, no upstream conflict) is fully
  automated: `fetch upstream → point submodule at new commit → apply patches →
  commit the delta → push`.
- When a patch goes stale, the loop **fails fast** and emits a **structured
  failure report** so an AI coding agent can regenerate just that patch: which
  patch, which hunk, the new upstream context around the failed hunk, and our
  intent (the original patch).
- **Patch hygiene** to minimize staleness: keep patches small and focused,
  version-guarded, and free of hard line-number dependencies.

**Honest boundary:** the fetch/apply/verify/report loop is fully automated.
The one thing we cannot fully automate is the semantic judgment of *what a
stale patch should say* when upstream genuinely changed something — but the
structured report makes that edit as trivial as possible for an AI agent.

**Not chosen (for reference):** a golden-pair / diff-on-demand variant exists,
where "our changes" are always `git diff upstream.golden ours.golden` (never
stale, but requires keeping `upstream.golden` updated and is less standard).
Patch-based was chosen for isolation, reviewability, and dist-git convention.

### fedpkg / git interaction (build tooling)

`fedpkg` (fedora's `rpkg` wrapper) interacts with git in ways that shape how we
commit. Verified against `rpkg` 1.70 / `fedpkg` 1.48:

- **`fedpkg build`** (submits a build): runs
  `check_repo(is_dirty=True, all_pushed=True)`. It **refuses** to run unless
  (a) the tree is clean — *including untracked files* (`git status
  --porcelain` shows nothing) — and (b) there are no unpushed commits. The
  failure is `… has uncommitted changes. Use git status to see details` /
  `There are unpushed changes in your repo`, and it suggests `--srpm` for
  local changes. **Critically, it never builds from the working tree** — it
  builds from the commit hash appended to `anongiturl`
  (`{anongiturl}#{commit_hash}`), which Koji clones. So a clean + **pushed**
  commit is mandatory.
- **`fedpkg srpm`** (local SRPM): runs `rpmbuild -bs` on the local spec +
  `sources/` and does **not** check the repo. This is the command to build from
  local / uncommitted changes.
- **`fedpkg test` / tmt** (`plans/full.fmf`, via `dist-git-source: true`): a
  separate build/test path that operates on the checked-out tree; it does not
  run fedpkg's dirty/push checks.

**Consequence for our model:** committing the working tree is harmless and,
for `fedpkg build`, required. When you bump the submodule and regenerate
patches, commit them *together* with the new submodule pointer. Keep stray
helper files out of the committed tree (commit, ignore, or delete them) —
untracked files make `fedpkg build` fail.

### Work-tree helpers

Helper spec copies (`llama-cpp.spec.bak`, `llama-cpp.spec.orig`,
`llama-cpp.spec.withcuda`) and untracked files (e.g. `cuda.patch`) exist for
transient work. They are **not** part of the patch set: keep them out of the
committed tree (commit, ignore, or delete) so `fedpkg build`'s dirty-check
passes and they don't muddy the canonical `patches/`.

## Conventions

- Keep our local changes **isolated and reviewable** against current upstream
  (`git diff upstream/rawhide`).
- Do not push to `upstream`; push only to `origin`.
- Bumping the upstream version means updating `Version:` and the digest in
  `sources` (and re-fetching the tarball at build time).
- See `AGENTS.md` here first for repo context; the spec itself for build details.
