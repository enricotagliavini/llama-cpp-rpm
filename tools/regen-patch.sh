#!/usr/bin/env bash
#
# regen-patch.sh -- regenerate a stale patch from the patched working tree.
#
# Use it after `tools/sync.sh` fails on a patch. Full loop:
#
#   1. ./tools/sync.sh                 # fails fast, emits a structured report
#   2. edit the working tree to the new intent. At this point fedora-src is
#      already at the new commit and the stale patch was NOT applied, so your
#      edits sit on top of pristine fedora-src + the surviving (earlier) patches.
#   3. ./tools/regen-patch.sh patches/0001-llama-cpp.spec.diff
#      -> writes a fresh patch (or one patch per differing file) capturing
#         "pristine upstream -> your edits". Files already in the pre-patch
#         baseline that match the working tree are skipped, so in the common
#         single-file case this rewrites just that one patch.
#   4. ./tools/sync.sh                 # verifies the regenerated patch(es) apply
#
# The pre-patch baseline is reconstructed in a temporary directory from pristine
# fedora-src + the patches that sort *before* the target, so earlier changes are
# accounted for and your in-progress edits are never clobbered. The baseline is
# deliberately NOT `HEAD` (HEAD still carries the old, now-replaced patch),
# which would double-apply the stale hunk.
#
# This script is read-only with respect to the real tree: on success it only
# writes the new patch file (default: overwriting the stale patch, which is
# still recoverable from git history); if the current patch does not parse it
# errors out WITHOUT truncating it.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

UPSTREAM_PATH="fedora-src"
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
  --to      directory to write the regenerated patch(es) here instead of
            overwriting the patch(es) in patches/ (default: patches/)
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

# Absolute form of a path given relative to the repo root. Needed wherever we
# hand a path to `git -C <dir>`: that resolves the argument against <dir>, not
# the process cwd, so a relative path would point at the wrong location.
absolutize() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$ROOT_DIR" "$1" ;; esac; }

