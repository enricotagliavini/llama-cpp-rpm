#!/usr/bin/env bash
#
# sync.sh -- carry-over sync loop for the llama-cpp RPM fork (layered repo).
#
# Keeps the root dist-git tree in sync with the pristine `fedora-src/` submodule
# while carrying our own changes (recorded as patches/) over with minimal
# friction.
#
# Overall logic, in four phases: (1) fetch + advance the submodule to the latest
# rawhide commit, (2) re-materialize the root from the pristine upstream tracked
# files, (3) re-apply patches/ in sorted order, failing fast with a structured
# report if any is stale, (4) stage + commit the delta (submodule pointer +
# materialized root files) or report that nothing changed.
#
# Flow:
#   1. Fetch the fedora-src submodule's rawhide branch; point the submodule at
#      the latest rawhide commit.
#   2. Materialize the root tree from the (new) pristine fedora-src tracked files.
#   3. Re-apply patches/ (sorted) on top of the materialized tree.
#   4. If every patch applies, commit the delta (submodule pointer + changed
#      dist-git files) and report success.
#   5. If a patch fails to apply, emit a structured failure report and STOP
#      without committing, so an agent can regenerate just that patch.
#
# Notes:
#   - Never pushes; commits locally and prints a reminder.
#   - Never touches deleteme/ or the fedora-src submodule's own history.
#   - The dist-git root files are committed from an explicit path list, so
#     unrelated / untracked files (deleteme/) are never staged.
#
set -euo pipefail

# ---- static config ----------------------------------------------------------
# Repo root and the paths we operate on. ROOT_DIR is always absolute so the rest
# of the script can use plain relative paths against the checked-out tree.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

UPSTREAM_PATH="fedora-src"                 # pristine dist-git submodule
UPSTREAM_BRANCH="rawhide"                  # branch the submodule tracks
UPSTREAM_REMOTE="https://src.fedoraproject.org/rpms/llama-cpp.git"
PATCH_DIR="patches"                        # our layered patch set
REPORT_FILE="tools/.sync-failure.json"     # structured failure report location

# Explicit list of the dist-git files materialized from upstream and committed.
# materialize_root() itself uses `git ls-files`, so it always reflects whatever
# upstream tracks; this list is only used for the commit stage so stray files
# are never included by accident.
DISTGIT_FILES=(
    ".fmf/version" ".gitignore" "README.md" "llama-cpp.spec"
    "plans/full.fmf" "sources"
)

# NEW_POINTER records where the submodule advanced to. It is consumed by both
# the commit stage and the failure report, so it is a global rather than
# threaded through function arguments.
NEW_POINTER=""

# ---- small helpers ----------------------------------------------------------

# Print a status line, prefixed with [sync], to stdout.
LOG()  { printf '[sync] %s\n' "$*"; }

# Minimal JSON string escaping (backslash, quote, tab -> escapes; newline ->
# space) so free-form text survives inside the failure report.
errjson() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr '\n' ' '
}

# ---- preconditions ----------------------------------------------------------

# Ensure the repo is a git work tree pointing at a known upstream before we
# touch anything. An *absent* submodule is intentionally NOT rejected here:
# check_preconditions no longer requires $UPSTREAM_PATH to exist on disk, so
# ensure_submodule_ready can clone it (it sees '-' from 'git submodule status')
# instead of aborting. A missing '.gitmodules' still fails later, when
# 'git submodule status' errors out.
check_preconditions() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "FATAL: $ROOT_DIR is not a git work tree" >&2; exit 2
    fi
}

