#!/usr/bin/env bash
# Pre-approve this Firstmate home's own operational scripts for Claude Code.
#
# Usage: fm-claude-permissions.sh print|sync
#   print  Print this home's Claude Code allow rules, one per line, sorted.
#   sync   Merge those rules into <code-root>/.claude/settings.local.json.
#          A no-op when FM_HOME resolves to a directory other than the code
#          root, so a shared code root never collects another home's rules.
#          Silent when the file already holds every rule; prints one
#          "CLAUDE_PERMISSIONS: <reason>" line and exits 1 when it cannot merge.
#
# Why: Claude Code's auto-mode classifier can block a home running its own
# scripts as "Self-Modification" (fm-spawn.sh pre-registers worker trust in
# ~/.claude.json, fm-brief.sh writes worker instructions, and so on). A matching
# permissions.allow rule resolves before the classifier sees the command, and a
# narrow exact-script rule survives auto mode, which drops only broad
# code-execution rules such as Bash(*).
#
# Granted scripts: every executable <code-root>/bin/fm-*.sh except sourced
# libraries (*-lib.sh) and the merge commands fm-pr-merge.sh and
# fm-merge-local.sh, which stay with the classifier or the captain's prompt.
# Each granted script S gets these rules, where R is the code root (both its
# logical and physical spelling when they differ) and H is the resolved FM_HOME:
#   Bash(bin/S *)  Bash(./bin/S *)  Bash(R/bin/S *)
#   Bash(FM_HOME=H bin/S *)  Bash(FM_HOME=H R/bin/S *)
# A trailing " *" also matches the bare command. Claude Code does not match an
# allow rule past an unlisted environment assignment, so the FM_HOME= forms are
# spelled out. Absolute forms are skipped for a path holding characters a shell
# would quote, because the command text would then differ from the rule.
#
# Merge contract: the rules are added to permissions.allow and every other key,
# rule, and ordering in the file is preserved; nothing is ever removed, so rules
# for a since-deleted script stay inert until edited by hand. The file is
# rewritten atomically and only when a rule is missing. sync refuses invalid
# JSON, a non-object document or permissions value, a non-array allow value, a
# symlinked file, and a file git tracks (Claude Code would then treat it as
# repository-supplied), rather than overwriting any of them.
#
# Bootstrap runs sync on every non-detect-only session start, so the primary
# home and every local or remote secondmate home converge on their own session
# start; Claude Code reloads permission edits into a running session.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

usage() {
  echo "usage: fm-claude-permissions.sh print|sync" >&2
}

# Characters a shell prints unquoted, so a rule can name the path literally.
plain_path() {
  case "$1" in
    ''|*[!A-Za-z0-9._/+@,:=-]*) return 1 ;;
  esac
}

granted_scripts() {
  local path name
  for path in "$FM_ROOT"/bin/fm-*.sh; do
    [ -f "$path" ] && [ -x "$path" ] || continue
    name=${path##*/}
    case "$name" in
      *-lib.sh|fm-pr-merge.sh|fm-merge-local.sh) continue ;;
    esac
    printf '%s\n' "$name"
  done
}

emit_rules() {
  local roots=() home root physical name r
  root=$(cd "$FM_ROOT" && pwd) || return 1
  physical=$(cd "$FM_ROOT" && pwd -P) || return 1
  plain_path "$root" && roots+=("$root")
  [ "$physical" = "$root" ] || ! plain_path "$physical" || roots+=("$physical")
  home=
  if [ -d "$FM_HOME" ]; then
    home=$(cd "$FM_HOME" && pwd) || home=
  fi
  plain_path "$home" || home=
  while IFS= read -r name; do
    printf 'Bash(bin/%s *)\n' "$name"
    printf 'Bash(./bin/%s *)\n' "$name"
    for r in ${roots[@]+"${roots[@]}"}; do
      printf 'Bash(%s/bin/%s *)\n' "$r" "$name"
    done
    if [ -n "$home" ]; then
      printf 'Bash(FM_HOME=%s bin/%s *)\n' "$home" "$name"
      for r in ${roots[@]+"${roots[@]}"}; do
        printf 'Bash(FM_HOME=%s %s/bin/%s *)\n' "$home" "$r" "$name"
      done
    fi
  done < <(granted_scripts)
}

diag() {
  echo "CLAUDE_PERMISSIONS: $*"
  exit 1
}

sync_rules() {
  local dir file rules tmp current merged
  [ -d "$FM_HOME" ] || return 0
  [ "$(cd "$FM_HOME" && pwd -P)" = "$(cd "$FM_ROOT" && pwd -P)" ] || return 0
  command -v jq >/dev/null 2>&1 || diag "jq is required to merge .claude/settings.local.json"
  dir="$FM_ROOT/.claude"
  file="$dir/settings.local.json"
  [ ! -L "$dir" ] || diag "$dir is a symlink; not writing through it"
  [ ! -L "$file" ] || diag "$file is a symlink; not writing through it"
  if git -C "$FM_ROOT" ls-files --error-unmatch -- .claude/settings.local.json >/dev/null 2>&1; then
    diag "$file is tracked by git; not writing home-local rules into it"
  fi
  rules=$(emit_rules | sort -u | jq -R . | jq -s .) || diag "could not enumerate $FM_ROOT/bin scripts"
  if [ -e "$file" ]; then
    current=$(cat "$file") || diag "cannot read $file"
    case "$current" in *[![:space:]]*) ;; *) current='{}' ;; esac
  else
    current='{}'
  fi
  # shellcheck disable=SC2016 # jq program, not shell expansion.
  merged=$(printf '%s' "$current" | jq --argjson rules "$rules" '
    if type != "object" then error("document is not a JSON object")
    elif (.permissions // {} | type) != "object" then error("permissions is not an object")
    elif (.permissions.allow // [] | type) != "array" then error("permissions.allow is not an array")
    else
      (.permissions.allow // []) as $have
      | if ($rules - $have) == [] then empty
        else .permissions.allow = $have + ($rules - $have) end
    end' 2>&1) || diag "cannot merge $file: $(printf '%s' "$merged" | head -n 1)"
  [ -n "$merged" ] || return 0
  mkdir -p "$dir" || diag "cannot create $dir"
  tmp=$(mktemp "$dir/.settings.local.json.XXXXXX") || diag "cannot create a temporary file in $dir"
  if ! printf '%s\n' "$merged" >"$tmp" || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    diag "cannot write $file"
  fi
}

case "${1:-}" in
  print) emit_rules | sort -u ;;
  sync) sync_rules ;;
  *) usage; exit 2 ;;
esac
