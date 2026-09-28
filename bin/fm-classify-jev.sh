#!/usr/bin/env bash
# fm-classify-jev.sh - answer one or more declared Choice questions about a
# JSON state with typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-classify-jev.sh --state <file|-> --questions <file|->  [--floor <0..1>]
#   fm-classify-jev.sh --state <file|-> --preset triage       [--floor <0..1>]
#
# This is bin/fm-dispatch-resolve.sh's classifier with the options left open.
# Dispatch resolution is one Choice question whose options are the configured
# rules; triage is one Choice question whose options are the canonical triage
# labels. Both are the same operation, so both use the one call path in
# bin/fm-jev-lib.sh. This tool stops at the answer: it publishes each
# question's choice, confidence, and full probabilities, and says whether the
# answer cleared the floor. It never applies a label, edits an issue, or
# dispatches anything.
#
# Opt-in gate: TYPESAFE_API_KEY non-empty in this process environment, else a
#   TYPESAFE_API_KEY= line in $FM_HOME/.env read with fmx_env_get, the same
#   accessor bin/fm-dispatch-resolve.sh uses. The environment wins. Absent in
#   both: one "classify: off" line on stderr, nothing on stdout, exit 0, no
#   network call. The key lives in one shell variable and reaches curl as a
#   header read from a file descriptor, never on argv; nothing logs or writes
#   it.
#
# Inputs:
#   --state       a JSON value sent verbatim as the request's `state`; `-`
#                 reads stdin. Only one of --state and --questions may be `-`.
#   --questions   a JSON object of question-name -> {type, instructions,
#                 criteria}; every question must be type "choice" with at least
#                 two criteria. `-` reads stdin.
#   --preset      a built-in question set instead of --questions; see
#                 "Presets" below.
#   --floor       the confidence floor, default 0.6, the same floor
#                 bin/fm-dispatch-resolve.sh applies. A caller may raise it
#                 above that shared default: the measured triage sample
#                 separated cleanly - agreements at 0.88 confidence and above,
#                 every disagreement at 0.55 or below - so a stricter floor
#                 than 0.6 is the intended use.
#
# Never-send check: when the optional $FM_HOME/config/dispatch-never-send list
#   exists, every string value of the built request - the state, every
#   instruction, and every criterion - is checked against it before the POST,
#   under the same matching rules the resolver documents. A match, or a list
#   that is not a readable regular file, prints one
#   "classify: off (...; nothing sent)" line on stderr, nothing on stdout, and
#   exits 0 with no network call.
#
# Presets:
#   triage   one question, `label`, over the canonical five triage roles
#            (needs-triage, needs-info, ready-for-agent, ready-for-human,
#            wontfix) with the condition under which each is right. Pass the
#            state as {"issue": {"title": ..., "body": ...}} or whatever else
#            carries the issue. Pass your own --questions file when a repo's
#            docs/agents/triage-labels.md names different labels.
#
# Output (stdout, TOON-style block, the resolver's shape):
#   classify:
#     status: clear | ambiguous | error
#     model: ..   latency_ms: ..   tokens: <in>/<out>
#     floor: 0.6
#     answer: <question>  choice: <option>  confidence: <c>  -> clear | ambiguous
#     probabilities: <question>  <option>=<p> <option>=<p> ...
#   The top-level status is clear only when every answer is at or above the
#   floor; one ambiguous answer makes the block ambiguous. At or above the
#   floor the answer is worth taking; below it the decision belongs to a
#   stronger model or a person. Neither is a claim the model is right.
#   Every outcome exits 0 so a caller is never blocked by this tool.
#   Exit 2 only for a usage or configuration error (unreadable or malformed
#   input, a malformed question set, a floor out of range, or missing jq),
#   which is actionable, never selected around.
#
# Environment:
#   TYPESAFE_API_KEY is the only tool-specific environment setting.
#
# docs/configuration.md "Typed dispatch resolution" owns the operator contract,
# including the measured calibration behind the default floor.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# The triage preset's criteria say when each canonical role is right. The five
# roles and their meanings come from the triage-label doc resolution order - a
# repo's own docs/agents/triage-labels.md first, the personal agent-docs
# default when the repo has none - and the wording is the wording the
# calibration recorded in docs/configuration.md was measured with, so changing
# it invalidates that measurement.
triage_preset() {
  jq -n '{
    label: {
      type: "choice",
      instructions: "Triage this issue. Which ONE state does it belong in?",
      criteria: {
        "ready-for-agent": "The problem and the finished state are both clear enough that a competent engineer could start now without asking anyone a question.",
        "needs-info": "Something essential is missing or ambiguous - reproduction steps, the expected behaviour, or which surface it affects - so work would start by guessing.",
        "ready-for-human": "It needs a person rather than an agent: a product or design judgement, an account or credential, a physical or external action, or a decision about what the product should do.",
        "wontfix": "It should not be done: obsolete, a duplicate, out of scope, or already true.",
        "needs-triage": "None of the above can be decided from what is written here."
      }
    }
  }'
}

