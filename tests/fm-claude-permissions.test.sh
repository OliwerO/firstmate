#!/usr/bin/env bash
# Behavioral regressions for bin/fm-claude-permissions.sh home-script allow rules.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-permissions)

# make_root <dir>: a fake code root holding the real script plus sample scripts.
make_root() {
  local root=$1 name
  mkdir -p "$root/bin"
  cp "$ROOT/bin/fm-claude-permissions.sh" "$root/bin/"
  for name in fm-spawn.sh fm-brief.sh fm-pr-merge.sh fm-merge-local.sh fm-sample-lib.sh; do
    printf '#!/usr/bin/env bash\n' >"$root/bin/$name"
    chmod +x "$root/bin/$name"
  done
  printf '#!/usr/bin/env bash\n' >"$root/bin/fm-not-executable.sh"
}

run_tool() {  # <root> <home> <verb>
  FM_ROOT_OVERRIDE="$1" FM_HOME="$2" "$1/bin/fm-claude-permissions.sh" "$3"
}

test_print_covers_only_home_scripts() {
  local root home out
  root="$TMP_ROOT/print/root"
  home="$TMP_ROOT/print/home"
  make_root "$root"
  mkdir -p "$home"
  out=$(run_tool "$root" "$home" print) || fail "print exited nonzero"
  assert_contains "$out" "Bash(bin/fm-spawn.sh *)" "relative form missing"
  assert_contains "$out" "Bash(./bin/fm-brief.sh *)" "dot-relative form missing"
  assert_contains "$out" "Bash($root/bin/fm-spawn.sh *)" "absolute form missing"
  assert_contains "$out" "Bash(FM_HOME=$home bin/fm-spawn.sh *)" "FM_HOME relative form missing"
  assert_contains "$out" "Bash(FM_HOME=$home $root/bin/fm-spawn.sh *)" "FM_HOME absolute form missing"
  assert_contains "$out" "fm-claude-permissions.sh" "the generator itself is a home script"
  assert_not_contains "$out" "fm-pr-merge.sh" "PR merge command was granted"
  assert_not_contains "$out" "fm-merge-local.sh" "local merge command was granted"
  assert_not_contains "$out" "fm-sample-lib.sh" "sourced library was granted"
  assert_not_contains "$out" "fm-not-executable.sh" "non-executable file was granted"
  assert_not_contains "$out" "Bash(*" "broad rule emitted"
  pass "print grants each home script in every invocation form and nothing else"
}

test_sync_merges_and_is_idempotent() {
  local root home file before after
  root="$TMP_ROOT/merge/root"
  home="$root"
  make_root "$root"
  mkdir -p "$root/.claude"
  file="$root/.claude/settings.local.json"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]},"permissions":{"allow":["Bash(make test)","Bash(bin/fm-spawn.sh *)"],"deny":["Bash(rm *)"]},"model":"x"}' >"$file"
  run_tool "$root" "$home" sync || fail "sync exited nonzero on a valid file"
  assert_equals "true" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$file")" "existing hook lost"
  assert_equals "x" "$(jq -r '.model' "$file")" "existing key lost"
  assert_equals '["Bash(rm *)"]' "$(jq -c '.permissions.deny' "$file")" "existing deny lost"
  assert_equals "Bash(make test)" "$(jq -r '.permissions.allow[0]' "$file")" "existing allow order changed"
  assert_equals 1 "$(jq '[.permissions.allow[] | select(. == "Bash(bin/fm-spawn.sh *)")] | length' "$file")" "duplicate rule added"
  assert_equals 1 "$(jq --arg r "Bash($root/bin/fm-brief.sh *)" '[.permissions.allow[] | select(. == $r)] | length' "$file")" "generated rule not merged"
  before=$(cat "$file")
  run_tool "$root" "$home" sync || fail "second sync exited nonzero"
  after=$(cat "$file")
  assert_equals "$before" "$after" "second sync changed an already-current file"
  pass "sync preserves existing settings, adds missing rules, and converges"
}

