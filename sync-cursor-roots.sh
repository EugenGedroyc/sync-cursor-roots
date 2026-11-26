#!/usr/bin/env bash
# Sync Cursor rules/, agents/, and skills/ between two .cursor roots (see CURSOR_ROOT_1 / CURSOR_ROOT_2).
# Also syncs optional project-level pairs (see SYNC_PROJECTS / --project).
# Uses newer mtime when content differs; prompts when mtimes tie (or with --tie-sec).
#
# Cross-filesystem / line endings (QA):
# - One root may live on a native Linux filesystem (e.g. ext4) and the other on a 9p/drvfs mount.
#   mtimes can land in the same 1s bucket across those; use --tie-sec 1 or 2 if you see bad picks.
# - Working-tree bytes can still be CRLF on one side; comparisons treat CRLF vs LF as equal
#   (diff --strip-trailing-cr). Text extensions auto LF-normalize on both roots when only EOL
#   differs (no --normalize-lf needed). Use --normalize-lf to strip CR on content-changing copies.
#   Keep .gitattributes with eol=lf for those paths. --commit-push LF-normalizes scoped
#   text in the working tree before git add so CRLF-on-drvfs files do not warn.
# - Paths may be Git Bash C:/... or /c/... (backslashes are accepted). Avoid mixing forms
#   inside one entry; the script canonicalizes existing directories via pwd -P.
#
# Usage:
#   sync-cursor-roots.sh [options]
#
# Assumptions:
#   Each .cursor root should live inside a git repo if you use --commit-push.
#   The script runs git add/commit/push from that root for rules/, agents/, skills/,
#   .gitignore, and .gitattributes, plus any SYNC_EXTRA_ITEMS. Project pairs are not
#   staged by --commit-push. Roots without .git are skipped for git.
#
# Environment (optional: $SCRIPT_DIR/.env, or a file named by SYNC_ENV_FILE):
#   SYNC_ENV_FILE              If set and this path is readable, source it (set -a); otherwise, if
#                              $SCRIPT_DIR/.env is readable, source that. No other paths are loaded.
#   CURSOR_ROOT_1              First .cursor root directory (default: $HOME/.cursor if unset).
#   CURSOR_ROOT_2              Second .cursor root directory (required: set in .env or pass --root-2).
#   SYNC_IGNORE_2_TO_1         Colon-separated paths; skip any copy or LF-normalize that would write
#                              root 2 bytes into root 1. Global keys stay repo-relative (rules/a.mdc).
#                              Project keys are projects/<name>/<rel>, e.g. projects/my-app/rules/x.mdc.
#   SYNC_IGNORE_1_TO_2         Same shape, blocking root 1 → root 2. Non-empty shell exports for
#                              SYNC_IGNORE_*, SYNC_PROJECTS, SYNC_PROJECT_ITEMS, and SYNC_EXTRA_ITEMS
#                              win over values from the file (see README).
#   SYNC_PROJECTS              Project pairs name|side1|side2, separated by newlines or semicolons.
#                              side1/side2 are that project's .cursor dir on each side (side 2 may be
#                              a folder in a settings repo and need not be named .cursor). Blank lines
#                              and lines starting with # are ignored. A later --project with the same
#                              name overrides the file entry.
#   SYNC_PROJECT_ITEMS         Items synced inside each project pair (comma, semicolon, or whitespace).
#                              A trailing slash, or a bare name with no dot, is a directory tree; any
#                              other entry is one file. Default:
#                              rules/,skills/,commands/,agents/,mcp.json,hooks.json,BUGBOT.md
#   SYNC_EXTRA_ITEMS           Optional items added to the global roots only (same syntax). Default
#                              empty, so commands/, mcp.json, and hooks.json stay out of the global sync.
#
# Options:
#   --dry-run                  Print planned actions only; no copies, mkdir, or git writes.
#                              No interactive prompts. When mtimes tie within --tie-sec
#                              but content differs, prints [dry-run] conflict lines and
#                              skips (no prompt).
#   -y, --yes                  Skip interactive confirmations before mutating sync and
#                              before git commit/push. Does not change conflict resolution:
#                              mtime ties with differing content still use the interactive
#                              menu unless --dry-run (which skips those conflicts).
#   --commit-push              After sync, git add/commit/push for the global scope only
#                              (rules/, agents/, skills/, SYNC_EXTRA_ITEMS, gitignore, gitattributes).
#                              When not --dry-run, prompts before commit/push unless -y/--yes.
#   -m, --message TEXT         Commit message (default: Cursor agent proposes one)
#   --root-1 PATH              Cursor root 1 (default: $CURSOR_ROOT_1 or $HOME/.cursor)
#   --root-2 PATH              Cursor root 2 (default: $CURSOR_ROOT_2; required if unset)
#   --project SPEC             Project pair name|side1|side2 (repeatable). Same name overrides
#                              SYNC_PROJECTS. Paths may be C:/..., /c/..., or relative.
#   --projects-only            Sync project pairs only; do not scan global rules/agents/skills.
#   --no-projects              Do not sync project pairs (global roots only).
#   --tie-sec N                If |mtime_a-mtime_b| <= N and content differs, prompt (default: 0)
#   --normalize-lf             When copying, strip CR for common text extensions (see script)
#   --verbose                  Log skips for CRLF-only diffs on extensions we do not LF-normalize
#   -h, --help                 Show help
#
# Project paths: if neither side exists, or a side exists and is not a directory, the script warns
# and skips that pair. If only one side exists, it creates the missing directory (unless --dry-run).
#
# Interactive prompts (tty; use -y/--yes if unavailable):
#   Do you want to continue? [Y/n/d] — before mutating sync (impact summary first).
#   Y / empty / yes: proceed; n / no: exit 0; d: full unified diffs in less -R, then re-prompt.
#   Proceed with git commit and push? [Y/n/d] — same; d runs a per-root staged diff preview.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Optional .env: export all assigned vars. Non-empty pre-set SYNC_IGNORE_*, SYNC_PROJECTS,
# SYNC_PROJECT_ITEMS, and SYNC_EXTRA_ITEMS in the shell win over the file.
load_sync_env_file() {
  local env_path=""
  if [[ -n "${SYNC_ENV_FILE-}" ]]; then
    if [[ -f "$SYNC_ENV_FILE" && -r "$SYNC_ENV_FILE" ]]; then
      env_path="$SYNC_ENV_FILE"
    fi
  elif [[ -f "$SCRIPT_DIR/.env" && -r "$SCRIPT_DIR/.env" ]]; then
    env_path="$SCRIPT_DIR/.env"
  fi
  [[ -z "$env_path" ]] && return 0
  local _pre_1_to_2 _pre_2_to_1 _pre_projects _pre_pitems _pre_extras
  _pre_1_to_2="${SYNC_IGNORE_1_TO_2-}"
  _pre_2_to_1="${SYNC_IGNORE_2_TO_1-}"
  _pre_projects="${SYNC_PROJECTS-}"
  _pre_pitems="${SYNC_PROJECT_ITEMS-}"
  _pre_extras="${SYNC_EXTRA_ITEMS-}"
  set -a
  # shellcheck disable=SC1090
  source "$env_path"
  set +a
  # Use if/fi (not &&) so the last statement is never a failing [[ under set -e.
  if [[ -n "$_pre_1_to_2" ]]; then
    SYNC_IGNORE_1_TO_2="$_pre_1_to_2"
  fi
  if [[ -n "$_pre_2_to_1" ]]; then
    SYNC_IGNORE_2_TO_1="$_pre_2_to_1"
  fi
  if [[ -n "$_pre_projects" ]]; then
    SYNC_PROJECTS="$_pre_projects"
  fi
  if [[ -n "$_pre_pitems" ]]; then
    SYNC_PROJECT_ITEMS="$_pre_pitems"
  fi
  if [[ -n "$_pre_extras" ]]; then
    SYNC_EXTRA_ITEMS="$_pre_extras"
  fi
}