STATE_PATH='' QUESTIONS_PATH='' PRESET='' FLOOR=$FM_JEV_CONFIDENCE_FLOOR
NEVER_SEND_PATH="$CONFIG/dispatch-never-send"
while [ $# -gt 0 ]; do
  case "$1" in
    --state) [ $# -ge 2 ] || die "--state needs a value"; STATE_PATH=$2; shift 2 ;;
    --questions) [ $# -ge 2 ] || die "--questions needs a value"; QUESTIONS_PATH=$2; shift 2 ;;
    --preset) [ $# -ge 2 ] || die "--preset needs a value"; PRESET=$2; shift 2 ;;
    --floor) [ $# -ge 2 ] || die "--floor needs a value"; FLOOR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq required"

known_preset() {
  case "$1" in
    triage) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- opt-in gate ---------------------------------------------------------------
TYPESAFE_API_KEY_PRIVATE=$(fm_jev_resolve_key "$FM_HOME")
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  echo "classify: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
  exit 0
fi

# ---- inputs --------------------------------------------------------------------
[ -n "$STATE_PATH" ] || die "--state required (see --help)"
if [ -n "$PRESET" ]; then
  [ -z "$QUESTIONS_PATH" ] || die "--preset and --questions are mutually exclusive"
  known_preset "$PRESET" || die "unknown preset: $PRESET (known: triage)"
else
  [ -n "$QUESTIONS_PATH" ] || die "--questions or --preset required (see --help)"
fi
if [ "$STATE_PATH" = - ] && [ "$QUESTIONS_PATH" = - ]; then
  die "only one of --state and --questions may read stdin"
fi
case "$FLOOR" in
  ''|*[!0-9.]*|*.*.*) die "--floor must be a number from 0 through 1: $FLOOR" ;;
esac
jq -ne --arg f "$FLOOR" '($f | tonumber) >= 0 and ($f | tonumber) <= 1' >/dev/null 2>&1 \
  || die "--floor must be a number from 0 through 1: $FLOOR"

STATE=$(mktemp) || die "mktemp failed"
QUESTIONS=$(mktemp) || { rm -f "$STATE"; die "mktemp failed"; }
RESP_FILE=$(mktemp) || { rm -f "$STATE" "$QUESTIONS"; die "mktemp failed"; }
SEND_TEXT=$(mktemp) || { rm -f "$STATE" "$QUESTIONS" "$RESP_FILE"; die "mktemp failed"; }
trap 'rm -f "$STATE" "$QUESTIONS" "$RESP_FILE" "$SEND_TEXT"' EXIT

read_input() {
  local path=$1 dest=$2 label=$3
  if [ "$path" = - ]; then
    cat > "$dest" || die "could not read $label from stdin"
  else
    [ -r "$path" ] || die "$label file not readable: $path"
    cp "$path" "$dest" || die "could not read $label file: $path"
  fi
}

read_input "$STATE_PATH" "$STATE" state
jq -e . "$STATE" >/dev/null 2>&1 || die "state is not JSON: $STATE_PATH"

if [ -n "$PRESET" ]; then
  triage_preset > "$QUESTIONS" || die "could not build the $PRESET preset"
