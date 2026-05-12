#!/usr/bin/env bash
# Sync Cursor rules/, agents/, and skills/ between two .cursor roots (e.g. WSL vs Windows mount).
# Uses newer mtime when content differs; prompts when mtimes tie (or with --tie-sec).
#
# Cross-filesystem / line endings (QA):
# - A Windows .cursor dir is often NTFS reached from WSL via drvfs (df type "9p"). mtimes
#   can land in the same 1s bucket as ext4 files; use --tie-sec 1 or 2 if you see bad picks.
# - Working-tree bytes can still be CRLF on one side; comparisons treat CRLF vs LF as equal
#   (diff --strip-trailing-cr). Use --normalize-lf on copies so destinations are LF for text
#   extensions (.md/.mdc/.json/.yaml/.txt). Keep .gitattributes with eol=lf for those paths.
#
# Usage:
#   sync-cursor-rules.sh [options]
#
# Assumptions:
#   Each .cursor root should live inside a git repo if you use --commit-push.
#   The script runs git add/commit/push from that root for rules/, agents/, skills/,
#   .gitignore, and .gitattributes. Roots without .git are skipped for git.
#
# Environment (optional: $SCRIPT_DIR/.env, or a file named by SYNC_ENV_FILE):
#   SYNC_ENV_FILE              If set and this path is readable, source it (set -a); otherwise, if
#                              $SCRIPT_DIR/.env is readable, source that. No other paths are loaded.
#   SYNC_IGNORE_WIN_TO_WSL     Colon-separated repo-relative paths (e.g. rules/a.mdc); skip any
#                              copy or LF-normalize that would write Windows bytes into WSL.
#   SYNC_IGNORE_WSL_TO_WIN     Same for paths; skip copies/normalize that would write WSL bytes
#                              into the Windows tree. Non-empty shell exports for the two SYNC_IGNORE_*
#                              variables win over values from the file (see README).
#
# Options:
#   --dry-run                  Print planned actions only; no copies or git writes.
#                              No interactive prompts. When mtimes tie within --tie-sec
#                              but content differs, prints [dry-run] conflict lines and
#                              skips (no prompt).
#   -y, --yes                  Skip interactive confirmations before mutating sync and
#                              before git commit/push. Does not change conflict resolution:
#                              mtime ties with differing content still use the interactive
#                              menu unless --dry-run (which skips those conflicts).
#   --commit-push              After sync, git add/commit/push (rules/, agents/, skills/,
#                              gitignore, gitattributes). When not --dry-run, prompts before commit/push
#                              unless -y/--yes.
#   -m, --message TEXT         Commit message (default: auto)
#   --wsl-root PATH            Default: $CURSOR_WSL_ROOT or $HOME/.cursor
#   --win-root PATH            Default: $CURSOR_WIN_ROOT or $HOME/winhome/.cursor
#   --tie-sec N                If |mtime_a-mtime_b| <= N and content differs, prompt (default: 0)
#   --normalize-lf             When copying, strip CR for common text extensions (see script)
#   --verbose                  Log skips for CRLF-only differences
#   -h, --help                 Show help
#
# Interactive prompts (tty; use -y/--yes if unavailable):
#   Do you want to continue? [Y/n/d] — before mutating sync (impact summary first).
#   Y / empty / yes: proceed; n / no: exit 0; d: full unified diffs, then re-prompt.
#   Proceed with git commit and push? [Y/n/d] — same; d runs a per-root staged diff preview.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Optional .env: export all assigned vars. Pre-set SYNC_IGNORE_* in the shell to override file values.
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
  local _pre_w _pre_l
  _pre_w="${SYNC_IGNORE_WIN_TO_WSL-}"
  _pre_l="${SYNC_IGNORE_WSL_TO_WIN-}"
  set -a
  # shellcheck disable=SC1090
  source "$env_path"
  set +a
  [[ -n "$_pre_w" ]] && SYNC_IGNORE_WIN_TO_WSL="$_pre_w"
  [[ -n "$_pre_l" ]] && SYNC_IGNORE_WSL_TO_WIN="$_pre_l"
}

load_sync_env_file