load_sync_env_file

DRY_RUN=0
ASSUME_YES=0
COMMIT_PUSH=0
COMMIT_MSG=""
TIE_SEC=0
NORMALIZE_LF=0
VERBOSE=0
ROOT1="${CURSOR_ROOT_1:-$HOME/.cursor}"
ROOT2="${CURSOR_ROOT_2:-}"
# Set to 1 after the first successful mutating-sync confirmation (copies / LF-normalize to both).
SYNC_WRITE_CONSENTED=0
SKIP_GIT_COMMIT_PUSH=0
# Global scope. Directory items end with /. SYNC_EXTRA_ITEMS is appended after argument parsing.
GLOBAL_ITEMS=(rules/ agents/ skills/)
PROJECT_ITEMS=()
DO_GLOBAL=1
DO_PROJECTS=1
CLI_PROJECTS=()
PROJECT_ORDER=()
ACTIVE_PROJECTS=()
PROJECT_DIRS_TO_CREATE=()
GIT_SCOPE_LABEL="rules, agents, skills, gitignore/attributes"
declare -A PROJECT_PATH1=()
declare -A PROJECT_PATH2=()
# Logical relative path (ignore key / display) → pair roots and path under each root.
declare -A FILE_REL=()
declare -A FILE_ROOT1=()
declare -A FILE_ROOT2=()

die() { echo "error: $*" >&2; exit 1; }

# GNU diffutils 3.4+: color when stdout is a tty (--color=auto). Ignored on older diff.
DIFF_COLOR_FLAG=()
if diff --color=auto -u /dev/null /dev/null >/dev/null 2>&1; then
  DIFF_COLOR_FLAG=(--color=auto)
fi

# Unified diff with CRLF ignored; optional color (see DIFF_COLOR_FLAG).
# SYNC_DIFF_PAGER=1 (set by pager_show_diff): force color for a pipe into less -R.
diff_unified() {
  local color_flag=("${DIFF_COLOR_FLAG[@]}")
  if [[ -n "${SYNC_DIFF_PAGER:-}" ]] && ((${#DIFF_COLOR_FLAG[@]})); then
    color_flag=(--color=always)
  fi
  diff "${color_flag[@]}" -u --strip-trailing-cr "$@" || true
}

# Run show_diff_cmd through less (colors preserved via SYNC_DIFF_PAGER + less -R).
pager_show_diff() {
  local show_diff_cmd="$1" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/sync-cursor-roots.diff.XXXXXX")
  SYNC_DIFF_PAGER=1 "$show_diff_cmd" >"$tmp" 2>&1 || true
  if command -v less >/dev/null 2>&1; then
    less -R "$tmp" </dev/tty >/dev/tty 2>/dev/tty || true
  else
    cat "$tmp" >/dev/tty 2>/dev/tty || cat "$tmp"
  fi
  rm -f -- "$tmp"
}

# Prompt on /dev/tty; empty or y/yes => 0 (yes); n/no => 1 (no). Loops on invalid input.
confirm_default_yes() {
  local msg="$1" ans
  while true; do
    if [[ ! -r /dev/tty ]] || [[ ! -w /dev/tty ]]; then
      die "cannot prompt interactively (/dev/tty unavailable); use -y/--yes or run in a terminal"
    fi
    printf '%s\n' "$msg" >/dev/tty
    read -r ans </dev/tty || die "cannot read confirmation from terminal; use -y/--yes"
    case "${ans:-}" in
      '' | [yY] | [yY][eE][sS]) return 0 ;;
      [nN] | [nN][oO]) return 1 ;;
      *) printf 'Please answer y or n (default yes).\n' >/dev/tty ;;
    esac
  done
}

# Like confirm_default_yes with optional d: show_diff_cmd is run when user enters d/D (must not exit).
confirm_default_yes_with_diff() {
  local msg="$1"
  shift
  local show_diff_cmd="$1"
  local ans
  while true; do
    if [[ ! -r /dev/tty ]] || [[ ! -w /dev/tty ]]; then
      die "cannot prompt interactively (/dev/tty unavailable); use -y/--yes or run in a terminal"
    fi
    printf '%s\n' "$msg" >/dev/tty
    read -r ans </dev/tty || die "cannot read confirmation from terminal; use -y/--yes"
    case "${ans:-}" in
      '' | [yY] | [yY][eE][sS]) return 0 ;;
      [nN] | [nN][oO]) return 1 ;;
      d|D) pager_show_diff "$show_diff_cmd" ;;
      *) printf 'Please answer y, n, or d (default yes).\n' >/dev/tty ;;
    esac
  done
}

# Populated by build_sync_ignore_maps() from SYNC_IGNORE_* (colon-separated rel paths).
declare -A SYNC_IGNORE_2_TO_1_MAP=()
declare -A SYNC_IGNORE_1_TO_2_MAP=()

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

fill_ignore_map_from_var() {
  local value="$1"
  local -n target_map="$2"
  target_map=()
  [[ -z "$value" ]] && return 0
  local IFS=':'
  local seg
  for seg in $value; do
    seg=$(trim "$seg")
    # nameref; shellcheck does not see writes via target_map
    # shellcheck disable=SC2034
    [[ -n "$seg" ]] && target_map["$seg"]=1
  done
}

build_sync_ignore_maps() {
  fill_ignore_map_from_var "${SYNC_IGNORE_2_TO_1-}" SYNC_IGNORE_2_TO_1_MAP
  fill_ignore_map_from_var "${SYNC_IGNORE_1_TO_2-}" SYNC_IGNORE_1_TO_2_MAP
}

rel_blocked_2_to_1() {
  [[ -n "${SYNC_IGNORE_2_TO_1_MAP[$1]+x}" ]]
}

rel_blocked_1_to_2() {
  [[ -n "${SYNC_IGNORE_1_TO_2_MAP[$1]+x}" ]]
}

# stdout: [dry-run] lines (match other dry-run copy messages).
dry_run_skip_ignore() {
  local which="$1" rel="$2"
  printf '[dry-run] skipped (%s): %s\n' "$which" "$rel"
}

# Non-dry: align with --verbose skips (e.g. EOL-only).
skip_ignore_msg() {
  local tag="$1" rel="$2"
  if [[ $VERBOSE -eq 1 ]]; then
    printf 'skip (ignored %s): %s\n' "$tag" "$rel" >&2
  fi
  return 0
}