test_sync_creates_missing_file() {
  local root file
  root="$TMP_ROOT/create/root"
  make_root "$root"
  file="$root/.claude/settings.local.json"
  run_tool "$root" "$root" sync || fail "sync exited nonzero without a settings file"
  assert_equals 1 "$(jq '[.permissions.allow[] | select(. == "Bash(bin/fm-brief.sh *)")] | length' "$file")" "new file lacks rules"
  : >"$file"
  run_tool "$root" "$root" sync || fail "sync exited nonzero on an empty settings file"
  assert_equals 1 "$(jq '[.permissions.allow[] | select(. == "Bash(bin/fm-brief.sh *)")] | length' "$file")" "empty file not filled"
  pass "sync creates or fills an absent or empty settings file"
}

test_sync_skips_a_home_outside_the_code_root() {
  local root home
  root="$TMP_ROOT/foreign/root"
  home="$TMP_ROOT/foreign/home"
  make_root "$root"
  mkdir -p "$home"
  run_tool "$root" "$home" sync || fail "sync exited nonzero for a separate home"
  [ ! -e "$root/.claude/settings.local.json" ] || fail "sync wrote rules for a home outside the code root"
  pass "sync leaves a code root alone when FM_HOME names another home"
}

test_sync_refuses_unsafe_files() {
  local root file out rc
  root="$TMP_ROOT/refuse/root"
  make_root "$root"
  mkdir -p "$root/.claude"
  file="$root/.claude/settings.local.json"

  printf '{"permissions": ' >"$file"
  out=$(run_tool "$root" "$root" sync); rc=$?
  expect_code 1 "$rc" "invalid JSON"
  assert_contains "$out" "CLAUDE_PERMISSIONS: cannot merge" "invalid JSON not reported"
  assert_equals '{"permissions": ' "$(cat "$file")" "invalid JSON was overwritten"

  printf '%s\n' '{"permissions":{"allow":"Bash(x)"}}' >"$file"
  out=$(run_tool "$root" "$root" sync); rc=$?
  expect_code 1 "$rc" "non-array allow"
  assert_contains "$out" "permissions.allow is not an array" "non-array allow not reported"

  rm -f "$file"
  printf '{}\n' >"$TMP_ROOT/refuse/elsewhere.json"
  ln -s "$TMP_ROOT/refuse/elsewhere.json" "$file"
  out=$(run_tool "$root" "$root" sync); rc=$?
  expect_code 1 "$rc" "symlinked file"
  assert_contains "$out" "is a symlink" "symlink not reported"
  assert_equals '{}' "$(cat "$TMP_ROOT/refuse/elsewhere.json")" "wrote through a symlink"

  rm -f "$file"
  printf '{}\n' >"$file"
  fm_git_identity
  git -C "$root" init -q
  git -C "$root" add -f .claude/settings.local.json
  out=$(run_tool "$root" "$root" sync); rc=$?
  expect_code 1 "$rc" "tracked file"
  assert_contains "$out" "is tracked by git" "tracked file not reported"
  assert_equals '{}' "$(cat "$file")" "tracked file was modified"
  pass "sync refuses invalid, symlinked, and tracked settings files without writing"
}

test_unquotable_paths_skip_absolute_forms() {
  local root out
  root="$TMP_ROOT/with space/root"
  make_root "$root"
  out=$(run_tool "$root" "$root" print) || fail "print exited nonzero"
  assert_contains "$out" "Bash(bin/fm-spawn.sh *)" "relative form missing"
  assert_not_contains "$out" "$root" "absolute form emitted for a path a shell would quote"
  assert_not_contains "$out" "FM_HOME=" "FM_HOME form emitted for a path a shell would quote"
  pass "paths a shell would quote get only relative rules"
}

test_print_covers_only_home_scripts
test_sync_merges_and_is_idempotent
test_sync_creates_missing_file
test_sync_skips_a_home_outside_the_code_root
test_sync_refuses_unsafe_files
test_unquotable_paths_skip_absolute_forms