DRY_RUN=0
ASSUME_YES=0
COMMIT_PUSH=0
COMMIT_MSG=""
TIE_SEC=0
NORMALIZE_LF=0
VERBOSE=0
WSL_ROOT="${CURSOR_WSL_ROOT:-$HOME/.cursor}"
WIN_ROOT="${CURSOR_WIN_ROOT:-$HOME/winhome/.cursor}"
# Set to 1 after the first successful mutating-sync confirmation (copies / LF-normalize to both).
SYNC_WRITE_CONSENTED=0
SKIP_GIT_COMMIT_PUSH=0
# Basenames under each .cursor root to scan for files and to stage on --commit-push.
SYNC_SUBDIRS=(rules agents skills)

die() { echo "error: $*" >&2; exit 1; }

# GNU diffutils 3.4+: color when stdout is a tty (--color=auto). Ignored on older diff.
DIFF_COLOR_FLAG=()
if diff --color=auto -u /dev/null /dev/null >/dev/null 2>&1; then
  DIFF_COLOR_FLAG=(--color=auto)
fi

# Unified diff with CRLF ignored; optional color (see DIFF_COLOR_FLAG).
diff_unified() {
  diff "${DIFF_COLOR_FLAG[@]}" -u --strip-trailing-cr "$@" || true
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
      d|D) "$show_diff_cmd" ;;
      *) printf 'Please answer y, n, or d (default yes).\n' >/dev/tty ;;
    esac
  done
}

# Populated by build_sync_ignore_maps() from SYNC_IGNORE_* (colon-separated rel paths).
declare -A SYNC_IGNORE_WIN_TO_WSL_MAP=()
declare -A SYNC_IGNORE_WSL_TO_WIN_MAP=()

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
  fill_ignore_map_from_var "${SYNC_IGNORE_WIN_TO_WSL-}" SYNC_IGNORE_WIN_TO_WSL_MAP
  fill_ignore_map_from_var "${SYNC_IGNORE_WSL_TO_WIN-}" SYNC_IGNORE_WSL_TO_WIN_MAP
}

rel_blocked_win_to_wsl() {
  [[ -n "${SYNC_IGNORE_WIN_TO_WSL_MAP[$1]+x}" ]]
}

rel_blocked_wsl_to_win() {
  [[ -n "${SYNC_IGNORE_WSL_TO_WIN_MAP[$1]+x}" ]]
}

# stdout: [dry-run] lines (match other dry-run copy messages).
dry_run_skip_ignore() {
  local which="$1" rel="$2"
  printf '[dry-run] skipped (%s): %s\n' "$which" "$rel"
}

# Non-dry: align with --verbose skips (e.g. EOL-only).
skip_ignore_msg() {
  local tag="$1" rel="$2"
  [[ $VERBOSE -eq 1 ]] && printf 'skip (ignored %s): %s\n' "$tag" "$rel" >&2
}

normalize_src_for_pair() {
  local wsl_f="$1" win_f="$2"
  local ma mb
  ma=$(mtime "$wsl_f")
  mb=$(mtime "$win_f")
  if [[ $ma -ge $mb ]]; then
    printf '%s\n' "$wsl_f"
  else
    printf '%s\n' "$win_f"
  fi
}

