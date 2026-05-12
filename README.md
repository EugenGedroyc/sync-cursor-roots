# sync-cursor-rules

Bash script that copies `rules/`, `agents/`, and `skills/` between two `.cursor` directories (for example WSL `~/.cursor` and a Windows mount). When the same file exists on both sides and the bytes differ, it picks the newer file by modification time. Equal times within `--tie-sec` open an interactive pick.

## Git and `--commit-push`

`--commit-push` only makes sense when each root is already a git checkout (or contains one). The script `cd`s to the root path you pass, stages `rules/`, `agents/`, `skills/`, `.gitignore`, and `.gitattributes`, then commits and pushes. If there is no `.git` there, it prints a skip message and moves on.

## Quick start

```bash
chmod +x sync-cursor-rules.sh
./sync-cursor-rules.sh --dry-run
```

Defaults: WSL side `$HOME/.cursor`, Windows side `$HOME/winhome/.cursor`. Override with `CURSOR_WSL_ROOT`, `CURSOR_WIN_ROOT`, or `--wsl-root` / `--win-root`.

## Directional ignores (`.env`)

Some files should only live on one machine. Set lists so the script never writes the wrong way.

- **`SYNC_IGNORE_WIN_TO_WSL`** — Colon-separated paths like `rules/powershell.mdc` or `rules/windows-grep.mdc`. Any step that would push **Windows → WSL** for that path is skipped (one-sided copy, “newer wins,” LF-normalize when the Windows file is the chosen source, or conflict resolution that would copy Windows into WSL).
- **`SYNC_IGNORE_WSL_TO_WIN`** — Same shape: blocks **WSL → Windows** for those paths.

Matching is exact on the path string (same form the script already uses). Spaces around each `:` segment are trimmed.

The script reads **`SCRIPT_DIR/.env`** next to `sync-cursor-rules.sh`, or the file named by **`SYNC_ENV_FILE`** if that path exists and is readable. It loads with `set -a` / `set +a` so variables export. If you already export **`SYNC_IGNORE_WIN_TO_WSL`** or **`SYNC_IGNORE_WSL_TO_WIN`** in your shell before running, those values are kept; the file cannot replace a non-empty value you set in the environment.

Commented samples: `.env.example` in this repo.

## Prompts

Without `-y` / `--yes`, the script asks before the first real copy and again before any git commit/push. `--dry-run` prints what would happen and touches nothing.

Full flags: `./sync-cursor-rules.sh --help`.
