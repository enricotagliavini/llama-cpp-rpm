#!/usr/bin/env bash
#
# sync.sh -- carry-over sync loop for the llama-cpp RPM fork (layered repo).
#
# Keeps the root dist-git tree in sync with the pristine `fedora-src/` submodule
# while carrying our own changes (recorded as patches/) over with minimal
# friction.
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

# ---- config -----------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

UPSTREAM_PATH="fedora-src"
UPSTREAM_BRANCH="rawhide"
UPSTREAM_REMOTE="https://src.fedoraproject.org/rpms/llama-cpp.git"
PATCH_DIR="patches"
REPORT_FILE="tools/.sync-failure.json"

# Explicit list of the dist-git files materialized from upstream and committed.
# materialize() itself uses `git ls-files`, so it always reflects whatever
# upstream tracks; this list is only used for the commit stage so stray files
# are never included by accident.
DISTGIT_FILES=(
  ".fmf/version" ".gitignore" "README.md" "llama-cpp.spec"
  "plans/full.fmf" "sources"
)

LOG()  { printf '[sync] %s\n' "$*"; }

# Minimal JSON string escaping (backslash, quote, tab, newline -> space).
errjson() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr '\n' ' '
}

# ---- preconditions ----------------------------------------------------------
if [ ! -d "$UPSTREAM_PATH" ]; then
  echo "FATAL: $UPSTREAM_PATH submodule is not present" >&2; exit 2
fi
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "FATAL: $ROOT_DIR is not a git work tree" >&2; exit 2
fi

# ---- 1. fetch + advance the submodule to the latest rawhide -----------------
OLD_POINTER="$(git -C "$UPSTREAM_PATH" rev-parse HEAD 2>/dev/null || echo none)"
LOG "fetching $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git -C "$UPSTREAM_PATH" fetch --quiet "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"

# Make sure the submodule worktree sits on rawhide at the freshly fetched tip.
if git -C "$UPSTREAM_PATH" rev-parse --verify --quiet "$UPSTREAM_BRANCH" >/dev/null; then
  git -C "$UPSTREAM_PATH" switch --quiet "$UPSTREAM_BRANCH"
else
  git -C "$UPSTREAM_PATH" switch --quiet -c "$UPSTREAM_BRANCH"
fi
git -C "$UPSTREAM_PATH" reset --hard --quiet FETCH_HEAD

NEW_POINTER="$(git -C "$UPSTREAM_PATH" rev-parse HEAD)"
if [ "$OLD_POINTER" != "$NEW_POINTER" ]; then
  LOG "fedora-src/$UPSTREAM_BRANCH advanced: $OLD_POINTER -> $NEW_POINTER"
  git add "$UPSTREAM_PATH"
else
  LOG "fedora-src/$UPSTREAM_BRANCH unchanged: $NEW_POINTER"
fi

# ---- 2. materialize the root from upstream tracked files --------------------
# Copy every file upstream tracks into the root. ls-files never lists .git, so
# the submodule gitfile is left untouched (a plain cp -a would clobber it).
LOG "materializing root from upstream tracked files"
while IFS= read -r f; do
  mkdir -p "$(dirname "$f")"
  cp -f "$UPSTREAM_PATH/$f" "$f"
done < <(git -C "$UPSTREAM_PATH" ls-files)

# ---- 3. re-apply patches/ in sorted order -----------------------------------
# apply_one returns 0 when the patch applies cleanly or is already applied, 1
# when it is stale (its context no longer matches the materialized tree).
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

# report_stale emits a structured (JSON + human) failure report and exits.
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

# ---- 4. stage the delta and commit (or report up-to-date) -------------------
git add "${DISTGIT_FILES[@]}" "patches" "$UPSTREAM_PATH"

if git diff --cached --quiet; then
  LOG "no changes: root already in sync with upstream $NEW_POINTER"
  LOG "our patch(es) in $PATCH_DIR/ apply cleanly; nothing to commit."
  exit 0
fi

MSG="${1:-sync: carry over upstream $UPSTREAM_BRANCH ($NEW_POINTER)}"
git commit --quiet -m "$MSG"
echo "[sync] committed $(git rev-parse --short HEAD)"
git show --stat --format=oneline HEAD | sed -n '1,20p'
echo
echo "[sync] reminder: this branch has no remote; push when ready, e.g.:"
echo "          git push origin main"
exit 0