normalize_src_for_pair() {
  local root1_f="$1" root2_f="$2"
  local ma mb
  ma=$(mtime "$root1_f")
  mb=$(mtime "$root2_f")
  if [[ $ma -ge $mb ]]; then
    printf '%s\n' "$root1_f"
  else
    printf '%s\n' "$root2_f"
  fi
}

# Resolve the two files for a logical relative path (global rel, or projects/<name>/<rel>).
pair_paths() {
  local logical="$1"
  local file_rel="$logical"
  local root1="$ROOT1"
  local root2="$ROOT2"
  if [[ -n "${FILE_REL[$logical]+x}" ]]; then
    file_rel="${FILE_REL[$logical]}"
  fi
  if [[ -n "${FILE_ROOT1[$logical]+x}" ]]; then
    root1="${FILE_ROOT1[$logical]}"
  fi
  if [[ -n "${FILE_ROOT2[$logical]+x}" ]]; then
    root2="${FILE_ROOT2[$logical]}"
  fi
  PP_R1="$root1/$file_rel"
  PP_R2="$root2/$file_rel"
}

# Populate PLAN_* arrays; mirrors sync_one decisions (DRY_RUN must be off; tie → PLAN_TIE).
plan_sync_one() {
  local rel="$1"
  pair_paths "$rel"
  local root1_f="$PP_R1"
  local root2_f="$PP_R2"

  if [[ ! -f "$root1_f" && ! -f "$root2_f" ]]; then
    return 0
  fi

  if [[ -f "$root1_f" && ! -f "$root2_f" ]]; then
    if rel_blocked_1_to_2 "$rel"; then
      return 0
    fi
    PLAN_COPY_TO_2+=("$rel")
    return 0
  fi

  if [[ ! -f "$root1_f" && -f "$root2_f" ]]; then
    if rel_blocked_2_to_1 "$rel"; then
      return 0
    fi
    PLAN_COPY_TO_1+=("$rel")
    return 0
  fi

  if bytes_identical "$root1_f" "$root2_f"; then
    return 0
  fi
  if text_same_ignoring_cr "$root1_f" "$root2_f"; then
    # CRLF vs LF only: cmp differs but diff --strip-trailing-cr agrees; normalize listed text types
    # on both sides without requiring --normalize-lf so cross-mount skills/rules stay convergent.
    if should_normalize_lf "$root1_f"; then
      local ma0 mb0 src0
      ma0=$(mtime "$root1_f")
      mb0=$(mtime "$root2_f")
      if [[ $ma0 -ge $mb0 ]]; then
        src0=$root1_f
      else
        src0=$root2_f
      fi
      if [[ "$src0" == "$root2_f" ]] && rel_blocked_2_to_1 "$rel"; then
        return 0
      fi
      if [[ "$src0" == "$root1_f" ]] && rel_blocked_1_to_2 "$rel"; then
        return 0
      fi
      PLAN_NORMALIZE+=("$rel")
    fi
    return 0
  fi

  local ma mb diff_t
  ma=$(mtime "$root1_f")
  mb=$(mtime "$root2_f")
  diff_t=$(( ma > mb ? ma - mb : mb - ma ))

  if [[ $diff_t -gt $TIE_SEC ]]; then
    if [[ $ma -gt $mb ]]; then
      if rel_blocked_1_to_2 "$rel"; then
        return 0
      fi
      PLAN_COPY_TO_2+=("$rel")
    else
      if rel_blocked_2_to_1 "$rel"; then
        return 0
      fi
      PLAN_COPY_TO_1+=("$rel")
    fi
    return 0
  fi

  PLAN_TIE+=("$rel")
}

diff_copy_to_dest() {
  local dest="$1" src="$2" old_label="$3" new_label="$4"
  local dest_use="$dest"
  [[ -f "$dest" ]] || dest_use=/dev/null
  diff_unified -L "$old_label" -L "$new_label" "$dest_use" "$src"
}

show_planned_sync_diffs() {
  local rel root1_f root2_f src tmp
  for rel in "${PLAN_COPY_TO_2[@]+"${PLAN_COPY_TO_2[@]}"}"; do
    pair_paths "$rel"
    root1_f="$PP_R1"
    root2_f="$PP_R2"
    echo "=== copy → root 2: $rel ==="
    diff_copy_to_dest "$root2_f" "$root1_f" "OLD (root 2: $root2_f)" "NEW (root 1 → root 2: $root1_f)"
    echo
  done
  for rel in "${PLAN_COPY_TO_1[@]+"${PLAN_COPY_TO_1[@]}"}"; do
    pair_paths "$rel"
    root1_f="$PP_R1"
    root2_f="$PP_R2"
    echo "=== copy → root 1: $rel ==="
    diff_copy_to_dest "$root1_f" "$root2_f" "OLD (root 1: $root1_f)" "NEW (root 2 → root 1: $root2_f)"
    echo
  done
  for rel in "${PLAN_NORMALIZE[@]+"${PLAN_NORMALIZE[@]}"}"; do
    pair_paths "$rel"
    root1_f="$PP_R1"
    root2_f="$PP_R2"
    src=$(normalize_src_for_pair "$root1_f" "$root2_f")
    echo "=== LF-normalize → both: $rel (chosen src: $src) ==="
    tmp=$(mktemp "${TMPDIR:-/tmp}/sync-cursor-roots.pre-diff.XXXXXX")
    sed 's/\r$//' < "$src" > "$tmp"
    if ! cmp -s "$root1_f" "$tmp" 2>/dev/null; then
      diff_unified -L "root 1 (current): $root1_f" -L "normalized (proposal)" "$root1_f" "$tmp"
      echo
    fi
    if ! cmp -s "$root2_f" "$tmp" 2>/dev/null; then
      diff_unified -L "root 2 (current): $root2_f" -L "normalized (proposal)" "$root2_f" "$tmp"
      echo
    fi
    rm -f -- "$tmp"
    echo
  done
  for rel in "${PLAN_TIE[@]+"${PLAN_TIE[@]}"}"; do
    pair_paths "$rel"
    root1_f="$PP_R1"
    root2_f="$PP_R2"
    echo "=== mtime tie / conflict (--tie-sec $TIE_SEC): $rel ==="
    if [[ -f "$root1_f" && -f "$root2_f" ]]; then
      diff_unified -L "root 1: $root1_f" -L "root 2: $root2_f" "$root1_f" "$root2_f"
    else
      echo "(cannot diff: missing file)"
    fi
    echo
  done
}

