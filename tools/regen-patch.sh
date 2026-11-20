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
#      -> writes one patch per differing file capturing "pristine upstream ->
#         your edits". Files already in the pre-patch baseline that match the
#         working tree are skipped, so in the common single-file case this
#         rewrites just that one patch.
#   4. ./tools/sync.sh                 # verifies the regenerated patch(es) apply
#
# Overall logic, in three phases: (1) reconstruct the pre-patch baseline,
# (2) diff it against your edited working tree writing one patch per differing
# file, (3) apply every generated patch to a fresh baseline copy and confirm the
# whole tree reproduces your edits.
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

# ---- static config ----------------------------------------------------------
# Repo root and the paths we operate on. ROOT_DIR is always absolute; the other
# paths are resolved relative to it.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

UPSTREAM_PATH="fedora-src"   # pristine dist-git submodule (source of truth)
PATCH_DIR="patches"          # our layered patch set
# Absolute path to patches/. `git -C <dir> apply <patch>` resolves the patch
# file path relative to <dir> (its own cwd), not the process cwd, so we hand it
# an absolute path to find the file itself; its internal a//b/ paths then apply
# correctly against <dir>'s tree.
ABS_PATCH_DIR="$(cd "$PATCH_DIR" && pwd)"

# ---- small helpers ----------------------------------------------------------

# Print usage and exit (2 = command-line misuse).
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

# Print an error to stderr and exit (1 = runtime failure).
die() {
  echo "regen-patch.sh: $*" >&2
  exit 1
}

# Parse arguments into the global PATCH (stale patch path) and TO (optional
# output directory). Errors out on misuse.
parse_args() {
  PATCH=""
  TO=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) [ $# -ge 2 ] || die "--to needs a path"; TO="$2"; shift 2 ;;
      --) shift; break ;;
      -h|--help) usage ;;
      -*) die "unknown option $1" ;;
      *) [ -z "$PATCH" ] && PATCH="$1"; shift ;;
    esac
  done
}

# Resolve a path relative to the repo root into an absolute one. Needed wherever
# we hand a path to `git -C <dir>`: that resolves the argument against <dir>, not
# the process cwd, so a relative path would point at the wrong location.
absolutize() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$ROOT_DIR" "$1" ;;
  esac
}

# ---- patch-numbering --------------------------------------------------------

# Echo the numeric prefix of an existing patch file named <num>-<file>.diff in
# patches/, or return non-zero if that file has no patch yet. The naming
# convention is <number>-<tracked-file>.diff.
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

