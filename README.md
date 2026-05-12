# sync-cursor-rules

Bash script that copies `rules/` and `agents/` between two `.cursor` directories (for example WSL `~/.cursor` and a Windows mount). When the same file exists on both sides and the bytes differ, it picks the newer file by modification time. Equal times within `--tie-sec` open an interactive pick.

## Git and `--commit-push`

`--commit-push` only makes sense when each root is already a git checkout (or contains one). The script `cd`s to the root path you pass, stages `rules/`, `agents/`, `.gitignore`, and `.gitattributes`, then commits and pushes. If there is no `.git` there, it prints a skip message and moves on.

## Quick start

```bash
chmod +x sync-cursor-rules.sh
./sync-cursor-rules.sh --dry-run
```

Defaults: WSL side `$HOME/.cursor`, Windows side `$HOME/winhome/.cursor`. Override with `CURSOR_WSL_ROOT`, `CURSOR_WIN_ROOT`, or `--wsl-root` / `--win-root`.

## Prompts

Without `-y` / `--yes`, the script asks before the first real copy and again before any git commit/push. `--dry-run` prints what would happen and touches nothing.

Full flags: `./sync-cursor-rules.sh --help`.
