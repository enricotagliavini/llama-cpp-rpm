#!/usr/bin/env bash
#
# regen-patch.sh -- regenerate a stale patch from the patched working tree.
#
# Use it after `tools/sync.sh` fails on a patch. Full loop:
#
#   1. ./tools/sync.sh                 # fails fast, emits a structured report
#   2. edit the working tree to the new intent. At this point upstream is
#      already at the new commit and the stale patch was NOT applied, so your
#      edits sit on top of pristine upstream + the surviving (earlier) patches.
#   3. ./tools/regen-patch.sh patches/0001-llama-cpp.spec.diff
#      -> writes a fresh patch capturing "pristine upstream -> your edits".
#   4. ./tools/sync.sh                 # verifies the new patch applies cleanly
#
# The pre-patch baseline is reconstructed in a temporary directory from pristine
# upstream + the patches that sort *before* the target, so earlier changes are
# accounted for and your in-progress edits are never clobbered. The baseline is
# deliberately NOT `HEAD` (HEAD still carries the old, now-replaced patch),
# which would double-apply the stale hunk.
#
# This script is read-only with respect to the real tree: it only writes the new
# patch file (default: overwriting the stale patch, which is still recoverable
# from git history).
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

UPSTREAM_PATH="upstream"
PATCH_DIR="patches"
# Absolute path to patches/. `git -C <dir> apply <patch>` resolves the patch
# file path relative to <dir> (its own cwd), not the process cwd, so we hand it
# an absolute path to find the file itself; its internal a//b/ paths then apply
# correctly against <dir>'s tree.
ABS_PATCH_DIR="$(cd "$PATCH_DIR" && pwd)"

usage() {
  cat >&2 <<USAGE
usage: tools/regen-patch.sh <patch> [--to <output-path>]
  <patch>   path to the stale patch under patches/ to regenerate
  --to      write the regenerated patch here instead of overwriting <patch>
            (default: overwrite the same path)
The working tree is assumed to already hold your edited intent (set up after
tools/sync.sh failed). This script does not fetch or move the submodule.
USAGE
  exit 2
}

PATCH=""
TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) [ $# -ge 2 ] || { echo "regen-patch.sh: --to needs a path" >&2; exit 2; }; TO="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage ;;
    -*) echo "regen-patch.sh: unknown option $1" >&2; usage ;;
    *) [ -z "$PATCH" ] && PATCH="$1"; shift ;;
  esac
done
[ -n "$PATCH" ] || usage
[ -f "$PATCH" ] || { echo "regen-patch.sh: no such patch: $PATCH" >&2; exit 2; }

# Target files of the patch (a/ b/ "---" headers), in order, de-duplicated.
target_files() { sed -n 's/^--- [ab]\///p' "$1" | awk '!seen[$0]++'; }

# Absolute form of a path given relative to the repo root. Needed wherever we
# hand a path to `git -C <dir>`: that resolves the argument against <dir>, not
# the process cwd, so a relative path would point at the wrong location.
absolutize() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$ROOT_DIR" "$1" ;; esac; }

# Read the target-file list once, up front. It must be captured before anything
# truncates $OUT: in the default (no --to) case $OUT == $PATCH, and the next
# step writes to it, which would destroy this list before we use it.
TARGET_FILES="$(target_files "$PATCH")"

# --- reconstruct the pre-patch baseline in a temp dir ------------------------
BASELINE="$(mktemp -d)"
CHECK=""
cleanup() { rm -rf "$BASELINE" "$CHECK"; }
trap cleanup EXIT

# Materialize pristine upstream into the baseline directory.
while IFS= read -r f; do
  mkdir -p "$BASELINE/$(dirname "$f")"
  cp -f "$UPSTREAM_PATH/$f" "$BASELINE/$f"
done < <(git -C "$UPSTREAM_PATH" ls-files)

# Apply every patch EXCEPT the target, so the baseline matches the state that
# exists immediately before the target patch in sorted order.
BASE_NAME="$(basename "$PATCH")"
while IFS= read -r p; do
  [ -z "$p" ] && continue
  [ "$p" = "$BASE_NAME" ] && continue
  if ! git -C "$BASELINE" apply "$ABS_PATCH_DIR/$p"; then
    echo "regen-patch.sh: patch $p did not apply to the baseline (the committed patch set is itself broken?)" >&2
    exit 1
  fi
done < <(ls -1 "$PATCH_DIR" | sort)

# --- diff baseline vs the edited working tree --------------------------------
OUT="${TO:-$PATCH}"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
any_change=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if [ ! -f "$BASELINE/$f" ]; then
    echo "regen-patch.sh: baseline has no $f — regenerating add/rename patches is not supported yet (edit-only)." >&2
    exit 1
  fi
  if [ ! -f "$ROOT_DIR/$f" ]; then
    echo "regen-patch.sh: working tree has no $f — did you edit it before running this?" >&2
    exit 1
  fi
  rc=0
  diff -u -L "a/$f" -L "b/$f" "$BASELINE/$f" "$ROOT_DIR/$f" >> "$OUT" || rc=$?
  if [ "$rc" -eq 1 ]; then
    any_change=1
  elif [ "$rc" -gt 1 ]; then
    echo "regen-patch.sh: diff error on $f (rc=$rc)" >&2
    exit 1
  fi
done <<< "$TARGET_FILES"

if [ "$any_change" -eq 0 ]; then
  echo "regen-patch.sh: WARNING — $OUT is empty: your edited working tree matches the pre-patch baseline." >&2
  exit 0
fi

echo "regen-patch.sh: wrote $OUT"

# --- verify: apply the generated patch to a copy of the baseline and confirm
#     it reproduces your edited working tree (i.e. the patch really is our net
#     edit relative to the pre-patch state) ------------------------------------
CHECK="$(mktemp -d)"
cp -a "$BASELINE/." "$CHECK/"
if ! git -C "$CHECK" apply "$(absolutize "$OUT")"; then
  echo "regen-patch.sh: FAILED — generated patch does not apply to the pre-patch baseline:" >&2
  git -C "$CHECK" apply "$(absolutize "$OUT")" 2>&1 | sed 's/^/    /' >&2
  exit 1
fi
bad=0
while IFS= read -r f; do
  cmp -s "$CHECK/$f" "$ROOT_DIR/$f" || { bad=1; echo "regen-patch.sh: mismatch after applying generated patch to $f" >&2; }
done <<< "$TARGET_FILES"
if [ "$bad" -ne 0 ]; then
  exit 1
fi
echo "regen-patch.sh: verified — the generated patch reproduces your edited working tree."
exit 0