# Ensure the pristine upstream submodule is checked out before we fetch/advance
# it or re-materialize its tracked files. An uninitialized submodule (-…fedora-src)
# looks harmless to `git -C fedora-src ...` during fetch, but fails at materialize
# ("cannot change to fedora-src"); worse, without this guard sync.sh advances the
# recorded pointer first and dies mid-loop with no structured failure report. We
# read `git submodule status`, whose first column encodes each submodule's state:
# ' ' up-to-date, '-' not cloned yet, '+' detached/changed, 'U' conflict. For '-'
# we clone it (after telling the user); for '+'/'U' we abort clearly; for ' ' we
# fall through straight to fetching. IFS is set to newline so a literal leading
# space is preserved — plain `read` would eat it and make '-' indistinguishable
# from an empty marker.
ensure_submodule_ready() {
    local line ch
    while IFS=$'\n' read -r line; do
        [ -z "$line" ] && continue
        ch="${line:0:1}"
        case "$ch" in
            ' ') : ;;                                                 # initialized, on commit
            '-') echo "FATAL: $UPSTREAM_PATH is not cloned yet; initializing it now..." >&2
                 git submodule update --init || { echo "FATAL: failed to initialize $UPSTREAM_PATH." >&2; exit 2; }
                 return 0 ;;                                          # only one submodule
            '+') echo "FATAL: $UPSTREAM_PATH is checked out at a different commit than the parent records." >&2; exit 2 ;;
            'U') echo "FATAL: $UPSTREAM_PATH has unresolved merge conflicts; resolve them before syncing." >&2; exit 2 ;;
            *)   echo "FATAL: unexpected \$UPSTREAM_PATH status in 'git submodule status' ($ch)." >&2; exit 2 ;;
        esac
    done < <(git submodule status)
}

# ---- 1. fetch + advance the submodule ---------------------------------------

# Fetch the submodule's upstream branch and make its worktree sit on the freshly
# fetched tip. Updates NEW_POINTER (global) and stages the submodule pointer when
# it actually advanced, so the commit stage picks up the bump.
fetch_and_advance_submodule() {
    local old_ptr new_ptr
    old_ptr="$(git -C "$UPSTREAM_PATH" rev-parse HEAD 2>/dev/null || echo none)"
    LOG "fetching $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
    git -C "$UPSTREAM_PATH" fetch --quiet "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"

    # Make sure the submodule worktree sits on rawhide at the freshly fetched tip:
    # switch to it if it exists locally, otherwise create it from the fetch.
    if git -C "$UPSTREAM_PATH" rev-parse --verify --quiet "$UPSTREAM_BRANCH" >/dev/null; then
        git -C "$UPSTREAM_PATH" switch --quiet "$UPSTREAM_BRANCH"
    else
        git -C "$UPSTREAM_PATH" switch --quiet -c "$UPSTREAM_BRANCH"
    fi
    git -C "$UPSTREAM_PATH" reset --hard --quiet FETCH_HEAD

    new_ptr="$(git -C "$UPSTREAM_PATH" rev-parse HEAD)"
    NEW_POINTER="$new_ptr"
    if [ "$old_ptr" != "$new_ptr" ]; then
        LOG "fedora-src/$UPSTREAM_BRANCH advanced: $old_ptr -> $new_ptr"
        git add "$UPSTREAM_PATH"
    else
        LOG "fedora-src/$UPSTREAM_BRANCH unchanged: $new_ptr"
    fi
}

# ---- 2. materialize the root from pristine upstream -------------------------

# Copy every file upstream tracks into the root. ls-files never lists .git, so
# the submodule's own gitfile is left untouched (a plain cp -a would clobber it).
materialize_root() {
    local f
    LOG "materializing root from upstream tracked files"
    while IFS= read -r f; do
        mkdir -p "$(dirname "$f")"
        cp -f "$UPSTREAM_PATH/$f" "$f"
    done < <(git -C "$UPSTREAM_PATH" ls-files)
}

# ---- 3. re-apply the patches ------------------------------------------------

# Apply a single patch <path>. Returns 0 when it applies cleanly or is already
# applied, 1 when it is stale (its context no longer matches the materialized
# tree). A relative patch path resolves against the repo root, which is our cwd,
# so a plain `git apply` is correct here (no `git -C` needed).
apply_one() {
    local pf="$1"
    if git apply --check "$pf" 2>/dev/null; then
        if git apply "$pf"; then
            echo "applied: $pf"; return 0
        fi
        return 1
    fi
    # Does not apply forward: is it already applied (reverse applies)?
    if git apply --check -R "$pf" 2>/dev/null; then
        echo "already-applied (skip): $pf"; return 0
    fi
    return 1
}