# Populate PLAN_* arrays; mirrors sync_one decisions (DRY_RUN must be off; tie → PLAN_TIE).
plan_sync_one() {
  local rel="$1"
  local wsl_f="$WSL_ROOT/$rel"
  local win_f="$WIN_ROOT/$rel"

  if [[ ! -f "$wsl_f" && ! -f "$win_f" ]]; then
    return 0
  fi

  if [[ -f "$wsl_f" && ! -f "$win_f" ]]; then
    if rel_blocked_wsl_to_win "$rel"; then
      return 0
    fi
    PLAN_COPY_TO_WIN+=("$rel")
    return 0
  fi

  if [[ ! -f "$wsl_f" && -f "$win_f" ]]; then
    if rel_blocked_win_to_wsl "$rel"; then
      return 0
    fi
    PLAN_COPY_TO_WSL+=("$rel")
    return 0
  fi

  if bytes_identical "$wsl_f" "$win_f"; then
    return 0
  fi
  if text_same_ignoring_cr "$wsl_f" "$win_f"; then
    if [[ $NORMALIZE_LF -eq 1 ]] && should_normalize_lf "$wsl_f"; then
      local ma0 mb0 src0
      ma0=$(mtime "$wsl_f")
      mb0=$(mtime "$win_f")
      if [[ $ma0 -ge $mb0 ]]; then
        src0=$wsl_f
      else
        src0=$win_f
      fi
      if [[ "$src0" == "$win_f" ]] && rel_blocked_win_to_wsl "$rel"; then
        return 0
      fi
      if [[ "$src0" == "$wsl_f" ]] && rel_blocked_wsl_to_win "$rel"; then
        return 0
      fi
      PLAN_NORMALIZE+=("$rel")
    fi
    return 0
  fi

  local ma mb diff_t
  ma=$(mtime "$wsl_f")
  mb=$(mtime "$win_f")
  diff_t=$(( ma > mb ? ma - mb : mb - ma ))

  if [[ $diff_t -gt $TIE_SEC ]]; then
    if [[ $ma -gt $mb ]]; then
      if rel_blocked_wsl_to_win "$rel"; then
        return 0
      fi
      PLAN_COPY_TO_WIN+=("$rel")
    else
      if rel_blocked_win_to_wsl "$rel"; then
        return 0
      fi
      PLAN_COPY_TO_WSL+=("$rel")
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
  local rel wsl_f win_f src tmp
  for rel in "${PLAN_COPY_TO_WIN[@]+"${PLAN_COPY_TO_WIN[@]}"}"; do
    wsl_f="$WSL_ROOT/$rel"
    win_f="$WIN_ROOT/$rel"
    echo "=== copy → Windows: $rel ==="
    diff_copy_to_dest "$win_f" "$wsl_f" "OLD (Windows: $win_f)" "NEW (WSL → Windows: $wsl_f)"
    echo
  done
  for rel in "${PLAN_COPY_TO_WSL[@]+"${PLAN_COPY_TO_WSL[@]}"}"; do
    wsl_f="$WSL_ROOT/$rel"
    win_f="$WIN_ROOT/$rel"
    echo "=== copy → WSL: $rel ==="
    diff_copy_to_dest "$wsl_f" "$win_f" "OLD (WSL: $wsl_f)" "NEW (Windows → WSL: $win_f)"
    echo
  done
  for rel in "${PLAN_NORMALIZE[@]+"${PLAN_NORMALIZE[@]}"}"; do
    wsl_f="$WSL_ROOT/$rel"
    win_f="$WIN_ROOT/$rel"
    src=$(normalize_src_for_pair "$wsl_f" "$win_f")
    echo "=== LF-normalize → both: $rel (chosen src: $src) ==="
    tmp=$(mktemp "${TMPDIR:-/tmp}/sync-cursor-rules.pre-diff.XXXXXX")
    sed 's/\r$//' < "$src" > "$tmp"
    if ! cmp -s "$wsl_f" "$tmp" 2>/dev/null; then
      diff_unified -L "WSL (current): $wsl_f" -L "normalized (proposal)" "$wsl_f" "$tmp"
      echo
    fi
    if ! cmp -s "$win_f" "$tmp" 2>/dev/null; then
      diff_unified -L "Windows (current): $win_f" -L "normalized (proposal)" "$win_f" "$tmp"
      echo
    fi
    rm -f -- "$tmp"
    echo
  done
  for rel in "${PLAN_TIE[@]+"${PLAN_TIE[@]}"}"; do
    wsl_f="$WSL_ROOT/$rel"
    win_f="$WIN_ROOT/$rel"
    echo "=== mtime tie / conflict (--tie-sec $TIE_SEC): $rel ==="
    if [[ -f "$wsl_f" && -f "$win_f" ]]; then
      diff_unified -L "WSL: $wsl_f" -L "Windows: $win_f" "$wsl_f" "$win_f"
    else
      echo "(cannot diff: missing file)"
    fi
    echo
  done
}