# Echo the numeric prefix of the existing patch file named <num>-<file>.diff in
# patches/ (e.g. 0001-llama-cpp.spec.diff -> 1), or return non-zero if that file
# has no patch yet. The naming convention is <4-digit-number>-<tracked-file>.diff.
patch_num_for_file() {
  local f="$1" p num stem
  for p in "$PATCH_DIR"/*; do
    [ -e "$p" ] || continue
    p="$(basename "$p")"
    case "$p" in [0-9]*-*.diff) : ;; *) continue ;; esac
    num="${p%%-*}"
    stem="${p#*-}"; stem="${stem%.diff}"
    [ "$stem" = "$f" ] && { printf '%s' "$num"; return 0; }
  done
  return 1
}

# Files to diff for the regenerated patch: everything tracked in the pristine
# submodule. Those are exactly the files carried over as patches. Files tracked
# only in the root repo (tools/, patches/, docs) are not in this list — they are
# committed directly to the fork and need no patch. Deriving the list from
# submodule state (not from the stale patch) lets a patch freely gain or lose
# files on regen, with no chicken-and-egg. Captured once, up front.
TARGET_FILES="$(git -C "$UPSTREAM_PATH" ls-files)"

# --- reconstruct the pre-patch baseline in a temp dir ------------------------
BASELINE="$(mktemp -d)"
CHECK=""
cleanup() { rm -rf "$BASELINE" "$CHECK"; }
trap cleanup EXIT

# Materialize pristine fedora-src into the baseline directory.
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
# Validate that every file to be diffed exists in both the pre-patch baseline
# and the working tree before we truncate $OUT below, so a broken state fails
# clearly (and without clobbering the user's existing patch) instead of
# producing a corrupt one.
if [ -z "$TARGET_FILES" ]; then
  echo "regen-patch.sh: no tracked files in $UPSTREAM_PATH — nothing to diff." >&2
  exit 1
fi
for f in $TARGET_FILES; do
  if [ ! -f "$BASELINE/$f" ]; then
    echo "regen-patch.sh: '$f' is not in the pre-patch baseline — is it still tracked in $UPSTREAM_PATH?" >&2
    exit 1
  fi
  if [ ! -f "$ROOT_DIR/$f" ]; then
    echo "regen-patch.sh: working tree has no $f — did you edit it before running this?" >&2
    exit 1
  fi
done

# --- emit one patch per differing file ---------------------------------------
# Choose where regenerated patches land: default is patches/ (each file rewrites
# its own existing patch in place); --to <dir> stages them in <dir> so you can
# inspect a regen without touching the real patch set.
#
# Numbering: reuse an existing patch's numeric prefix for a file that already
# has one, otherwise append after the highest existing number. This keeps patch
# numbers stable across regens, is independent of which patch you targeted, and
# never orphans a patch.
if [ -n "$TO" ]; then
  OUT_DIR="$TO"
else
  OUT_DIR="$PATCH_DIR"
fi
mkdir -p "$OUT_DIR"

max_num=0
for p in "$PATCH_DIR"/*; do
  [ -e "$p" ] || continue
  p="$(basename "$p")"
  case "$p" in [0-9]*-*.diff) : ;; *) continue ;; esac
  num="${p%%-*}"
  if [ "$((10#$num))" -gt "$max_num" ] 2>/dev/null; then max_num="$((10#$num))"; fi
done
next_num=$((max_num + 1))

generated=()
any_change=0
for f in $TARGET_FILES; do
  [ -z "$f" ] && continue
  diff_file="$(mktemp)"
  rc=0
  # rc=1 => differs (want a patch); rc=0 => identical (skip); rc>1 => error.
  diff -u -L "a/$f" -L "b/$f" "$BASELINE/$f" "$ROOT_DIR/$f" > "$diff_file" 2>/dev/null || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "regen-patch.sh: diff error on $f (rc=$rc)" >&2
    rm -f "$diff_file"
    exit 1
  fi
  if [ "$rc" -ne 1 ]; then rm -f "$diff_file"; continue; fi

  num="$(patch_num_for_file "$f")" || true
  if [ -z "$num" ]; then
    num="$(printf '%04d' "$next_num")"
    next_num=$((next_num + 1))
  else
    num="$(printf '%04d' "$((10#$num))")"
  fi
  out="$OUT_DIR/$num-$f.diff"
  mv "$diff_file" "$out"
  generated+=("$out")
  any_change=1
done

if [ "$any_change" -eq 0 ]; then
  echo "regen-patch.sh: WARNING — no differing files: your edited working tree matches the pre-patch baseline (nothing to regenerate)." >&2
  exit 0
fi

echo "regen-patch.sh: wrote ${#generated[@]} patch(es):"
for g in "${generated[@]}"; do echo "  $g"; done

# --- verify: apply every generated patch to a copy of the pre-patch baseline
#     and confirm the whole tree reproduces your edited working tree. This is
#     the net-edit check generalized to one-patch-per-file. --------------------
CHECK="$(mktemp -d)"
cp -a "$BASELINE/." "$CHECK/"
for g in "${generated[@]}"; do
  if ! git -C "$CHECK" apply "$(absolutize "$g")"; then
    echo "regen-patch.sh: FAILED — $(basename "$g") does not apply to the pre-patch baseline:" >&2
    git -C "$CHECK" apply "$(absolutize "$g")" 2>&1 | sed 's/^/    /' >&2
    exit 1
  fi
done
bad=0
for f in $TARGET_FILES; do
  cmp -s "$CHECK/$f" "$ROOT_DIR/$f" || { bad=1; echo "regen-patch.sh: mismatch after applying generated patch to $f" >&2; }
done
if [ "$bad" -ne 0 ]; then
  exit 1
fi

echo "regen-patch.sh: verified — the generated patch reproduces your edited working tree."
exit 0
