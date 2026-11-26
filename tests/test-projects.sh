#!/usr/bin/env bash
# Project-pair sync plus a check that the default global rules/agents/skills sync is unchanged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../sync-cursor-roots.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_eq() {
  local path="$1" want="$2" got
  [[ -f "$path" ]] || fail "missing file: $path"
  got="$(cat -- "$path")"
  if [[ "$got" == "$want" || "$got" == "$want"$'\n' || "$got"$'\n' == "$want" ]]; then
    return 0
  fi
  fail "$path: expected [$want] got [$got]"
}

assert_absent() {
  [[ ! -e "$1" ]] || fail "unexpected path exists: $1"
}

assert_no_cr() {
  if grep -q $'\r' "$1"; then
    fail "CR still present in $1"
  fi
}

RUN_RC=0
RUN_OUT=""

run_sync() {
  local env_file="$1"
  shift
  set +e
  RUN_OUT="$(SYNC_ENV_FILE="$env_file" bash "$SCRIPT" "$@" 2>&1)"
  RUN_RC=$?
  set -e
}

expect_ok() {
  [[ "$RUN_RC" -eq 0 ]] || fail "exit $RUN_RC
$RUN_OUT"
}

expect_fail() {
  [[ "$RUN_RC" -ne 0 ]] || fail "expected failure but exit 0
$RUN_OUT"
}

assert_out_has() {
  [[ "$RUN_OUT" == *"$1"* ]] || fail "output missing [$1]
$RUN_OUT"
}

assert_out_lacks() {
  [[ "$RUN_OUT" != *"$1"* ]] || fail "output unexpectedly contains [$1]
$RUN_OUT"
}

# Absolute stamps stay ordered on hosts whose "now" is already in 2026.
old_mtime() { touch -d '2020-01-01 00:00:00' "$1"; }
new_mtime() { touch -d '2024-06-01 00:00:00' "$1"; }
newer_mtime() { touch -d '2030-01-01 00:00:00' "$1"; }
newest_mtime() { touch -d '2031-06-01 00:00:00' "$1"; }

write_env() {
  local dest="$1" line key value
  : >"$dest"
  shift
  for line in "$@"; do
    key="${line%%=*}"
    value="${line#*=}"
    value="${value//\'/\'\\\'\'}"
    printf "%s='%s'\n" "$key" "$value" >>"$dest"
  done
}

# --- help (exits before root checks; do not load a repo .env) ---
set +e
RUN_OUT="$(SYNC_ENV_FILE=/dev/null bash "$SCRIPT" --help 2>&1)"
RUN_RC=$?
set -e
expect_ok
assert_out_has "--project SPEC"
assert_out_has "--projects-only"
assert_out_has "--no-projects"
assert_out_has "projects/<name>/<rel>"
assert_out_has "SYNC_PROJECTS"

# --- default global scope, no project config ---
P1="$TMP/plain1"
P2="$TMP/plain2"
mkdir -p "$P1/rules" "$P2/rules" "$P1/agents" "$P2/agents" "$P1/skills" "$P2/skills" "$P1/commands"
printf 'old-global\n' >"$P1/rules/shared.mdc"
printf 'new-global\n' >"$P2/rules/shared.mdc"
old_mtime "$P1/rules/shared.mdc"
new_mtime "$P2/rules/shared.mdc"
printf 'only-from-1\n' >"$P1/rules/only1.mdc"
printf 'only-from-2\n' >"$P2/agents/only2.md"
printf 'global-cmd\n' >"$P1/commands/c.md"
printf '{"mcp":true}\n' >"$P1/mcp.json"

PLAIN="$TMP/plain.env"
write_env "$PLAIN" "CURSOR_ROOT_1=$P1" "CURSOR_ROOT_2=$P2"

run_sync "$PLAIN" --dry-run
expect_ok
assert_out_has "Scope:        rules/ agents/ skills/"
assert_out_has "Scanning both roots for files under rules/, agents/, skills/ ..."
assert_out_lacks "Projects:"
assert_out_has "root 2 newer -> root 1 (rules/shared.mdc)"
assert_out_lacks "$P1/commands/c.md"
assert_out_lacks "$P1/mcp.json"
assert_file_eq "$P1/rules/shared.mdc" "old-global"
assert_absent "$P2/commands/c.md"
assert_absent "$P2/mcp.json"