else
  read_input "$QUESTIONS_PATH" "$QUESTIONS" questions
  jq -e . "$QUESTIONS" >/dev/null 2>&1 || die "questions is not JSON: $QUESTIONS_PATH"
fi

# The question set is this tool's whole contract with the model, so a malformed
# one is an actionable configuration error, never selected around.
questions_err=$(jq -r '
  if type != "object" then "questions must be an object of question-name -> question"
  elif (keys | length) == 0 then "questions must declare at least one question"
  elif any(keys[]; length == 0) then "each question needs a non-empty name"
  elif any(.[]; type != "object") then "each question must be an object"
  elif any(.[]; .type != "choice") then "each question needs type \"choice\""
  elif any(.[]; (.instructions | type) != "string" or (.instructions | length) == 0) then "each question needs non-empty instructions"
  elif any(.[]; (.criteria | type) != "object") then "each question needs a criteria object"
  elif any(.[]; (.criteria | keys | length) < 2) then "each question needs at least two criteria"
  elif any(.[] | .criteria | .[]; type != "string" or length == 0) then "each criterion needs a non-empty condition"
  else empty end
' "$QUESTIONS" 2>/dev/null) || die "malformed questions: not JSON"
[ -z "$questions_err" ] || die "malformed questions: $questions_err"

emit_error() {
  local reason=$1
  echo "classify: error ($reason)" >&2
  printf 'classify:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

off_nothing_sent() {
  echo "classify: off ($1; nothing sent)" >&2
  exit 0
}

command -v curl >/dev/null 2>&1 || emit_error "curl not installed"

REQUEST=$(jq -n --arg model "$FM_JEV_MODEL" --slurpfile state "$STATE" --slurpfile questions "$QUESTIONS" '
  {model: $model, state: $state[0], questions: $questions[0]}') \
  || emit_error "could not build the request"

fm_jev_never_send_check "$NEVER_SEND_PATH" "$REQUEST" "$SEND_TEXT" request \
  || off_nothing_sent "$FM_JEV_NEVER_SEND_REASON"

fm_jev_post "$REQUEST" "$RESP_FILE" "$TYPESAFE_API_KEY_PRIVATE"
[ "$FM_JEV_HTTP" = 200 ] \
  || emit_error "http $FM_JEV_HTTP after ${FM_JEV_LATENCY_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"

# Every declared question must come back as a well-formed Choice answer over
# exactly its own options; the shared definitions own that contract.
jq -e --slurpfile questions "$QUESTIONS" "$FM_JEV_ANSWER_JQ"'
  ($questions[0]) as $q | . as $root |
  ($root.answers | type) == "object" and
  all($q | keys[]; . as $name | jev_answer_ok($root.answers[$name]; ($q[$name].criteria | keys))) and
  ($root | jev_usage_ok)' "$RESP_FILE" >/dev/null 2>&1 \
  || emit_error "response is not a Choice answer for every question"

RESULT=$(jq -n --arg floor "$FLOOR" --argjson lat "$FM_JEV_LATENCY_MS" \
  --slurpfile resp "$RESP_FILE" --slurpfile questions "$QUESTIONS" '
  ($resp[0]) as $r | ($questions[0]) as $q | ($floor | tonumber) as $f |
  ($q | keys | map({
    name: .,
    choice: $r.answers[.].choice,
    confidence: $r.answers[.].confidence,
    probabilities: $r.answers[.].probabilities,
    verdict: (if $r.answers[.].confidence >= $f then "clear" else "ambiguous" end)
  })) as $answers |
  {
    status: (if all($answers[]; .verdict == "clear") then "clear" else "ambiguous" end),
    model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    floor: $f, answers: $answers
  }') || emit_error "classification failed"

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  "classify:",
  "  status: \(.status | flat)",
  "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
  "  floor: \(.floor | flat)",
  (.answers[] |
    "  answer: \(.name | flat)  choice: \(.choice | flat)  confidence: \(.confidence | flat)  -> \(.verdict | flat)",
    "  probabilities: \(.name | flat)  \([.probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))")' \
  <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
exit 0
