# sync-cursor-roots

Bash script that copies `rules/`, `agents/`, and `skills/` between two `.cursor` directories you name as **cursor root 1** and **cursor root 2** (for example two machines or two mounts). When the same file exists on both sides and the bytes differ, it picks the newer file by modification time. Equal times within `--tie-sec` open an interactive pick.

## Git and `--commit-push`

`--commit-push` only makes sense when each root is already a git checkout (or contains one). The script `cd`s to the root path you pass, stages `rules/`, `agents/`, `skills/`, `.gitignore`, and `.gitattributes`, then commits and pushes. If there is no `.git` there, it prints a skip message and moves on.

## Quick start

```bash
chmod +x sync-cursor-roots.sh
export CURSOR_ROOT_2=/path/to/other/.cursor   # required unless set in .env
./sync-cursor-roots.sh --dry-run
```

**Cursor root 1** defaults to `$HOME/.cursor` when `CURSOR_ROOT_1` is unset. **Cursor root 2** has no default: set `CURSOR_ROOT_2` in `SCRIPT_DIR/.env` (or `SYNC_ENV_FILE`), or pass `--root-2 PATH`. Override root 1 with `CURSOR_ROOT_1` or `--root-1 PATH`.

## Directional ignores (`.env`)

Some files should only live on one side. Set lists so the script never writes the wrong way.

- **`SYNC_IGNORE_2_TO_1`** — Colon-separated paths like `rules/machine-a.mdc`. Any step that would push **root 2 → root 1** for that path is skipped (one-sided copy, “newer wins,” LF-normalize when root 2 is the chosen source, or conflict resolution that would copy root 2 into root 1).
- **`SYNC_IGNORE_1_TO_2`** — Same shape: blocks **root 1 → root 2** for those paths.

Matching is exact on the path string (same form the script already uses). Spaces around each `:` segment are trimmed.

The script reads **`SCRIPT_DIR/.env`** next to `sync-cursor-roots.sh`, or the file named by **`SYNC_ENV_FILE`** if that path exists and is readable. It loads with `set -a` / `set +a` so variables export. If you already export **`SYNC_IGNORE_2_TO_1`** or **`SYNC_IGNORE_1_TO_2`** in your shell before running, those values are kept; the file cannot replace a non-empty value you set in the environment.

Commented samples: `.env.example` in this repo.

## Prompts

Without `-y` / `--yes`, the script asks before the first real copy and again before any git commit/push. `--dry-run` prints what would happen and touches nothing.

Full flags: `./sync-cursor-roots.sh --help`.