run_sync "$PLAIN" -y
expect_ok
assert_file_eq "$P1/rules/shared.mdc" "new-global"
assert_file_eq "$P2/rules/only1.mdc" "only-from-1"
assert_file_eq "$P1/agents/only2.md" "only-from-2"
assert_absent "$P2/commands/c.md"
assert_absent "$P2/mcp.json"
assert_absent "$P1/hooks.json"

run_sync "$PLAIN" -y
expect_ok
assert_out_lacks "copied:"
assert_out_lacks "created directory:"

printf 'from-global-1\n' >"$P1/rules/shared.mdc"
newest_mtime "$P1/rules/shared.mdc"
old_mtime "$P2/rules/shared.mdc"
run_sync "$PLAIN" -y
expect_ok
assert_file_eq "$P2/rules/shared.mdc" "from-global-1"

# Global commands/mcp/hooks stay put until SYNC_EXTRA_ITEMS is set.
printf '{"h":1}\n' >"$P2/hooks.json"
EXTRA="$TMP/extra.env"
write_env "$EXTRA" "CURSOR_ROOT_1=$P1" "CURSOR_ROOT_2=$P2" "SYNC_EXTRA_ITEMS=commands/,mcp.json,hooks.json"
run_sync "$EXTRA" -y
expect_ok
assert_out_has "Scope:        rules/ agents/ skills/ commands/ mcp.json hooks.json"
assert_file_eq "$P2/commands/c.md" "global-cmd"
assert_file_eq "$P2/mcp.json" '{"mcp":true}'
assert_file_eq "$P1/hooks.json" '{"h":1}'

# --- project pairs ---
G1="$TMP/g1"
G2="$TMP/g2"
mkdir -p "$G1/rules" "$G2/rules" "$G1/agents" "$G2/skills"

A1="$TMP/work/my-app/.cursor"
A2="$TMP/settings/my-app"
mkdir -p "$A1/rules/nested" "$A2/rules" "$A1/skills" "$A2/skills" "$A2/commands" "$A1/agents"

printf 'proj-old\n' >"$A1/rules/x.mdc"
printf 'proj-new\n' >"$A2/rules/x.mdc"
old_mtime "$A1/rules/x.mdc"
new_mtime "$A2/rules/x.mdc"

printf 'skill-new\n' >"$A1/skills/s.md"
printf 'skill-old\n' >"$A2/skills/s.md"
new_mtime "$A1/skills/s.md"
old_mtime "$A2/skills/s.md"

printf 'nested-1\n' >"$A1/rules/nested/n.mdc"
printf 'cmd\n' >"$A2/commands/run.md"
printf '{"hooks":1}\n' >"$A1/hooks.json"
printf '# bug\n' >"$A2/BUGBOT.md"
printf '{"p":1}\n' >"$A1/mcp.json"
printf 'agent-body\n' >"$A1/agents/a.md"

printf 'keep-1\n' >"$A1/rules/keep.mdc"
printf 'keep-2\n' >"$A2/rules/keep.mdc"
new_mtime "$A1/rules/keep.mdc"
old_mtime "$A2/rules/keep.mdc"

printf 'from2-1\n' >"$A1/rules/from2.mdc"
printf 'from2-2\n' >"$A2/rules/from2.mdc"
old_mtime "$A1/rules/from2.mdc"
new_mtime "$A2/rules/from2.mdc"

# Same relative path as a global ignore must still sync, because the key is prefixed.
printf 'g-ignore-1\n' >"$G1/rules/stay1.mdc"
printf 'g-ignore-2\n' >"$G2/rules/stay1.mdc"
new_mtime "$G1/rules/stay1.mdc"
old_mtime "$G2/rules/stay1.mdc"
printf 'proj-stay-new\n' >"$A1/rules/stay1.mdc"
printf 'proj-stay-old\n' >"$A2/rules/stay1.mdc"
new_mtime "$A1/rules/stay1.mdc"
old_mtime "$A2/rules/stay1.mdc"

printf 'same\n' >"$A1/rules/eol.mdc"
printf 'same\r\n' >"$A2/rules/eol.mdc"
old_mtime "$A1/rules/eol.mdc"
new_mtime "$A2/rules/eol.mdc"

B1="$TMP/work/solo/.cursor"
mkdir -p "$B1/rules"
printf 'solo\n' >"$B1/rules/solo.mdc"
B2="$TMP/settings/solo"