# Echo the highest numeric prefix currently in patches/ (0 when empty).
find_max_patch_num() {
  local p num max_num=0
  for p in "$PATCH_DIR"/*; do
    [ -e "$p" ] || continue
    p="$(basename "$p")"
    case "$p" in [0-9]*-*.diff) : ;; *) continue ;; esac
    num="${p%%-*}"
    if [ "$((10#$num))" -gt "$max_num" ] 2>/dev/null; then max_num="$((10#$num))"; fi
  done
  printf '%s' "$max_num"
}

# ---- baseline reconstruction ------------------------------------------------

# Materialize pristine fedora-src into <dest>: copy every file the submodule
# tracks. ls-files never lists .git, so the submodule's own gitfile is untouched.
materialize_pristine() {
  local dest="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mkdir -p "$dest/$(dirname "$f")"
    cp -f "$UPSTREAM_PATH/$f" "$dest/$f"
  done < <(git -C "$UPSTREAM_PATH" ls-files)
}

# Apply every patch in PATCH_DIR except <target>, into <dest>, in sorted order.
# The baseline therefore matches the state that exists immediately before the
# target patch — earlier changes are accounted for, and the target's old hunk is
# not re-applied.
apply_patches_except_target() {
  local dest="$1" target="$2" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$p" = "$target" ] && continue
    if ! git -C "$dest" apply "$ABS_PATCH_DIR/$p"; then
      die "patch $p did not apply to the baseline (the committed patch set is itself broken?)"
    fi
  done < <(ls -1 "$PATCH_DIR" | sort)
}

# ---- emit & verify ----------------------------------------------------------

# For <file>, diff <base> against the working tree and, if it differs, write
# <out_dir>/<num>-<file>.diff. Echo the patch path on success and return 0;
# return 1 (no output) when the files are identical; exit non-zero on error.
# Runs in a command substitution (see emit_patches), so it must not rely on any
# state it sets — the patch file it writes is on the real filesystem, so it
# persists, and its path is returned via stdout.
gen_patch_for() {
  local f="$1" out_dir="$2" num="$3" base="$4" diff_file rc=0
  diff_file="$(mktemp)"
  # rc=1 => differs (emit); rc=0 => identical (skip); rc>1 => error.
  diff -u -L "a/$f" -L "b/$f" "$base/$f" "$ROOT_DIR/$f" >"$diff_file" 2>/dev/null || rc=$?
  if [ "$rc" -gt 1 ]; then
    rm -f "$diff_file"; die "diff error on $f (rc=$rc)"
  fi
  if [ "$rc" -ne 1 ]; then
    rm -f "$diff_file"; return 1
  fi
  mkdir -p "$out_dir"
  # Flatten the tracked path into a single filename (e.g. plans/full.fmf ->
  # plans-full.fmf) so the patch stays a flat file in OUT_DIR; the real path is
  # preserved in the patch's a//b/ headers below.
  local flat="${f//\//-}"
  local out="$out_dir/${num}-${flat}.diff"
  mv "$diff_file" "$out"
  printf '%s' "$out"
}

# Iterate every tracked file, assign each its patch number, and emit one patch
# per differing file. Collected patch paths go into the global `generated`
# array, which main reads back. Numbering happens here in the running shell (not
# a subshell) so the increment below persists across iterations.
emit_patches() {
  local out_dir="$1" baseline="$2" f existing num out
  generated=()
  for f in $TARGET_FILES; do
    [ -n "$f" ] || continue
    # Number: reuse an existing patch's prefix for this file, otherwise append
    # after the highest existing number. Only consume a new number once a patch
    # is actually emitted (see below), so skipped files leave no gap in the run.
    existing="$(patch_num_for_file "$f" 2>/dev/null)" || true
    if [ -n "$existing" ]; then
      num="$(printf '%04d' "$((10#$existing))")"
    else
      num="$(printf '%04d' "$next_num")"
    fi
    if out="$(gen_patch_for "$f" "$out_dir" "$num" "$baseline")"; then
      generated+=("$out")
      [ -z "$existing" ] && next_num=$((next_num + 1))
    fi
  done
}

# Apply every generated patch to a fresh copy of the baseline and confirm the
# whole tree reproduces the edited working tree. Return 0 on a match.
verify_against_working_tree() {
  local check="$1" g f bad=0
  cp -a "$BASELINE/." "$check/"
  for g in "${generated[@]}"; do
    if ! git -C "$check" apply "$(absolutize "$g")"; then
      echo "regen-patch.sh: FAILED — $(basename "$g") does not apply to the pre-patch baseline:" >&2
      git -C "$check" apply "$(absolutize "$g")" 2>&1 | sed 's/^/    /' >&2
      return 1
    fi
  done
  for f in $TARGET_FILES; do
    [ -n "$f" ] || continue
    if ! cmp -s "$check/$f" "$ROOT_DIR/$f"; then
      echo "regen-patch.sh: mismatch after applying generated patch to $f" >&2
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

# ---- main -------------------------------------------------------------------
#
# Flow: reconstruct the pre-patch baseline -> validate the target files -> emit
# one patch per differing file -> self-verify that the patches reproduce the
# edited working tree.
main() {
  parse_args "$@"
  [ -n "$PATCH" ] || usage
  [ -f "$PATCH" ] || die "no such patch: $PATCH"

  # Files carried over as patches = everything tracked in the pristine submodule.
  # Deriving this from the submodule (not the patch headers) lets a patch freely
  # gain or lose files on regen.
  TARGET_FILES="$(git -C "$UPSTREAM_PATH" ls-files)"
  [ -n "$TARGET_FILES" ] || die "no tracked files in $UPSTREAM_PATH — nothing to diff."

  # Where regenerated patches land: default is patches/ (each file rewrites its
  # own existing patch in place); --to <dir> stages them elsewhere for inspection.
  OUT_DIR="$PATCH_DIR"
  [ -n "$TO" ] && OUT_DIR="$TO"
  mkdir -p "$OUT_DIR"

  # Assign brand-new files numbers after the highest existing patch.
  next_num=$(( $(find_max_patch_num) + 1 ))

  BASELINE="$(mktemp -d)"
  CHECK=""
  cleanup() {
    [ -n "${BASELINE:-}" ] && rm -rf "$BASELINE"
    [ -n "${CHECK:-}" ] && rm -rf "$CHECK"
  }
  trap cleanup EXIT

  # Reconstruct the pre-patch baseline.
  materialize_pristine "$BASELINE"
  apply_patches_except_target "$BASELINE" "$(basename "$PATCH")"

  # Validate that every target file exists in both the baseline and the working
  # tree before we write anything, so a broken state fails clearly instead of
  # producing a corrupt patch.
  local f g
  for f in $TARGET_FILES; do
    [ -n "$f" ] || continue
    [ -f "$BASELINE/$f" ] || die "'$f' is not in the pre-patch baseline — is it still tracked in $UPSTREAM_PATH?"
    [ -f "$ROOT_DIR/$f" ] || die "working tree has no $f — did you edit it before running this?"
  done

  # Emit one patch per differing file.
  emit_patches "$OUT_DIR" "$BASELINE"

  if [ "${#generated[@]}" -eq 0 ]; then
    echo "regen-patch.sh: WARNING — no differing files: your edited working tree matches the pre-patch baseline (nothing to regenerate)." >&2
    exit 0
  fi

  echo "regen-patch.sh: wrote ${#generated[@]} patch(es):"
  for g in "${generated[@]}"; do
    echo "  $g"
  done

  # Self-verify: apply every generated patch to a fresh baseline copy and confirm
  # the whole tree reproduces the edited working tree.
  CHECK="$(mktemp -d)"
  verify_against_working_tree "$CHECK" || die "generated patch(es) do not reproduce your edited working tree."
  echo "regen-patch.sh: verified — the generated patch reproduces your edited working tree."
}

main "$@"