# Emit the structured (JSON + human) failure report and exit(1), so a failing
# sync stops without committing. Uses NEW_POINTER (global) and takes the
# offending patch, its basename, target file, and git apply error as arguments.
report_stale() {
    local pf="$1" base="$2" target="$3" err="$4"
    mkdir -p tools
    local esc; esc="$(errjson "$err")"
    cat > "$REPORT_FILE" <<JSON
{
  "event": "patch_stale",
  "patch": "$pf",
  "target_file": "$target",
  "upstream_commit": "$NEW_POINTER",
  "upstream_ref": "$UPSTREAM_REMOTE@$UPSTREAM_BRANCH",
  "error": "$esc",
  "our_intent": "$pf",
  "action": "Regenerate $base against the new upstream context. 1) Read $target (current state post-bump). 2) Read $pf (the desired changes). 3) Produce a new patch, e.g.: diff -u -L a/$target -L b/$target <new-upstream-file> <our-target-file> > $base. 4) Re-run tools/sync.sh to confirm it applies cleanly."
}
JSON

    echo "=== STRUCTURED FAILURE REPORT: stale patch (no commit made) ===" >&2
    cat "$REPORT_FILE" >&2
    echo >&2
    echo "=== stale patch: $base -> touches $target ===" >&2
    echo "--- git apply error ---" >&2
    printf '%s\n' "$err" | sed 's/^/  /' >&2
    echo "--- current (post-bump) $target ---" >&2
    if [ -f "$target" ]; then sed 's/^/  /' "$target" >&2; else echo "  (absent: $target)" >&2; fi
    echo >&2
    echo "Report written to $REPORT_FILE (git-ignored). Fix the patch, then re-run tools/sync.sh." >&2
    exit 1
}

# Load the sorted patch list into the global PATCHES array, then apply each one,
# failing fast (report_stale) on the first that does not apply cleanly.
apply_patches() {
    local p pf target err
    PATCHES=()
    while IFS= read -r p; do [ -n "$p" ] && PATCHES+=("$p"); done \
        < <(ls -1 "$PATCH_DIR" | sort)

    if [ "${#PATCHES[@]}" -gt 0 ]; then
        LOG "applying ${#PATCHES[@]} patch(es) from $PATCH_DIR/"
    fi
    for p in "${PATCHES[@]}"; do
        pf="$PATCH_DIR/$p"
        if ! apply_one "$pf"; then
            target="$(sed -n 's/^--- a\///p' "$pf" | head -1)"
            err="$(git apply "$pf" 2>&1 >/dev/null || true)"
            report_stale "$pf" "$p" "$target" "$err"
        fi
    done
}

# ---- 4. stage + commit (or report up-to-date) -------------------------------

# Stage the explicit delta (materialized dist-git files + patches + submodule
# pointer) and commit it. If nothing changed, report up-to-date and exit 0. The
# optional first argument overrides the commit message.
stage_and_commit() {
    git add "${DISTGIT_FILES[@]}" "patches" "$UPSTREAM_PATH"

    if git diff --cached --quiet; then
        LOG "no changes: root already in sync with upstream $NEW_POINTER"
        LOG "our patch(es) in $PATCH_DIR/ apply cleanly; nothing to commit."
        exit 0
    fi

    local msg="${1:-sync: carry over upstream $UPSTREAM_BRANCH ($NEW_POINTER)}"
    git commit --quiet -m "$msg"
    echo "[sync] committed $(git rev-parse --short HEAD)"
    git show --stat --format=oneline HEAD | sed -n '1,20p'
    echo
    echo "[sync] reminder: this branch has no remote; push when ready, e.g.:"
    echo "          git push origin main"
}

# ---- main -------------------------------------------------------------------
#
# Flow: check preconditions -> ensure the upstream submodule is ready -> fetch +
# advance the submodule -> re-materialize the root -> apply patches (fail fast
# on stale) -> stage + commit the delta.
main() {
    check_preconditions
    ensure_submodule_ready
    fetch_and_advance_submodule
    materialize_root
    apply_patches
    stage_and_commit "$@"
}

main "$@"