E2="$TMP/settings/only-right"
mkdir -p "$E2/rules"
printf 'from-right\n' >"$E2/rules/r.mdc"
E1="$TMP/work/only-right/.cursor"

D1="$TMP/path with spaces/app/.cursor"
D2="$TMP/settings/space app"
mkdir -p "$D1/rules"
printf 'space-rule\n' >"$D1/rules/sp.mdc"

ENV="$TMP/projects.env"
cat >"$ENV" <<EOF
CURSOR_ROOT_1=$G1
CURSOR_ROOT_2=$G2
SYNC_IGNORE_1_TO_2=rules/stay1.mdc:projects/my-app/rules/keep.mdc
SYNC_IGNORE_2_TO_1=projects/my-app/rules/from2.mdc
SYNC_PROJECTS='
my-app|$A1|$A2
solo|$B1|$B2
only-right|$E1|$E2
space|$D1|$D2
ghost|$TMP/no-such-1|$TMP/no-such-2
'
EOF

run_sync "$ENV" --dry-run
expect_ok
assert_out_has "Projects:"
assert_out_has "Scanning global roots and project pairs ..."
assert_out_has "root 2 newer -> root 1 (projects/my-app/rules/x.mdc)"
assert_out_has "root 1 newer -> root 2 (projects/my-app/skills/s.md)"
assert_out_has "projects/my-app/rules/nested/n.mdc"
assert_out_has "projects/my-app/commands/run.md"
assert_out_has "projects/my-app/hooks.json"
assert_out_has "projects/my-app/BUGBOT.md"
assert_out_has "projects/my-app/mcp.json"
assert_out_has "projects/my-app/agents/a.md"
assert_out_has "[dry-run] skipped (SYNC_IGNORE_1_TO_2): rules/stay1.mdc"
assert_out_has "[dry-run] skipped (SYNC_IGNORE_1_TO_2): projects/my-app/rules/keep.mdc"
assert_out_has "[dry-run] skipped (SYNC_IGNORE_2_TO_1): projects/my-app/rules/from2.mdc"
assert_out_has "root 1 newer -> root 2 (projects/my-app/rules/stay1.mdc)"
assert_out_has "EOL normalize"
assert_out_has "neither side exists"
assert_out_has "ghost"
assert_out_has "[dry-run] would create directory:"
assert_out_lacks "created directory:"
assert_file_eq "$A1/rules/x.mdc" "proj-old"
assert_file_eq "$A2/rules/keep.mdc" "keep-2"
assert_absent "$B2"
assert_absent "$E1"
assert_absent "$TMP/no-such-1"
assert_absent "$TMP/no-such-2"

run_sync "$ENV" -y
expect_ok
assert_file_eq "$A1/rules/x.mdc" "proj-new"
assert_file_eq "$A2/skills/s.md" "skill-new"
assert_file_eq "$A2/rules/nested/n.mdc" "nested-1"
assert_file_eq "$A1/commands/run.md" "cmd"
assert_file_eq "$A2/hooks.json" '{"hooks":1}'
assert_file_eq "$A1/BUGBOT.md" "# bug"
assert_file_eq "$A2/mcp.json" '{"p":1}'
assert_file_eq "$A2/agents/a.md" "agent-body"
assert_file_eq "$A2/rules/keep.mdc" "keep-2"
assert_file_eq "$A1/rules/keep.mdc" "keep-1"
assert_file_eq "$A1/rules/from2.mdc" "from2-1"
assert_file_eq "$A2/rules/from2.mdc" "from2-2"
assert_file_eq "$G2/rules/stay1.mdc" "g-ignore-2"
assert_file_eq "$A2/rules/stay1.mdc" "proj-stay-new"
assert_file_eq "$B2/rules/solo.mdc" "solo"
assert_file_eq "$E1/rules/r.mdc" "from-right"
assert_file_eq "$D2/rules/sp.mdc" "space-rule"
assert_absent "$TMP/no-such-1"
cmp -s "$A1/rules/eol.mdc" "$A2/rules/eol.mdc" || fail "eol files diverged"
assert_no_cr "$A1/rules/eol.mdc"
assert_no_cr "$A2/rules/eol.mdc"
assert_file_eq "$A1/rules/eol.mdc" "same"

