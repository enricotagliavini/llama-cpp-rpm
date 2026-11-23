# llama-cpp

## A word of thanks

This fork exists because of the **[Fedora](https://fedoraproject.org/)** community — thank you for building and maintaining the day-to-day desktop and server OS this package runs on. Without your work, none of this would exist.

## What this is

A personal fork of the Fedora `llama-cpp` RPM package. It packages Facebook's [`llama.cpp`](https://github.com/ggml-org/llama.cpp), the ggml-based inference engine, as RPMs for Fedora, with local modifications layered on top of upstream Fedora.

Two things drive these changes:

1. **CUDA support** — enabling the CUDA GPU backend (`libggml-cuda`) so you can run inference on NVIDIA GPUs.
2. **Modular GPU backends** — instead of bundling every optional backend into one monolithic package, each GPU backend now ships as its own top-level RPM.

For build details see [`llama-cpp.spec`](./llama-cpp.spec). This page focuses on how to keep the fork in sync with upstream.

## Split packages for each ggml backend

| Package | Backend | Library |
| --- | --- | --- |
| `llama-cpp` | CPU only | base library + CLI tools |
| `llama-cpp-hip` | ROCm (AMD) | `libggml-hip` |
| `llama-cpp-vulkan` | Vulkan | `libggml-vulkan` |
| `llama-cpp-cuda` | CUDA (NVIDIA) | `libggml-cuda` |

The base `llama-cpp` package installs the CPU-only artifacts; each backend package depends on it and pulls in only the library and build/runtime dependencies it needs. Turn a backend on or off at build time with the spec's `%bcond_with` / `%if %{with}` options (`rocm`, `vulkan`, `cuda`).

## Change carry-over workflow

Upstream Fedora keeps moving, so our patches eventually drift out of date. To stay in sync without hand-resolving merge conflicts, we use a **layered repo**:

- `fedora-src/` is a **pristine** copy of the Fedora source, pinned as a git submodule. Never edit its files directly — bumping the version means advancing this pointer, which you do through `sync.sh`.
- `patches/` holds **our** changes as patch files. This is the single source of truth for "what we changed."
- The working tree you see is those two things combined: `fedora-src/` + `patches/` applied on top.

### Happy path — syncing with upstream

To fetch the latest Fedora and re-apply our patches:

```bash
./tools/sync.sh
```

In a clean state this runs automatically end to end:

1. Fetches the Fedora source `rawhide` branch and moves the submodule pointer to the new tip.
2. Re-materializes the working tree from Fedora's tracked files.
3. Re-applies every patch in `patches/`.
4. Commits the delta (submodule pointer + regenerated patches) and prints a reminder to push — pushing is **not** automatic.

When nothing upstream touched any file our patches rely on, that's the whole story.

### When `sync.sh` fails

If one of our patches no longer applies after an upstream change, `sync.sh` stops immediately **without committing**, so the submodule advance is discarded. It writes a structured failure report to `tools/.sync-failure.json`, which tells you exactly which patch failed on which hunk, what the new upstream context looks like around it, and how to fix it. Then regenerate just that patch against the updated upstream:

```bash
./tools/regen-patch.sh patches/0001-example.diff
```

This rebuilds the pre-patch baseline from current Fedora plus your surviving patches, diffs it against your edited working tree, and rewrites only the stale patch — leaving everything else untouched. Adjust the generated patch to match what you actually intended, then re-run `sync.sh`. Only the failing patch changes; surviving patches are never touched, so other drift stays isolated and reviewable.

### Creating a patch that didn't exist before

Some changes have no upstream equivalent — CUDA tooling, splitting a backend, etc. For those, edit the working tree as usual, then generate the patch so it stays isolated:

```bash
./tools/regen-patch.sh patches/0001-example.diff --to /tmp/p   # inspect the output in /tmp/p first
mv /tmp/p/0001-example.diff patches/                            # move it into place once satisfied
```

`regen-patch.sh` diffs current Fedora + your surviving patches against your edited working tree and writes one patch per file that differs. It numbers patches stably (e.g. `0001-llama-cpp.spec.diff`) across runs and never clobbers your in-progress edits. Commit the new patch together with any bumped submodule pointer in one go — and remember that `fedpkg build` refuses to run unless the tree is clean and everything is pushed, so commit **and** push after `sync.sh`.
