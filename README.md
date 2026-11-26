# sync-cursor-roots

Keep your Cursor setup in sync across machines. If you use Cursor on more than one box (laptop and desktop, host and VM, Linux and a 9p-mounted Windows share), your `rules/`, `agents/`, and `skills/` drift apart fast. Editing on one side, then forgetting which side is newer, is the usual way to lose work.

This is a bash script that copies `rules/`, `agents/`, and `skills/` between two `.cursor` directories you name as **cursor root 1** and **cursor root 2**. When the same file exists on both sides and the bytes differ, it picks the newer file by modification time. Equal times within `--tie-sec` open an interactive pick.

The same rules can also keep project-level `.cursor` folders aligned with a settings repo. That path is off unless you list pairs. See [Project sync](#project-sync).

## Example: Windows + WSL

A common setup: Cursor runs both on Windows (against `C:\Users\you\.cursor`) and inside WSL (against `/home/you/.cursor`). Each root is its own git checkout, pushing to the same remote. Cursor writes its own `.gitignore` in each root and keeps it current, so only `rules/`, `agents/`, `skills/`, `.gitignore`, and `.gitattributes` are tracked. Everything else Cursor drops in `.cursor/` (chats, caches, logs, sockets) stays ignored.

```text
C:\Users\you\.cursor          <- git repo, remote = origin
/home/you/.cursor             <- git repo, remote = origin (same remote)
```

Run the script from either side with `CURSOR_ROOT_2` pointing at the other (via the 9p mount in WSL, e.g. `/mnt/c/Users/you/.cursor`).

### Why not just `git pull` between the two roots?

You can, but it hurts in practice:

- **Cursor rewrites `.gitignore`.** Both sides edit the same file at unpredictable times. Every sync becomes a merge conflict on a file you didn't touch.
- **Two checkouts, one remote, constant rebasing.** To move a change from machine A to machine B with git alone you commit on A, push, then pull on B. Forget the order and you get diverged history on config files. Local-to-local copy avoids the round trip and works offline.
- **Per-machine files.** Some rules belong only on one side (machine-specific paths, OS-specific shell rules). `SYNC_IGNORE_1_TO_2` / `SYNC_IGNORE_2_TO_1` block those at the copy step. Git would either sync them or need a second ignore mechanism on top.
- **Runtime churn in `.cursor/`.** Cursor writes a lot of files you never want in a commit. Treating the whole `.cursor/` as a repo invites mistakes; this script only touches the three folders that matter.

Use git for the long-term history of your rules. Use this script to keep the two working copies aligned day to day.

## Git and `--commit-push`

`--commit-push` only works when each root is a git checkout (or contains one). The script `cd`s to the root path you pass, stages `rules/`, `agents/`, `skills/`, `.gitignore`, and `.gitattributes`, then commits and pushes. If there is no `.git` there, it prints a skip message and moves on.

## Quick start

```bash
chmod +x sync-cursor-roots.sh
export CURSOR_ROOT_2=/path/to/other/.cursor   # required unless set in .env
./sync-cursor-roots.sh --dry-run
```

**Cursor root 1** defaults to `$HOME/.cursor` when `CURSOR_ROOT_1` is unset. **Cursor root 2** has no default: set `CURSOR_ROOT_2` in `SCRIPT_DIR/.env` (or `SYNC_ENV_FILE`), or pass `--root-2 PATH`. Override root 1 with `CURSOR_ROOT_1` or `--root-1 PATH`.

## Directional ignores (`.env`)

Some files should only live on one side. Set lists so the script never writes the wrong way.

- **`SYNC_IGNORE_2_TO_1`** — Colon-separated paths like `rules/machine-a.mdc`. Any step that would push **root 2 → root 1** for that path is skipped (one-sided copy, "newer wins", LF-normalize when root 2 is the chosen source, or conflict resolution that would copy root 2 into root 1).
- **`SYNC_IGNORE_1_TO_2`** — Same shape: blocks **root 1 → root 2** for those paths.

Matching is exact on the path string (same form the script already uses). Spaces around each `:` segment are trimmed.

The script reads **`SCRIPT_DIR/.env`** next to `sync-cursor-roots.sh`, or the file named by **`SYNC_ENV_FILE`** if that path exists and is readable. It loads with `set -a` / `set +a` so variables export. If you already export **`SYNC_IGNORE_2_TO_1`** or **`SYNC_IGNORE_1_TO_2`** in your shell before running, those values are kept; the file cannot replace a non-empty value you set in the environment.

See `.env.example` for commented samples.

## Project sync

Global sync only touches the two `.cursor` roots. Project sync is a separate list of pairs: each pair is one project's `.cursor` directory on side 1 and the matching folder on side 2 (often a directory inside a settings repo, and that folder does not have to be named `.cursor`).

### Config

`SYNC_PROJECTS` is newline-separated or `;`-separated. Each entry is `name|side1|side2`. Blank lines and lines that start with `#` are ignored. `name` is the label used in ignore paths (`[A-Za-z0-9._-]+`), not a path.

```bash
SYNC_PROJECTS='
# checkout .cursor  ->  folder in the settings repo
my-app|C:/Users/you/code/my-app/.cursor|D:/cursor-config/projects/my-app
web|/c/Users/you/code/web/.cursor|D:/cursor-config/projects/web
'
```

Repeat `--project name|side1|side2` for the same shape. A repeated name overrides the `SYNC_PROJECTS` entry. A non-empty `SYNC_PROJECTS` already exported in the shell wins over the file, same as the ignore lists.

Inside each pair the script syncs `rules/`, `skills/`, `commands/`, `agents/`, plus the files `mcp.json`, `hooks.json`, and `BUGBOT.md` when they exist. Override that list with `SYNC_PROJECT_ITEMS` (comma, semicolon, or whitespace). A trailing `/`, or a bare name with no dot (`rules`, `commands`), is a directory tree. Anything else is one file.

```bash
SYNC_PROJECT_ITEMS=rules/,skills/,commands/,agents/,mcp.json,hooks.json,BUGBOT.md
```

`SYNC_EXTRA_ITEMS` uses the same syntax and **adds** items to the global roots only. It is empty by default, so `commands/`, `mcp.json`, and `hooks.json` are not part of the original global sync unless you opt in:

```bash
SYNC_EXTRA_ITEMS=commands/,mcp.json,hooks.json
```

### What gets copied

Project files use the same newer-wins comparison, `--tie-sec` prompt, `--dry-run`, and LF normalization as the global roots. Ignore keys are the project name plus the path under that pair, with forward slashes:

```text
projects/<name>/<path-under-the-pair>
projects/my-app/rules/x.mdc
projects/my-app/mcp.json
```

`rules/x.mdc` still means the global roots only. It does not match `projects/my-app/rules/x.mdc`.

```bash
SYNC_IGNORE_1_TO_2=projects/my-app/rules/windows-only.mdc:rules/machine-a.mdc
SYNC_IGNORE_2_TO_1=projects/web/rules/linux-only.mdc
```

If neither side of a pair exists, or a side exists and is not a directory, the script prints a warning and skips that pair. If one side exists, it creates the missing directory and then copies. `--dry-run` reports that create and does not mkdir.

`--no-projects` runs the global sync only. `--projects-only` skips the global `rules/` `agents/` `skills/` scan. Those two flags cannot be combined. `--commit-push` still stages only the global roots (plus `SYNC_EXTRA_ITEMS`); it does not commit project pairs, and it is skipped with `--projects-only`.

### Windows Git Bash

Git Bash accepts `C:/...`, `/c/...`, and backslashes. Quote values that contain spaces.

```bash
# .env next to the script, then:
./sync-cursor-roots.sh --dry-run

# or one pair on the command line (Git Bash):
./sync-cursor-roots.sh --dry-run \
  --project 'my-app|C:/Users/you/code/my-app/.cursor|D:/cursor-config/projects/my-app'

./sync-cursor-roots.sh --projects-only -y
./sync-cursor-roots.sh --no-projects
```

## Prompts

Without `-y` / `--yes`, the script asks before the first real copy and again before any git commit/push. `--dry-run` prints what would happen and touches nothing.

Full flags: `./sync-cursor-roots.sh --help`.

## Line endings

If the **only** difference is CRLF vs LF (common across Linux vs Windows/9p mounts), paths like `.md`/`.mdc`/`.json`/`.yaml`/`.txt` are LF-normalized on **both** roots automatically. You do not need `--normalize-lf` for that case. Pass `--normalize-lf` when you also want CR stripped on ordinary copies where content differs.

Before `--commit-push` runs `git add`, the same text types under `rules/`, `agents/`, and `skills/` are LF-normalized in the working tree so Git does not warn about CRLF vs `.gitattributes` `eol=lf`.