# Reverse newer-wins: project side 1 and global side 1.
printf 'from-side-1\n' >"$A1/rules/x.mdc"
newer_mtime "$A1/rules/x.mdc"
old_mtime "$A2/rules/x.mdc"
printf 'global-only-new\n' >"$G1/rules/fresh.mdc"
run_sync "$ENV" -y
expect_ok
assert_file_eq "$A2/rules/x.mdc" "from-side-1"
assert_file_eq "$G2/rules/fresh.mdc" "global-only-new"

run_sync "$ENV" -y
expect_ok
assert_out_lacks "copied:"
assert_out_lacks "created directory:"

# --no-projects moves global bytes and leaves the project pair alone.
printf 'proj-should-stay\n' >"$A1/skills/s.md"
newer_mtime "$A1/skills/s.md"
printf 'global-should-move\n' >"$G1/rules/fresh.mdc"
newer_mtime "$G1/rules/fresh.mdc"
run_sync "$ENV" --no-projects -y
expect_ok
assert_out_has "Projects:     skipped (--no-projects)"
assert_file_eq "$G2/rules/fresh.mdc" "global-should-move"
assert_file_eq "$A2/skills/s.md" "skill-new"

# --projects-only is the other direction.
printf 'only-proj\n' >"$A1/skills/s.md"
newest_mtime "$A1/skills/s.md"
printf 'only-global\n' >"$G1/rules/fresh.mdc"
newest_mtime "$G1/rules/fresh.mdc"
run_sync "$ENV" --projects-only -y
expect_ok
assert_out_has "projects only (--projects-only)"
assert_file_eq "$A2/skills/s.md" "only-proj"
assert_file_eq "$G2/rules/fresh.mdc" "global-should-move"

# Narrow project items (bare directory name) and a custom list.
N1="$TMP/narrow/.cursor"
N2="$TMP/settings/narrow"
mkdir -p "$N1/rules" "$N1/commands"
printf 'n-rule\n' >"$N1/rules/a.md"
printf 'n-cmd\n' >"$N1/commands/c.md"
NARROW="$TMP/narrow.env"
write_env "$NARROW" \
  "CURSOR_ROOT_1=$G1" \
  "CURSOR_ROOT_2=$G2" \
  "SYNC_PROJECT_ITEMS=rules" \
  "SYNC_PROJECTS=narrow|$N1|$N2"
run_sync "$NARROW" --projects-only -y
expect_ok
assert_file_eq "$N2/rules/a.md" "n-rule"
assert_absent "$N2/commands/c.md"
assert_absent "$N2/commands"

# Semicolon separator, comment line, and a shell export overriding the file.
S1="$TMP/semi-a"
S2="$TMP/settings/semi-a"
T1="$TMP/semi-b"
T2="$TMP/settings/semi-b"
mkdir -p "$S1/rules" "$T1/skills"
printf 'semi-a\n' >"$S1/rules/a.mdc"
printf 'semi-b\n' >"$T1/skills/b.md"
SEMI="$TMP/semi.env"
cat >"$SEMI" <<EOF
CURSOR_ROOT_1=$G1
CURSOR_ROOT_2=$G2
SYNC_PROJECTS='
# comment should be ignored
not-used|$TMP/nope-a|$TMP/nope-b
'
EOF
run_sync "$SEMI" --projects-only -y
expect_ok
assert_out_has "not-used"
assert_out_has "neither side exists"

cat >"$SEMI" <<EOF
CURSOR_ROOT_1=$G1
CURSOR_ROOT_2=$G2
SYNC_PROJECTS='sa|$S1|$S2;sb|$T1|$T2'
EOF
run_sync "$SEMI" --projects-only -y
expect_ok
assert_file_eq "$S2/rules/a.mdc" "semi-a"
assert_file_eq "$T2/skills/b.md" "semi-b"

O1="$TMP/override-a"
O2="$TMP/override-b"
mkdir -p "$O1/rules"
printf 'overridden\n' >"$O1/rules/o.mdc"
set +e
RUN_OUT="$(SYNC_PROJECTS="ovr|$O1|$O2" SYNC_ENV_FILE="$SEMI" bash "$SCRIPT" --projects-only -y 2>&1)"
RUN_RC=$?
set -e
expect_ok
assert_file_eq "$O2/rules/o.mdc" "overridden"
assert_out_lacks "semi-a/rules/a.mdc"
assert_out_has "ovr:"

