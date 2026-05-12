#!/usr/bin/env bash
# Sync Cursor rules/ and agents/ between two .cursor roots (e.g. WSL vs Windows mount).
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
# Options:
#   --dry-run              Print planned actions only; no copies or git writes.
#                          When mtimes tie within --tie-sec but content differs,
#                          prints [dry-run] conflict lines and skips (no prompt).
#   --commit-push          After sync, git add/commit/push (rules/, agents/, .gitignore, .gitattributes)
#   -m, --message TEXT     Commit message (default: auto)
#   --wsl-root PATH        Default: $CURSOR_WSL_ROOT or $HOME/.cursor
#   --win-root PATH        Default: $CURSOR_WIN_ROOT or $HOME/winhome/.cursor
#   --tie-sec N            If |mtime_a-mtime_b| <= N and content differs, prompt (default: 0)
#   --normalize-lf        When copying, strip CR for common text extensions (see script)
#   --verbose               Log skips for CRLF-only differences
#   -h, --help             Show help

set -euo pipefail

DRY_RUN=0
COMMIT_PUSH=0
COMMIT_MSG=""
TIE_SEC=0
NORMALIZE_LF=0
VERBOSE=0
WSL_ROOT="${CURSOR_WSL_ROOT:-$HOME/.cursor}"
WIN_ROOT="${CURSOR_WIN_ROOT:-$HOME/winhome/.cursor}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  sed -n '2,/^[^#]/p' "$0" | sed '/^[^#]/d' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
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
  for sub in rules agents; do
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
          diff -u --strip-trailing-cr "$wsl_f" "$win_f" | sed -n '1,200p' >&2 || true
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
    copy_file "$wsl_f" "$win_f" "WSL -> Windows ($rel)"
    return 0
  fi

  if [[ ! -f "$wsl_f" && -f "$win_f" ]]; then
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
      if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] %s: LF-normalize %s -> %s and %s\n' "$label" "$src" "$wsl_f" "$win_f"
      else
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
      copy_file "$wsl_f" "$win_f" "WSL newer -> Windows ($rel)"
    else
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
    copy_file "$wsl_f" "$win_f" "resolved WSL -> Windows ($rel)"
  else
    copy_file "$win_f" "$wsl_f" "resolved Windows -> WSL ($rel)"
  fi
}

echo "WSL root:     $WSL_ROOT"
[[ "$WSL_CFG" != "$WSL_ROOT" ]] && echo "  (from $WSL_CFG)"
echo "Windows root: $WIN_ROOT"
[[ "$WIN_CFG" != "$WIN_ROOT" ]] && echo "  (from $WIN_CFG)"
echo "Scope:        rules/ agents/"
[[ $NORMALIZE_LF -eq 1 ]] && echo "Normalize:    LF strip on copy for .md/.mdc/.json/.yaml/.txt"
[[ $DRY_RUN -eq 1 ]] && echo "Mode:         dry-run"
maybe_warn_drvfs "$WSL_ROOT" "WSL"
maybe_warn_drvfs "$WIN_ROOT" "Windows"
echo

for rel in "${PATHS_SORTED[@]+"${PATHS_SORTED[@]}"}"; do
  sync_one "$rel"
done

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
    for sub in rules agents; do
      if [[ -d "$sub" ]]; then
        # agents/ must stay tracked even if the managed .gitignore block drops !agents/ on disk
        if [[ "$sub" == agents ]]; then
          git add -f -- "$sub"
        else
          git add -- "$sub"
        fi
      fi
    done
    if git diff --cached --quiet; then
      echo "git ($name): nothing to commit (rules, agents, gitignore/attributes)"
      exit 0
    fi
    local msg="$COMMIT_MSG"
    if [[ -z "$msg" ]]; then
      msg="chore(cursor): sync rules and agents"
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[dry-run] git ($name): would commit and push with message: $msg"
      git diff --cached --stat || true
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
  echo
  echo "=== git commit/push (rules, agents, gitignore/attributes) ==="
  git_commit_push_one "$WSL_ROOT" "WSL" || true
  git_commit_push_one "$WIN_ROOT" "Windows" || true
fi

echo
echo "Done."