print_sync_impact_summary() {
  local n2 n1 nt nn
  n2=${#PLAN_COPY_TO_2[@]}
  n1=${#PLAN_COPY_TO_1[@]}
  nn=${#PLAN_NORMALIZE[@]}
  nt=${#PLAN_TIE[@]}
  echo "Upcoming sync (this run):"
  if ((n2)); then
    echo "  Copy → root 2 ($n2):"
    local r
    for r in "${PLAN_COPY_TO_2[@]}"; do echo "    $r"; done
  fi
  if ((n1)); then
    echo "  Copy → root 1 ($n1):"
    local r2
    for r2 in "${PLAN_COPY_TO_1[@]}"; do echo "    $r2"; done
  fi
  if ((nn)); then
    echo "  LF-normalize → both, text types ($nn):"
    local r3
    for r3 in "${PLAN_NORMALIZE[@]}"; do echo "    $r3"; done
  fi
  if ((nt)); then
    echo "  Mtime tie / conflict within --tie-sec=$TIE_SEC ($nt) — resolve interactively:"
    local r4
    for r4 in "${PLAN_TIE[@]}"; do echo "    $r4"; done
  fi
  if ((${#PROJECT_DIRS_TO_CREATE[@]})); then
    echo "  Create missing project directory (${#PROJECT_DIRS_TO_CREATE[@]}):"
    local d
    for d in "${PROJECT_DIRS_TO_CREATE[@]}"; do echo "    $d"; done
  fi
  echo
}

ensure_pre_sync_consent_if_needed() {
  if [[ $DRY_RUN -eq 1 ]] || [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi

  PLAN_COPY_TO_2=()
  PLAN_COPY_TO_1=()
  PLAN_NORMALIZE=()
  PLAN_TIE=()
  local rel
  for rel in "${PATHS_SORTED[@]+"${PATHS_SORTED[@]}"}"; do
    plan_sync_one "$rel"
  done

  local total_mut total_tie
  total_mut=$((${#PLAN_COPY_TO_2[@]} + ${#PLAN_COPY_TO_1[@]} + ${#PLAN_NORMALIZE[@]}))
  total_tie=${#PLAN_TIE[@]}
  if [[ $total_mut -eq 0 ]] && [[ $total_tie -eq 0 ]]; then
    return 0
  fi

  print_sync_impact_summary
  if ! confirm_default_yes_with_diff 'Do you want to continue? [Y/n/d]' show_planned_sync_diffs; then
    echo 'Aborted: no file changes were made.' >&2
    exit 0
  fi
  SYNC_WRITE_CONSENTED=1
}

ensure_mutating_sync_consent() {
  if [[ $DRY_RUN -eq 1 ]] || [[ $ASSUME_YES -eq 1 ]] || [[ $SYNC_WRITE_CONSENTED -eq 1 ]]; then
    return 0
  fi
  if ! confirm_default_yes 'Do you want to continue? [Y/n]'; then
    echo 'Aborted: no file changes were made.' >&2
    exit 0
  fi
  SYNC_WRITE_CONSENTED=1
}

usage() {
  sed -n '2,/^[^#]/p' "$0" | sed '/^[^#]/d' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --commit-push) COMMIT_PUSH=1 ;;
    -m|--message)
      [[ $# -ge 2 ]] || die "--message requires a value"
      COMMIT_MSG="$2"
      shift
      ;;
    --root-1)
      [[ $# -ge 2 ]] || die "--root-1 requires a path"
      ROOT1="$2"
      shift
      ;;
    --root-2)
      [[ $# -ge 2 ]] || die "--root-2 requires a path"
      ROOT2="$2"
      shift
      ;;
    --project)
      [[ $# -ge 2 ]] || die "--project requires name|path1|path2"
      CLI_PROJECTS+=("$2")
      shift
      ;;
    --projects-only) DO_GLOBAL=0 ;;
    --no-projects) DO_PROJECTS=0 ;;
    --tie-sec)
      [[ $# -ge 2 ]] || die "--tie-sec requires a number"
      [[ "$2" =~ ^[0-9]+$ ]] || die "--tie-sec must be a non-negative integer"
      TIE_SEC="$2"
      shift
      ;;
    --normalize-lf) NORMALIZE_LF=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

if [[ $DO_GLOBAL -eq 0 && $DO_PROJECTS -eq 0 ]]; then
  die "--projects-only and --no-projects cannot be combined"
fi

[[ -n "${ROOT2}" ]] || die "CURSOR_ROOT_2 must be set in .env (or SYNC_ENV_FILE) or pass --root-2 PATH"
[[ -d "$ROOT1" ]] || die "cursor root 1 not a directory: $ROOT1"
[[ -d "$ROOT2" ]] || die "cursor root 2 not a directory: $ROOT2"

resolve_root() {
  local p="$1"
  readlink -f "$p" 2>/dev/null || echo "$p"
}

ROOT1_CFG=$ROOT1
ROOT2_CFG=$ROOT2
ROOT1=$(resolve_root "$ROOT1")
ROOT2=$(resolve_root "$ROOT2")

fs_type() {
  df -T "$1" 2>/dev/null | awk 'NR==2 {print $2}'
}

maybe_warn_drvfs() {
  local root="$1" label="$2"
  local t
  t=$(fs_type "$root")
  if [[ "$t" == "9p" ]]; then
    echo "note: cursor root ($label) looks like a 9p/drvfs-style mount ($root)." >&2
    echo "      Same-second mtimes happen across native fs vs 9p/drvfs; try --tie-sec 1 or 2 if picks look wrong." >&2
  fi
}

mtime() {
  local f="$1"
  if [[ -f "$f" ]]; then
    stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# Byte-identical, or text that only differs by CRLF vs LF (GNU diff --strip-trailing-cr).
bytes_identical() {
  cmp -s "$1" "$2"
}

text_same_ignoring_cr() {
  diff -q --strip-trailing-cr "$1" "$2" >/dev/null 2>&1
}

should_normalize_lf() {
  case "${1,,}" in
    *.md|*.mdc|*.json|*.jsonl|*.yaml|*.yml|*.txt) return 0 ;;
    *) return 1 ;;
  esac
}

# Strip CR from one working-tree file. Missing CR or a non-text extension is a no-op.
normalize_lf_file() {
  local f="$1" tmp
  should_normalize_lf "$f" || return 0
  grep -q $'\r' "$f" 2>/dev/null || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/sync-cursor-roots.XXXXXX")
  sed 's/\r$//' < "$f" > "$tmp"
  mv -f -- "$tmp" "$f"
}

# Strip CR from scoped text files in the working tree (cwd = repo root). Avoids git add
# "CRLF will be replaced by LF" warnings when .gitattributes sets eol=lf on 9p/drvfs mounts.
normalize_lf_in_sync_scope() {
  local item sub f
  for item in "${GLOBAL_ITEMS[@]}"; do
    if [[ "$item" == */ ]]; then
      sub="${item%/}"
      [[ -d "$sub" ]] || continue
      while IFS= read -r -d '' f; do
        normalize_lf_file "$f"
      done < <(find "$sub" -type f -print0 2>/dev/null)
    elif [[ -f "$item" ]]; then
      normalize_lf_file "$item"
    fi
  done
}

# Item syntax: trailing slash, or a bare name with no dot, is a directory; otherwise a file.
normalize_item_name() {
  local s="$1" rest part
  s="${s//\\//}"
  [[ -n "$s" ]] || die "empty sync item"
  if [[ "$s" != */ && "$s" != */* && "$s" != *.* ]]; then
    s="${s}/"
  fi
  if [[ "$s" == /* || "$s" =~ ^[A-Za-z]: ]]; then
    die "sync item must be relative to the cursor directory: ${s%/}"
  fi
  rest="${s%/}"
  set -f
  local IFS=/
  for part in $rest; do
    if [[ -z "$part" || "$part" == "." || "$part" == ".." ]]; then
      set +f
      die "invalid sync item: ${s%/}"
    fi
  done
  set +f
  printf '%s\n' "$s"
}

# $1 spec text, $2 nameref of the destination array.
parse_item_spec_into() {
  local spec="$1"
  local -n _dest="$2"
  local flat part normalized
  flat="${spec//$'\r'/$'\n'}"
  flat="${flat//,/$'\n'}"
  flat="${flat//;/$'\n'}"
  flat="${flat//$'\t'/$'\n'}"
  flat="${flat// /$'\n'}"
  while IFS= read -r part || [[ -n "$part" ]]; do
    part=$(trim "$part")
    [[ -z "$part" ]] && continue
    normalized=$(normalize_item_name "$part")
    _dest+=("$normalized")
  done <<<"$flat"
}

item_in_list() {
  local needle="$1" x
  shift
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

add_project_spec() {
  local spec="$1" source_label="$2"
  local name="" path1="" path2="" rest=""
  local IFS='|'
  read -r name path1 path2 rest <<<"$spec" || true
  name=$(trim "$name")
  path1=$(trim "$path1")
  path2=$(trim "${path2-}")
  rest=$(trim "${rest-}")
  if [[ -n "$rest" || -z "$name" || -z "$path1" || -z "$path2" ]]; then
    die "project entry must be name|path1|path2 ($source_label: $spec)"
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "project name must match [A-Za-z0-9._-]+ ($source_label: $name)"
  fi
  if [[ -n "${PROJECT_PATH1[$name]+x}" ]]; then
    echo "note: project '$name' overridden by $source_label" >&2
  else
    PROJECT_ORDER+=("$name")
  fi
  PROJECT_PATH1[$name]="$path1"
  PROJECT_PATH2[$name]="$path2"
}

parse_projects_blob() {
  local raw="$1" source_label="$2" line
  [[ -n "$raw" ]] || return 0
  raw="${raw//$'\r'/}"
  raw="${raw//;/$'\n'}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(trim "$line")
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    add_project_spec "$line" "$source_label"
  done <<<"$raw"
}

configure_sync_scope() {
  local item spec
  local -a extra_items=()
  GLOBAL_ITEMS=(rules/ agents/ skills/)
  if [[ -n "${SYNC_EXTRA_ITEMS-}" ]]; then
    parse_item_spec_into "$SYNC_EXTRA_ITEMS" extra_items
    for item in "${extra_items[@]+"${extra_items[@]}"}"; do
      if item_in_list "$item" "${GLOBAL_ITEMS[@]}"; then
        continue
      fi
      GLOBAL_ITEMS+=("$item")
    done
    GIT_SCOPE_LABEL="rules, agents, skills, extra items, gitignore/attributes"
  fi
  PROJECT_ITEMS=()
  if [[ -n "${SYNC_PROJECT_ITEMS-}" ]]; then
    parse_item_spec_into "$SYNC_PROJECT_ITEMS" PROJECT_ITEMS
  else
    parse_item_spec_into "rules/,skills/,commands/,agents/,mcp.json,hooks.json,BUGBOT.md" PROJECT_ITEMS
  fi
  if [[ ${#PROJECT_ITEMS[@]} -eq 0 ]]; then
    die "SYNC_PROJECT_ITEMS did not contain any sync items"
  fi
  PROJECT_ORDER=()
  parse_projects_blob "${SYNC_PROJECTS-}" "SYNC_PROJECTS"
  for spec in "${CLI_PROJECTS[@]+"${CLI_PROJECTS[@]}"}"; do
    add_project_spec "$spec" "--project"
  done
  if [[ $DO_GLOBAL -eq 0 && ${#PROJECT_ORDER[@]} -eq 0 ]]; then
    die "no project pairs configured; set SYNC_PROJECTS or pass --project name|path1|path2"
  fi
}

# Existing directories become a physical absolute path. Missing paths keep a stable
# parent+basename form so Git Bash C:/ and /c/ inputs still match find output later.
canon_path() {
  local p="$1" parent base canon_parent resolved
  p="${p//\\//}"
  while [[ "$p" == */ && ${#p} -gt 1 && "$p" != [A-Za-z]:/ ]]; do
    p="${p%/}"
  done
  if [[ -d "$p" ]]; then
    canon_parent=$(cd -- "$p" && pwd -P) || canon_parent=""
    if [[ -n "$canon_parent" ]]; then
      printf '%s\n' "$canon_parent"
      return 0
    fi
  fi
  parent=$(dirname -- "$p")
  base=$(basename -- "$p")
  if [[ "$parent" != "$p" && -d "$parent" ]]; then
    canon_parent=$(cd -- "$parent" && pwd -P) || canon_parent=""
    if [[ -n "$canon_parent" ]]; then
      printf '%s/%s\n' "$canon_parent" "$base"
      return 0
    fi
  fi
  resolved=$(readlink -f "$p" 2>/dev/null) || true
  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  printf '%s\n' "$p"
}

prepare_project_pair() {
  local name="$1"
  local p1 p2
  p1=$(canon_path "${PROJECT_PATH1[$name]}")
  p2=$(canon_path "${PROJECT_PATH2[$name]}")
  PROJECT_PATH1[$name]="$p1"
  PROJECT_PATH2[$name]="$p2"
  if [[ -e "$p1" && ! -d "$p1" ]]; then
    echo "warning: project '$name': side 1 exists but is not a directory; skipping: $p1" >&2
    return 1
  fi
  if [[ -e "$p2" && ! -d "$p2" ]]; then
    echo "warning: project '$name': side 2 exists but is not a directory; skipping: $p2" >&2
    return 1
  fi
  if [[ ! -d "$p1" && ! -d "$p2" ]]; then
    echo "warning: project '$name': neither side exists; skipping" >&2
    echo "  side 1: $p1" >&2
    echo "  side 2: $p2" >&2
    return 1
  fi
  if [[ -d "$p1" && ! -d "$p2" ]]; then
    PROJECT_DIRS_TO_CREATE+=("$p2")
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "note: project '$name': side 2 is missing (dry-run, not creating): $p2" >&2
    else
      echo "note: project '$name': side 2 is missing and will be created: $p2" >&2
    fi
  elif [[ -d "$p2" && ! -d "$p1" ]]; then
    PROJECT_DIRS_TO_CREATE+=("$p1")
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "note: project '$name': side 1 is missing (dry-run, not creating): $p1" >&2
    else
      echo "note: project '$name': side 1 is missing and will be created: $p1" >&2
    fi
  fi
  return 0
}

activate_projects() {
  local name
  ACTIVE_PROJECTS=()
  PROJECT_DIRS_TO_CREATE=()
  [[ $DO_PROJECTS -eq 1 ]] || return 0
  for name in "${PROJECT_ORDER[@]+"${PROJECT_ORDER[@]}"}"; do
    if prepare_project_pair "$name"; then
      ACTIVE_PROJECTS+=("$name")
    fi
  done
}

# Null-delimited files under one root for the given items (dirs recurse, files are exact).
collect_scope_files() {
  local root="$1"
  shift
  local item sub
  [[ -d "$root" ]] || return 0
  for item in "$@"; do
    if [[ "$item" == */ ]]; then
      sub="${item%/}"
      if [[ -d "$root/$sub" ]]; then
        find "$root/$sub" -type f -print0 2>/dev/null
      fi
    elif [[ -f "$root/$item" ]]; then
      printf '%s\0' "$root/$item"
    fi
  done
}

index_pair() {
  local root1="$1" root2="$2" prefix="$3"
  shift 3
  local -a items=("$@")
  local -a found=()
  local -A local_seen=()
  local f rel logical
  while IFS= read -r -d '' f; do
    rel="${f#"$root1"/}"
    if [[ -z "$rel" || "$rel" == "$f" ]]; then
      continue
    fi
    if [[ -z "${local_seen[$rel]+x}" ]]; then
      local_seen[$rel]=1
      found+=("$rel")
    fi
  done < <(collect_scope_files "$root1" "${items[@]}")
  while IFS= read -r -d '' f; do
    rel="${f#"$root2"/}"
    if [[ -z "$rel" || "$rel" == "$f" ]]; then
      continue
    fi
    if [[ -z "${local_seen[$rel]+x}" ]]; then
      local_seen[$rel]=1
      found+=("$rel")
    fi
  done < <(collect_scope_files "$root2" "${items[@]}")
  for rel in "${found[@]+"${found[@]}"}"; do
    if [[ -n "$prefix" ]]; then
      logical="$prefix/$rel"
    else
      logical="$rel"
    fi
    if [[ -z "${SEEN_PATHS[$logical]+x}" ]]; then
      SEEN_PATHS[$logical]=1
      PATHS+=("$logical")
    fi
    FILE_REL[$logical]="$rel"
    FILE_ROOT1[$logical]="$root1"
    FILE_ROOT2[$logical]="$root2"
  done
}

index_all_pairs() {
  local name
  if [[ $DO_GLOBAL -eq 1 ]]; then
    index_pair "$ROOT1" "$ROOT2" "" "${GLOBAL_ITEMS[@]}"
  fi
  if [[ $DO_PROJECTS -eq 1 ]]; then
    for name in "${ACTIVE_PROJECTS[@]+"${ACTIVE_PROJECTS[@]}"}"; do
      index_pair "${PROJECT_PATH1[$name]}" "${PROJECT_PATH2[$name]}" "projects/$name" "${PROJECT_ITEMS[@]}"
    done
  fi
}

default_global_scope() {
  [[ ${#GLOBAL_ITEMS[@]} -eq 3 && "${GLOBAL_ITEMS[0]}" == rules/ && "${GLOBAL_ITEMS[1]}" == agents/ && "${GLOBAL_ITEMS[2]}" == skills/ ]]
}

print_run_header() {
  local name
  echo "Cursor root 1: $ROOT1"
  [[ "$ROOT1_CFG" != "$ROOT1" ]] && echo "  (from $ROOT1_CFG)"
  echo "Cursor root 2: $ROOT2"
  [[ "$ROOT2_CFG" != "$ROOT2" ]] && echo "  (from $ROOT2_CFG)"
  if [[ $DO_GLOBAL -eq 1 ]]; then
    echo "Scope:        ${GLOBAL_ITEMS[*]}"
  else
    echo "Scope:        projects only (--projects-only)"
  fi
  if [[ $DO_PROJECTS -eq 1 && ${#PROJECT_ORDER[@]} -gt 0 ]]; then
    echo "Projects:     ${#ACTIVE_PROJECTS[@]} pair(s); items: ${PROJECT_ITEMS[*]}"
    for name in "${ACTIVE_PROJECTS[@]+"${ACTIVE_PROJECTS[@]}"}"; do
      echo "  $name: ${PROJECT_PATH1[$name]}  <->  ${PROJECT_PATH2[$name]}"
    done
  elif [[ $DO_PROJECTS -eq 0 && ${#PROJECT_ORDER[@]} -gt 0 ]]; then
    echo "Projects:     skipped (--no-projects)"
  fi
  [[ $NORMALIZE_LF -eq 1 ]] && echo "Normalize:    LF strip on copy for .md/.mdc/.json/.yaml/.txt"
  [[ $DRY_RUN -eq 1 ]] && echo "Mode:         dry-run"
  maybe_warn_drvfs "$ROOT1" "root 1"
  maybe_warn_drvfs "$ROOT2" "root 2"
  if [[ $DO_PROJECTS -eq 1 ]]; then
    for name in "${ACTIVE_PROJECTS[@]+"${ACTIVE_PROJECTS[@]}"}"; do
      if [[ -d "${PROJECT_PATH1[$name]}" ]]; then
        maybe_warn_drvfs "${PROJECT_PATH1[$name]}" "project $name side 1"
      fi
      if [[ -d "${PROJECT_PATH2[$name]}" ]]; then
        maybe_warn_drvfs "${PROJECT_PATH2[$name]}" "project $name side 2"
      fi
    done
  fi
  if [[ $DO_GLOBAL -eq 0 ]]; then
    echo "Scanning project pairs ..."
  elif [[ $DO_PROJECTS -eq 1 && ${#ACTIVE_PROJECTS[@]} -gt 0 ]]; then
    echo "Scanning global roots and project pairs ..."
  elif default_global_scope; then
    echo "Scanning both roots for files under rules/, agents/, skills/ ..."
  else
    echo "Scanning both roots for files under global scope (${GLOBAL_ITEMS[*]}) ..."
  fi
  echo
}

create_missing_project_dirs() {
  local d
  for d in "${PROJECT_DIRS_TO_CREATE[@]+"${PROJECT_DIRS_TO_CREATE[@]}"}"; do
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[dry-run] would create directory: $d"
    else
      mkdir -p -- "$d" || die "cannot create directory: $d"
      echo "created directory: $d"
    fi
  done
}

configure_sync_scope
activate_projects
print_run_header

declare -A SEEN_PATHS=()
PATHS=()
index_all_pairs

PATHS_SORTED=()
if ((${#PATHS[@]})); then
  mapfile -t PATHS_SORTED < <(printf '%s\n' "${PATHS[@]}" | sort -u)
fi
echo "Indexed ${#PATHS_SORTED[@]} file path(s) under scope."
echo

build_sync_ignore_maps

copy_file() {
  local src="$1" dest="$2"
  local label="$3"
  local tmp
  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ $NORMALIZE_LF -eq 1 ]] && should_normalize_lf "$src"; then
      echo "[dry-run] $label: LF-normalized copy $src -> $dest"
    else
      echo "[dry-run] $label: cp -p -- $src -> $dest"
    fi
    return 0
  fi
  ensure_mutating_sync_consent
  mkdir -p "$(dirname "$dest")"
  if [[ $NORMALIZE_LF -eq 1 ]] && should_normalize_lf "$src"; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/sync-cursor-roots.XXXXXX")
    sed 's/\r$//' < "$src" > "$tmp"
    mv -f -- "$tmp" "$dest"
    touch -r "$src" "$dest" 2>/dev/null || true
    echo "copied: $label (LF-normalized)"
  else
    cp -p -- "$src" "$dest"
    echo "copied: $label"
  fi
}

resolve_conflict() {
  local rel="$1" root1_f="$2" root2_f="$3"
  local choice
  while true; do
    echo >&2
    echo >&2 "Conflict: $rel"
    echo >&2 "  [1] keep root 1  ($root1_f)"
    echo >&2 "  [2] keep root 2 ($root2_f)"
    echo >&2 "  [3] skip (leave both as-is)"
    echo >&2 "  [d] show unified diff"
    read -r -p "Choose (1/2/3/d): " choice </dev/tty || true
    case "${choice:-}" in
      1) printf '%s\n' "$root1_f"; return 0 ;;
      2) printf '%s\n' "$root2_f"; return 0 ;;
      3) return 1 ;;
      d|D)
        if [[ -f "$root1_f" && -f "$root2_f" ]]; then
          if ((${#DIFF_COLOR_FLAG[@]})); then
            diff --color=always -u --strip-trailing-cr "$root1_f" "$root2_f" | sed -n '1,200p' >&2 || true
          else
            diff -u --strip-trailing-cr "$root1_f" "$root2_f" | sed -n '1,200p' >&2 || true
          fi
        else
          echo >&2 "(cannot diff: missing file)"
        fi
        ;;
      *) echo >&2 "Invalid choice." ;;
    esac
  done
}

sync_one() {
  local rel="$1"
  pair_paths "$rel"
  local root1_f="$PP_R1"
  local root2_f="$PP_R2"

  if [[ ! -f "$root1_f" && ! -f "$root2_f" ]]; then
    return 0
  fi

  if [[ -f "$root1_f" && ! -f "$root2_f" ]]; then
    if rel_blocked_1_to_2 "$rel"; then
      if [[ $DRY_RUN -eq 1 ]]; then
        dry_run_skip_ignore "SYNC_IGNORE_1_TO_2" "$rel"
      else
        skip_ignore_msg "root 1→root 2" "$rel"
      fi
      return 0
    fi
    copy_file "$root1_f" "$root2_f" "root 1 -> root 2 ($rel)"
    return 0
  fi

  if [[ ! -f "$root1_f" && -f "$root2_f" ]]; then
    if rel_blocked_2_to_1 "$rel"; then
      if [[ $DRY_RUN -eq 1 ]]; then
        dry_run_skip_ignore "SYNC_IGNORE_2_TO_1" "$rel"
      else
        skip_ignore_msg "root 2→root 1" "$rel"
      fi
      return 0
    fi
    copy_file "$root2_f" "$root1_f" "root 2 -> root 1 ($rel)"
    return 0
  fi

  if bytes_identical "$root1_f" "$root2_f"; then
    return 0
  fi
  if text_same_ignoring_cr "$root1_f" "$root2_f"; then
    # CRLF vs LF only: cmp differs but diff --strip-trailing-cr agrees; normalize listed text types
    # on both sides without requiring --normalize-lf so cross-mount skills/rules stay convergent.
    if should_normalize_lf "$root1_f"; then
      local ma mb src tmp label
      ma=$(mtime "$root1_f")
      mb=$(mtime "$root2_f")
      if [[ $ma -ge $mb ]]; then
        src=$root1_f
        label="EOL normalize (from root 1 mtime) -> both ($rel)"
      else
        src=$root2_f
        label="EOL normalize (from root 2 mtime) -> both ($rel)"
      fi
      if [[ "$src" == "$root2_f" ]] && rel_blocked_2_to_1 "$rel"; then
        if [[ $DRY_RUN -eq 1 ]]; then
          dry_run_skip_ignore "SYNC_IGNORE_2_TO_1" "$rel"
        else
          skip_ignore_msg "root 2→root 1 (LF-normalize)" "$rel"
        fi
        return 0
      fi
      if [[ "$src" == "$root1_f" ]] && rel_blocked_1_to_2 "$rel"; then
        if [[ $DRY_RUN -eq 1 ]]; then
          dry_run_skip_ignore "SYNC_IGNORE_1_TO_2" "$rel"
        else
          skip_ignore_msg "root 1→root 2 (LF-normalize)" "$rel"
        fi
        return 0
      fi
      if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] %s: LF-normalize %s -> %s and %s\n' "$label" "$src" "$root1_f" "$root2_f"
      else
        ensure_mutating_sync_consent
        tmp=$(mktemp "${TMPDIR:-/tmp}/sync-cursor-roots.XXXXXX")
        sed 's/\r$//' < "$src" > "$tmp"
        cp -f -- "$tmp" "$root1_f"
        cp -f -- "$tmp" "$root2_f"
        rm -f -- "$tmp"
        touch -r "$src" "$root1_f" 2>/dev/null || true
        touch -r "$src" "$root2_f" 2>/dev/null || true
        echo "normalized: $label"
      fi
    else
      [[ $VERBOSE -eq 1 ]] && echo "skip (EOL-only / CRLF vs LF): $rel"
    fi
    return 0
  fi

  local ma mb diff_t
  ma=$(mtime "$root1_f")
  mb=$(mtime "$root2_f")
  diff_t=$(( ma > mb ? ma - mb : mb - ma ))

  if [[ $diff_t -gt $TIE_SEC ]]; then
    if [[ $ma -gt $mb ]]; then
      if rel_blocked_1_to_2 "$rel"; then
        if [[ $DRY_RUN -eq 1 ]]; then
          dry_run_skip_ignore "SYNC_IGNORE_1_TO_2" "$rel"
        else
          skip_ignore_msg "root 1→root 2" "$rel"
        fi
        return 0
      fi
      copy_file "$root1_f" "$root2_f" "root 1 newer -> root 2 ($rel)"
    else
      if rel_blocked_2_to_1 "$rel"; then
        if [[ $DRY_RUN -eq 1 ]]; then
          dry_run_skip_ignore "SYNC_IGNORE_2_TO_1" "$rel"
        else
          skip_ignore_msg "root 2→root 1" "$rel"
        fi
        return 0
      fi
      copy_file "$root2_f" "$root1_f" "root 2 newer -> root 1 ($rel)"
    fi
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] conflict (mtime tie within --tie-sec, content differs): $rel" >&2
    echo "[dry-run]   root 1: $root1_f" >&2
    echo "[dry-run]   root 2: $root2_f" >&2
    echo "[dry-run]   Would prompt (keep root 1 / keep root 2 / skip); skipping - leaving both files unchanged." >&2
    echo "[dry-run]   Hint: run without --dry-run to choose, or adjust mtimes / use --tie-sec so the newer side wins." >&2
    return 0
  fi

  local winner
  if ! winner=$(resolve_conflict "$rel" "$root1_f" "$root2_f"); then
    return 0
  fi
  [[ -n "$winner" ]] || return 0

  if [[ "$winner" == "$root1_f" ]]; then
    if rel_blocked_1_to_2 "$rel"; then
      printf 'refused: chose root 1 but SYNC_IGNORE_1_TO_2 blocks copy to root 2: %s\n' "$rel" >&2
      return 0
    fi
    copy_file "$root1_f" "$root2_f" "resolved root 1 -> root 2 ($rel)"
  else
    if rel_blocked_2_to_1 "$rel"; then
      printf 'refused: chose root 2 but SYNC_IGNORE_2_TO_1 blocks copy to root 1: %s\n' "$rel" >&2
      return 0
    fi
    copy_file "$root2_f" "$root1_f" "resolved root 2 -> root 1 ($rel)"
  fi
}

ensure_pre_sync_consent_if_needed

create_missing_project_dirs

for rel in "${PATHS_SORTED[@]+"${PATHS_SORTED[@]}"}"; do
  sync_one "$rel"
done

# Uses Cursor Agent headless output (--print); prefers standalone `agent`, else `cursor agent`.
# Reads staged diff from disk so large patches do not overflow argv limits.
git_commit_msg_via_cursor_agent() {
  local repo_root="$1"
  local diff_file prompt agent_output line
  diff_file=$(mktemp "${TMPDIR:-/tmp}/sync-cursor-roots.staged-diff.XXXXXX")
  if ! git -C "$repo_root" diff --cached >"$diff_file" 2>/dev/null; then
    rm -f -- "$diff_file"
    return 1
  fi
  prompt="Read the UTF-8 unified git diff at this absolute path:
$diff_file

It is the current staged diff for this repo (Cursor rules/agents/skills under .cursor).

Output ONLY a git commit message following Conventional Commits:
- First line MUST be the subject: type(scope): imperative, lowercase description (about 72 chars or less).
- Use types such as chore, feat, fix, docs, refactor when appropriate; scope \"cursor\" unless something narrower fits.
- Do not add a body unless necessary; prefer subject line only.
- No markdown fences, no quotation marks around the message, no preamble or explanation — only the commit message text."

  if command -v agent >/dev/null 2>&1; then
    agent_output="$(agent --print --trust --mode ask --workspace "$repo_root" "$prompt")" || agent_output=""
  elif command -v cursor >/dev/null 2>&1; then
    agent_output="$(cursor agent --print --trust --mode ask --workspace "$repo_root" "$prompt")" || agent_output=""
  else
    rm -f -- "$diff_file"
    echo "warning: neither 'agent' nor 'cursor' on PATH; using fallback commit message" >&2
    return 1
  fi
  rm -f -- "$diff_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(trim "$line")
    [[ -z "$line" ]] && continue
    [[ "$line" == \`\`\`* ]] && continue
    [[ "$line" == \`\`\` ]] && continue
    printf '%s\n' "$line"
    return 0
  done <<<"$agent_output"

  echo "warning: Cursor agent returned no usable commit subject line; using fallback message" >&2
  return 1
}

git_add_sync_scope() {
  local f item sub
  for f in .gitignore .gitattributes; do
    if [[ -f "$f" ]]; then
      git add -- "$f"
    fi
  done
  for item in "${GLOBAL_ITEMS[@]}"; do
    if [[ "$item" == */ ]]; then
      sub="${item%/}"
      [[ -d "$sub" ]] || continue
      # agents/ and skills/ may be ignored by a managed .gitignore; -f keeps them staged.
      # Extra directories and files use -f for the same reason. rules/ stays a normal add.
      if [[ "$sub" == rules ]]; then
        git add -- "$sub"
      else
        git add -f -- "$sub"
      fi
    elif [[ -f "$item" ]]; then
      git add -f -- "$item"
    fi
  done
}

git_reset_sync_scope() {
  local item
  local specs=(.gitignore .gitattributes)
  for item in "${GLOBAL_ITEMS[@]}"; do
    specs+=("${item%/}")
  done
  git reset HEAD -- "${specs[@]}" 2>/dev/null || true
}

git_preview_staged_diffs() {
  local root name
  for root in "$ROOT1" "$ROOT2"; do
    if [[ "$root" == "$ROOT1" ]]; then
      name="root 1"
    else
      name="root 2"
    fi
    if [[ ! -d "$root/.git" ]]; then
      echo "=== git preview ($name): not a git repo — skip ==="
      echo
      continue
    fi
    (
      cd "$root" || exit 0
      if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        exit 0
      fi
      normalize_lf_in_sync_scope
      git_add_sync_scope
      if git diff --cached --quiet; then
        echo "=== git preview ($name): nothing staged after add (${GIT_SCOPE_LABEL}) ==="
      else
        echo "=== git preview ($name): git diff --cached (same paths as commit) ==="
        if [[ -n "${SYNC_DIFF_PAGER:-}" ]]; then
          git --no-pager diff --cached --color=always || true
        else
          git --no-pager diff --cached --color=auto || true
        fi
      fi
      git_reset_sync_scope
    )
    echo
  done
}

git_commit_push_one() {
  local root="$1" name="$2"
  if [[ ! -d "$root/.git" ]]; then
    echo "skip git ($name): not a git repo: $root"
    return 0
  fi
  (
    cd "$root" || exit 1
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "skip git ($name): $root"
      exit 0
    fi
    normalize_lf_in_sync_scope
    git_add_sync_scope
    if git diff --cached --quiet; then
      echo "git ($name): nothing to commit (${GIT_SCOPE_LABEL})"
      exit 0
    fi
    local msg="$COMMIT_MSG"
    if [[ -z "$msg" ]]; then
      if [[ $DRY_RUN -eq 1 ]]; then
        msg="(dry-run: would run Cursor agent --print --mode ask to propose Conventional Commits message)"
      elif ! msg=$(git_commit_msg_via_cursor_agent "$root"); then
        msg="chore(cursor): sync rules, agents, and skills"
      fi
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[dry-run] git ($name): would commit and push with message: $msg"
      git --no-pager diff --cached --stat --color=auto || true
      exit 0
    fi
    set +e
    if ! git commit -m "$msg"; then
      echo "git ($name): commit failed (resolve conflicts or inspect git status)" >&2
      exit 1
    fi
    if ! git push; then
      echo "git ($name): push failed (fix remote/auth and retry)" >&2
      exit 1
    fi
    set -e
    echo "git ($name): committed and pushed"
  )
}

if [[ $COMMIT_PUSH -eq 1 && $DO_GLOBAL -eq 0 ]]; then
  echo "note: --commit-push applies to the global roots only; skipped with --projects-only" >&2
  COMMIT_PUSH=0
fi

if [[ $COMMIT_PUSH -eq 1 ]]; then
  if [[ $DRY_RUN -eq 0 ]] && [[ $ASSUME_YES -eq 0 ]]; then
    if ! confirm_default_yes_with_diff 'Proceed with git commit and push? [Y/n/d]' git_preview_staged_diffs; then
      SKIP_GIT_COMMIT_PUSH=1
      echo 'Skipping git commit/push.' >&2
    fi
  fi
fi

if [[ $COMMIT_PUSH -eq 1 ]] && [[ $SKIP_GIT_COMMIT_PUSH -eq 0 ]]; then
  echo
  echo "=== git commit/push (${GIT_SCOPE_LABEL}) ==="
  git_commit_push_one "$ROOT1" "root 1" || true
  git_commit_push_one "$ROOT2" "root 2" || true
fi

echo
echo "Done."