# CLI --project, relative paths, and a same-name override.
C1="$TMP/cli-proj/.cursor"
C2="$TMP/settings/cli-proj"
mkdir -p "$C1/rules"
printf 'cli-rule\n' >"$C1/rules/cli.mdc"
run_sync "$PLAIN" --project "cli-demo|$C1|$C2" -y
expect_ok
assert_file_eq "$C2/rules/cli.mdc" "cli-rule"

mkdir -p "$TMP/rel-a/rules"
printf 'rel-rule\n' >"$TMP/rel-a/rules/t.md"
set +e
rel_out="$(
  cd "$TMP"
  SYNC_ENV_FILE="$PLAIN" bash "$SCRIPT" --project 'rel|rel-a|rel-b' -y 2>&1
)"
rel_rc=$?
set -e
[[ "$rel_rc" -eq 0 ]] || fail "relative project sync failed ($rel_rc): $rel_out"
assert_file_eq "$TMP/rel-b/rules/t.md" "rel-rule"

printf 'cli-wins\n' >"$C1/rules/cli.mdc"
newer_mtime "$C1/rules/cli.mdc"
# File still lists my-app; CLI replaces that name and must not use the stale paths.
cat >"$TMP/override-name.env" <<EOF
CURSOR_ROOT_1='$G1'
CURSOR_ROOT_2='$G2'
SYNC_PROJECTS='cli-demo|$TMP/nope-a|$TMP/nope-b'
EOF
run_sync "$TMP/override-name.env" --projects-only --project "cli-demo|$C1|$C2" -y
expect_ok
assert_out_has "overridden by --project"
assert_file_eq "$C2/rules/cli.mdc" "cli-wins"
assert_absent "$TMP/nope-a"

# Missing Windows-style paths warn and do not abort. Backslashes are normalized.
run_sync "$PLAIN" --projects-only --project 'win|C:\Users\nope\.cursor|D:/cursor-config/projects/win'
expect_ok
assert_out_has "neither side exists"
assert_out_has "C:/Users/nope/.cursor"
assert_out_has "D:/cursor-config/projects/win"

# Not a directory, bad spec, combined flags, projects-only with nothing configured.
printf 'x\n' >"$TMP/not-a-dir"
run_sync "$PLAIN" --projects-only --project "notdir|$TMP/not-a-dir|$P2"
expect_ok
assert_out_has "not a directory"
assert_file_eq "$TMP/not-a-dir" "x"

run_sync "$PLAIN" --project 'missing-fields'
expect_fail
assert_out_has "name|path1|path2"

run_sync "$PLAIN" --project 'bad name|/tmp/a|/tmp/b'
expect_fail
assert_out_has "project name must match"

run_sync "$PLAIN" --projects-only --no-projects
expect_fail
assert_out_has "cannot be combined"

run_sync "$PLAIN" --projects-only
expect_fail
assert_out_has "no project pairs configured"

# Tie on a project file is reported in dry-run and left untouched.
TIE1="$TMP/tie1"
TIE2="$TMP/tie2"
mkdir -p "$TIE1/rules" "$TIE2/rules"
printf 'tie-a\n' >"$TIE1/rules/tie.mdc"
printf 'tie-b\n' >"$TIE2/rules/tie.mdc"
touch -d '2024-01-01 00:00:00' "$TIE1/rules/tie.mdc" "$TIE2/rules/tie.mdc"
TIE_ENV="$TMP/tie.env"
write_env "$TIE_ENV" "CURSOR_ROOT_1=$P1" "CURSOR_ROOT_2=$P2" "SYNC_PROJECTS=tie|$TIE1|$TIE2"
run_sync "$TIE_ENV" --projects-only --dry-run
expect_ok
assert_out_has "conflict (mtime tie"
assert_out_has "projects/tie/rules/tie.mdc"
assert_file_eq "$TIE1/rules/tie.mdc" "tie-a"
assert_file_eq "$TIE2/rules/tie.mdc" "tie-b"

# Empty SYNC_PROJECT_ITEMS is an error.
EMPTY_ITEMS="$TMP/empty-items.env"
write_env "$EMPTY_ITEMS" "CURSOR_ROOT_1=$P1" "CURSOR_ROOT_2=$P2" "SYNC_PROJECT_ITEMS=," "SYNC_PROJECTS=tie|$TIE1|$TIE2"
run_sync "$EMPTY_ITEMS" --projects-only --dry-run
expect_fail
assert_out_has "did not contain any sync items"

printf '%s\n' "project sync tests passed"