print_sync_impact_summary() {
  local nw nl nt nn
  nw=${#PLAN_COPY_TO_WIN[@]}
  nl=${#PLAN_COPY_TO_WSL[@]}
  nn=${#PLAN_NORMALIZE[@]}
  nt=${#PLAN_TIE[@]}
  echo "Upcoming sync (this run):"
  if ((nw)); then
    echo "  Copy → Windows ($nw):"
    local r
    for r in "${PLAN_COPY_TO_WIN[@]}"; do echo "    $r"; done
  fi
  if ((nl)); then
    echo "  Copy → WSL ($nl):"
    local r2
    for r2 in "${PLAN_COPY_TO_WSL[@]}"; do echo "    $r2"; done
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
  echo
}

ensure_pre_sync_consent_if_needed() {
  if [[ $DRY_RUN -eq 1 ]] || [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi

  PLAN_COPY_TO_WIN=()
  PLAN_COPY_TO_WSL=()
  PLAN_NORMALIZE=()
  PLAN_TIE=()
  local rel
  for rel in "${PATHS_SORTED[@]+"${PATHS_SORTED[@]}"}"; do
    plan_sync_one "$rel"
  done

  local total_mut total_tie
  total_mut=$((${#PLAN_COPY_TO_WIN[@]} + ${#PLAN_COPY_TO_WSL[@]} + ${#PLAN_NORMALIZE[@]}))
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
    --wsl-root)
      [[ $# -ge 2 ]] || die "--wsl-root requires a path"
      WSL_ROOT="$2"
      shift
      ;;
    --win-root)
      [[ $# -ge 2 ]] || die "--win-root requires a path"
      WIN_ROOT="$2"
      shift
      ;;
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

[[ -d "$WSL_ROOT" ]] || die "WSL root not a directory: $WSL_ROOT"
[[ -d "$WIN_ROOT" ]] || die "Windows root not a directory: $WIN_ROOT"

resolve_root() {
  local p="$1"
  readlink -f "$p" 2>/dev/null || echo "$p"
}

WSL_CFG=$WSL_ROOT
WIN_CFG=$WIN_ROOT
WSL_ROOT=$(resolve_root "$WSL_ROOT")
WIN_ROOT=$(resolve_root "$WIN_ROOT")

fs_type() {
  df -T "$1" 2>/dev/null | awk 'NR==2 {print $2}'
}

maybe_warn_drvfs() {
  local root="$1" label="$2"
  local t
  t=$(fs_type "$root")
  if [[ "$t" == "9p" ]]; then
    echo "note: $label .cursor is on WSL drvfs/9p ($root)." >&2
    echo "      Same-second mtimes happen across ext4<->drvfs; try --tie-sec 1 or 2 if picks look wrong." >&2
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

collect_relpaths() {
  local root="$1"
  local sub
  for sub in "${SYNC_SUBDIRS[@]}"; do
    if [[ -d "$root/$sub" ]]; then
      find "$root/$sub" -type f -print0 2>/dev/null
    fi
  done
}

declare -A SEEN_PATHS
PATHS=()

while IFS= read -r -d '' f; do
  rel="${f#"$WSL_ROOT"/}"
  if [[ -n "$rel" && "$rel" != "$f" ]]; then
    if [[ -z "${SEEN_PATHS[$rel]+x}" ]]; then
      SEEN_PATHS[$rel]=1
      PATHS+=("$rel")
    fi
  fi
done < <(collect_relpaths "$WSL_ROOT")

while IFS= read -r -d '' f; do
  rel="${f#"$WIN_ROOT"/}"
  if [[ -n "$rel" && "$rel" != "$f" ]]; then
    if [[ -z "${SEEN_PATHS[$rel]+x}" ]]; then
      SEEN_PATHS[$rel]=1
      PATHS+=("$rel")
    fi
  fi
done < <(collect_relpaths "$WIN_ROOT")

PATHS_SORTED=()
if ((${#PATHS[@]})); then
  mapfile -t PATHS_SORTED < <(printf '%s\n' "${PATHS[@]}" | sort -u)
fi

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
    tmp=$(mktemp "${TMPDIR:-/tmp}/sync-cursor-rules.XXXXXX")
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
  local rel="$1" wsl_f="$2" win_f="$3"
  local choice
  while true; do
    echo >&2
    echo >&2 "Conflict: $rel"
    echo >&2 "  [1] keep WSL  ($wsl_f)"
    echo >&2 "  [2] keep Windows ($win_f)"
    echo >&2 "  [3] skip (leave both as-is)"
    echo >&2 "  [d] show unified diff"
    read -r -p "Choose (1/2/3/d): " choice </dev/tty || true
    case "${choice:-}" in
      1) printf '%s\n' "$wsl_f"; return 0 ;;
      2) printf '%s\n' "$win_f"; return 0 ;;
      3) return 1 ;;
      d|D)
        if [[ -f "$wsl_f" && -f "$win_f" ]]; then
          if ((${#DIFF_COLOR_FLAG[@]})); then
            diff --color=always -u --strip-trailing-cr "$wsl_f" "$win_f" | sed -n '1,200p' >&2 || true
          else
            diff -u --strip-trailing-cr "$wsl_f" "$win_f" | sed -n '1,200p' >&2 || true
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
  local wsl_f="$WSL_ROOT/$rel"
  local win_f="$WIN_ROOT/$rel"

  if [[ ! -f "$wsl_f" && ! -f "$win_f" ]]; then
    return 0
  fi

  if [[ -f "$wsl_f" && ! -f "$win_f" ]]; then
    if rel_blocked_wsl_to_win "$rel"; then
      if [[ $DRY_RUN -eq 1 ]]; then
        dry_run_skip_ignore "SYNC_IGNORE_WSL_TO_WIN" "$rel"
      else
        skip_ignore_msg "WSL→Windows" "$rel"
      fi
      return 0
    fi
    copy_file "$wsl_f" "$win_f" "WSL -> Windows ($rel)"
    return 0
  fi

  if [[ ! -f "$wsl_f" && -f "$win_f" ]]; then
    if rel_blocked_win_to_wsl "$rel"; then
      if [[ $DRY_RUN -eq 1 ]]; then
        dry_run_skip_ignore "SYNC_IGNORE_WIN_TO_WSL" "$rel"
      else
        skip_ignore_msg "WIN→WSL" "$rel"
      fi
      return 0
    fi
    copy_file "$win_f" "$wsl_f" "Windows -> WSL ($rel)"
    return 0
  fi

  if bytes_identical "$wsl_f" "$win_f"; then
    return 0
  fi
  if text_same_ignoring_cr "$wsl_f" "$win_f"; then
    if [[ $NORMALIZE_LF -eq 1 ]] && should_normalize_lf "$wsl_f"; then
      local ma mb src tmp label
      ma=$(mtime "$wsl_f")
      mb=$(mtime "$win_f")
      if [[ $ma -ge $mb ]]; then
        src=$wsl_f
        label="EOL normalize (from WSL mtime) -> both ($rel)"
      else
        src=$win_f
        label="EOL normalize (from Windows mtime) -> both ($rel)"
      fi
      if [[ "$src" == "$win_f" ]] && rel_blocked_win_to_wsl "$rel"; then
        if [[ $DRY_RUN -eq 1 ]]; then
          dry_run_skip_ignore "SYNC_IGNORE_WIN_TO_WSL" "$rel"
        else
          skip_ignore_msg "WIN→WSL (LF-normalize)" "$rel"
        fi
        return 0
      fi
      if [[ "$src" == "$wsl_f" ]] && rel_blocked_wsl_to_win "$rel"; then
        if [[ $DRY_RUN -eq 1 ]]; then
          dry_run_skip_ignore "SYNC_IGNORE_WSL_TO_WIN" "$rel"
        else
          skip_ignore_msg "WSL→Windows (LF-normalize)" "$rel"
        fi
        return 0
      fi
      if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] %s: LF-normalize %s -> %s and %s\n' "$label" "$src" "$wsl_f" "$win_f"
      else
        ensure_mutating_sync_consent
        tmp=$(mktemp "${TMPDIR:-/tmp}/sync-cursor-rules.XXXXXX")
        sed 's/\r$//' < "$src" > "$tmp"
        cp -f -- "$tmp" "$wsl_f"
        cp -f -- "$tmp" "$win_f"
        rm -f -- "$tmp"
        touch -r "$src" "$wsl_f" 2>/dev/null || true
        touch -r "$src" "$win_f" 2>/dev/null || true
        echo "normalized: $label"
      fi
    else
      [[ $VERBOSE -eq 1 ]] && echo "skip (EOL-only / CRLF vs LF): $rel"
    fi
    return 0
  fi

  local ma mb diff_t
  ma=$(mtime "$wsl_f")
  mb=$(mtime "$win_f")
  diff_t=$(( ma > mb ? ma - mb : mb - ma ))

  if [[ $diff_t -gt $TIE_SEC ]]; then
    if [[ $ma -gt $mb ]]; then
      if rel_blocked_wsl_to_win "$rel"; then
        if [[ $DRY_RUN -eq 1 ]]; then
          dry_run_skip_ignore "SYNC_IGNORE_WSL_TO_WIN" "$rel"
        else
          skip_ignore_msg "WSL→Windows" "$rel"
        fi
        return 0
      fi
      copy_file "$wsl_f" "$win_f" "WSL newer -> Windows ($rel)"
    else
      if rel_blocked_win_to_wsl "$rel"; then
        if [[ $DRY_RUN -eq 1 ]]; then
          dry_run_skip_ignore "SYNC_IGNORE_WIN_TO_WSL" "$rel"
        else
          skip_ignore_msg "WIN→WSL" "$rel"
        fi
        return 0
      fi
      copy_file "$win_f" "$wsl_f" "Windows newer -> WSL ($rel)"
    fi
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] conflict (mtime tie within --tie-sec, content differs): $rel" >&2
    echo "[dry-run]   WSL:      $wsl_f" >&2
    echo "[dry-run]   Windows:  $win_f" >&2
    echo "[dry-run]   Would prompt (keep WSL / keep Windows / skip); skipping - leaving both files unchanged." >&2
    echo "[dry-run]   Hint: run without --dry-run to choose, or adjust mtimes / use --tie-sec so the newer side wins." >&2
    return 0
  fi

  local winner
  if ! winner=$(resolve_conflict "$rel" "$wsl_f" "$win_f"); then
    return 0
  fi
  [[ -n "$winner" ]] || return 0

  if [[ "$winner" == "$wsl_f" ]]; then
    if rel_blocked_wsl_to_win "$rel"; then
      printf 'refused: resolved to WSL but SYNC_IGNORE_WSL_TO_WIN blocks copy to Windows: %s\n' "$rel" >&2
      return 0
    fi
    copy_file "$wsl_f" "$win_f" "resolved WSL -> Windows ($rel)"
  else
    if rel_blocked_win_to_wsl "$rel"; then
      printf 'refused: resolved to Windows but SYNC_IGNORE_WIN_TO_WSL blocks copy to WSL: %s\n' "$rel" >&2
      return 0
    fi
    copy_file "$win_f" "$wsl_f" "resolved Windows -> WSL ($rel)"
  fi
}

echo "WSL root:     $WSL_ROOT"
[[ "$WSL_CFG" != "$WSL_ROOT" ]] && echo "  (from $WSL_CFG)"
echo "Windows root: $WIN_ROOT"
[[ "$WIN_CFG" != "$WIN_ROOT" ]] && echo "  (from $WIN_CFG)"
echo "Scope:        rules/ agents/ skills/"
[[ $NORMALIZE_LF -eq 1 ]] && echo "Normalize:    LF strip on copy for .md/.mdc/.json/.yaml/.txt"
[[ $DRY_RUN -eq 1 ]] && echo "Mode:         dry-run"
maybe_warn_drvfs "$WSL_ROOT" "WSL"
maybe_warn_drvfs "$WIN_ROOT" "Windows"
echo

ensure_pre_sync_consent_if_needed

for rel in "${PATHS_SORTED[@]+"${PATHS_SORTED[@]}"}"; do
  sync_one "$rel"
done

git_preview_staged_diffs() {
  local root name
  for root in "$WSL_ROOT" "$WIN_ROOT"; do
    if [[ "$root" == "$WSL_ROOT" ]]; then
      name="WSL"
    else
      name="Windows"
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
      local f sub
      for f in .gitignore .gitattributes; do
        if [[ -f "$f" ]]; then
          git add -- "$f"
        fi
      done
      for sub in "${SYNC_SUBDIRS[@]}"; do
        if [[ -d "$sub" ]]; then
          if [[ "$sub" == agents || "$sub" == skills ]]; then
            git add -f -- "$sub"
          else
            git add -- "$sub"
          fi
        fi
      done
      if git diff --cached --quiet; then
        echo "=== git preview ($name): nothing staged after add (rules, agents, skills, gitignore/attributes) ==="
      else
        echo "=== git preview ($name): git diff --cached (same paths as commit) ==="
        git --no-pager diff --cached --color=auto || true
      fi
      git reset HEAD -- .gitignore .gitattributes "${SYNC_SUBDIRS[@]}" 2>/dev/null || true
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
    for f in .gitignore .gitattributes; do
      if [[ -f "$f" ]]; then
        git add -- "$f"
      fi
    done
    local sub
    for sub in "${SYNC_SUBDIRS[@]}"; do
      if [[ -d "$sub" ]]; then
        # agents/ and skills/ may be ignored by a managed .gitignore; -f keeps them staged.
        if [[ "$sub" == agents || "$sub" == skills ]]; then
          git add -f -- "$sub"
        else
          git add -- "$sub"
        fi
      fi
    done
    if git diff --cached --quiet; then
      echo "git ($name): nothing to commit (rules, agents, skills, gitignore/attributes)"
      exit 0
    fi
    local msg="$COMMIT_MSG"
    if [[ -z "$msg" ]]; then
      msg="chore(cursor): sync rules, agents, and skills"
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
  echo "=== git commit/push (rules, agents, skills, gitignore/attributes) ==="
  git_commit_push_one "$WSL_ROOT" "WSL" || true
  git_commit_push_one "$WIN_ROOT" "Windows" || true
fi

echo
echo "Done."
