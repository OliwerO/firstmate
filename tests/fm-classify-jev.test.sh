#!/usr/bin/env bash
# Behavior tests for bin/fm-classify-jev.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, and answers with a canned typesafe.ai response.
# No case touches the network, and the absent-key case proves the tool makes no
# call at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-classify-jev.sh"
TMP_ROOT=$(fm_test_tmproot fm-classify-jev)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
LOG="$TMP_ROOT/log"
STATE="$TMP_ROOT/state.json"
QUESTIONS="$TMP_ROOT/questions.json"
RESPONSE="$TMP_ROOT/response.json"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$LOG" "$NO_CURL_BIN"
for command_name in bash cat chmod cp dirname jq mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
done

cat > "$STATE" <<'JSON'
{"issue": {"title": "Pager shows one row too many", "body": "The `<=` on line 40 of pager.sh should be `<`."}}
JSON

cat > "$QUESTIONS" <<'JSON'
{
  "label": {
    "type": "choice",
    "instructions": "Which ONE state does this issue belong in?",
    "criteria": {
      "ready-for-agent": "Fully specified.",
      "needs-info": "Something essential is missing.",
      "wontfix": "It should not be done."
    }
  },
  "blast_radius": {
    "type": "choice",
    "instructions": "What is the worst realistic blast radius?",
    "criteria": {
      "internal-only": "Tooling, tests, docs or process.",
      "user-visible": "Something a user sees, recoverably."
    }
  }
}
JSON

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
log="${FAKE_CURL_LOG:?}"
printf '%s\n' "$@" > "$log/argv"
out=''
prev=''
for arg in "$@"; do
  if [ "$prev" = -o ]; then out=$arg; fi
  prev=$arg
done
cat > "$log/body"
cat <&3 > "$log/header" 2>/dev/null || :
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" CHILD_ENV_LOG="$LOG/child-env"

# write_response <label-choice> <label-confidence> <radius-choice> <radius-confidence>
write_response() {
  jq -n --arg lc "$1" --argjson lp "$2" --arg rc "$3" --argjson rp "$4" '
    def spread($choice; $conf; $options):
      ($options | length) as $n |
      ($options | map({key: ., value: (if . == $choice then $conf else ((1 - $conf) / ($n - 1)) end)}) | from_entries);
    {
      model: "jev-1.13.0",
      answers: {
        label: {choice: $lc, confidence: $lp,
                probabilities: spread($lc; $lp; ["ready-for-agent", "needs-info", "wontfix"])},
        blast_radius: {choice: $rc, confidence: $rp,
                       probabilities: spread($rc; $rp; ["internal-only", "user-visible"])}
      },
      usage: {input_tokens: 712, output_tokens: 48}
    }' > "$RESPONSE"
}

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run <exit-var> <out-var> <err-var> [args...]
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

run_without_curl() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$NO_CURL_BIN" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

KEY='test-key-4a7b1c2d-never-on-argv'
code='' out='' err=''

# --- absent key: off, silent on stdout, no network ----------------------------
reset_log
write_response ready-for-agent 0.91 internal-only 0.88
run code out err --state "$STATE" --questions "$QUESTIONS"
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'classify: off (TYPESAFE_API_KEY absent from the environment and' "absent key explains itself on stderr"
assert_absent "$LOG/argv" "absent key never calls curl"
pass "absent key is off: one stderr line, exit 0, no network call"

# --- .env key, and the environment wins over it -------------------------------
printf '%s\n' '# local secrets' "export TYPESAFE_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
reset_log
run code out err --state "$STATE" --questions "$QUESTIONS"
expect_code 0 "$code" ".env key resolves"
assert_contains "$out" '  status: clear' ".env key produces a clear result"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" ".env key reaches curl on the fd header"
reset_log
TYPESAFE_API_KEY=env-wins run code out err --state "$STATE" --questions "$QUESTIONS"
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "environment key wins over .env"
rm -f "$HOME_DIR/.env"
pass "TYPESAFE_API_KEY= in .env activates the tool; the environment wins over it"

# --- clear: request shape, secret handling, every answer reported -------------
reset_log
write_response ready-for-agent 0.91 internal-only 0.88
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --questions "$QUESTIONS"
expect_code 0 "$code" "clear exits 0"
assert_contains "$out" 'classify:' "TOON block header"
assert_contains "$out" '  status: clear' "every answer above the floor is a clear block"
assert_contains "$out" '  model: jev-1.13.0' "the answering model is reported"
assert_contains "$out" '  tokens: 712/48' "usage is reported"
assert_contains "$out" '  floor: 0.6' "the floor in force is reported"
assert_contains "$out" '  answer: label  choice: ready-for-agent  confidence: 0.91  -> clear' "the label answer and its verdict"
assert_contains "$out" '  answer: blast_radius  choice: internal-only  confidence: 0.88  -> clear' "the second question rides the same round trip"
assert_contains "$out" '  probabilities: label  ready-for-agent=0.91' "full probabilities are printed per question"
assert_contains "$out" '  probabilities: blast_radius  internal-only=0.88' "probabilities are printed for every question"
argv=$(cat "$LOG/argv")
assert_not_contains "$argv" "$KEY" "the key never appears on curl argv"
assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "the request uses the fixed typesafe.ai endpoint"
assert_contains "$argv" $'--max-time\n5' "the request uses the fixed five-second timeout"
assert_contains "$argv" '@/dev/fd/3' "the header is read from a file descriptor"
assert_equals 'curl:clean' "$(cat "$LOG/child-env")" "the API key is absent from every child environment"
body=$(cat "$LOG/body")
assert_equals 'jev-latest' "$(jq -r .model <<<"$body")" "default model is jev-latest"
assert_equals 'Pager shows one row too many' "$(jq -r .state.issue.title <<<"$body")" "the state rides verbatim"
assert_equals '["blast_radius","label"]' "$(jq -c '.questions | keys' <<<"$body")" "both questions ride one call"
assert_equals '["needs-info","ready-for-agent","wontfix"]' "$(jq -c '.questions.label.criteria | keys' <<<"$body")" "criteria ride verbatim"
pass "clear: one request carrying every question, key on the fd header only, each answer reported"

# --- the floor separates clear from ambiguous ---------------------------------
reset_log
write_response ready-for-agent 0.55 internal-only 0.88
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --questions "$QUESTIONS"
expect_code 0 "$code" "a below-floor answer still exits 0"
assert_contains "$out" '  status: ambiguous' "one below-floor answer makes the block ambiguous"
assert_contains "$out" '  answer: label  choice: ready-for-agent  confidence: 0.55  -> ambiguous' "the below-floor answer is named ambiguous"
assert_contains "$out" '  answer: blast_radius  choice: internal-only  confidence: 0.88  -> clear' "the other answer keeps its own verdict"
reset_log
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --questions "$QUESTIONS" --floor 0.5
assert_contains "$out" '  status: clear' "a lower floor takes the same answer"
assert_contains "$out" '  floor: 0.5' "the floor in force is the one passed"
reset_log
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --questions "$QUESTIONS" --floor 0.95
assert_contains "$out" '  answer: blast_radius  choice: internal-only  confidence: 0.88  -> ambiguous' "a higher floor escalates a previously clear answer"
pass "the confidence floor decides clear versus ambiguous, and --floor moves it"

# --- exactly-at-the-floor is clear --------------------------------------------
reset_log
write_response ready-for-agent 0.6 internal-only 0.6
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --questions "$QUESTIONS"
assert_contains "$out" '  status: clear' "confidence exactly at the floor is taken, not escalated"
pass "the floor is inclusive: at the floor the answer is taken"

# --- the triage preset ---------------------------------------------------------
PRESET_RESPONSE="$TMP_ROOT/preset-response.json"
jq -n '{
  model: "jev-1.13.0",
  answers: {label: {choice: "ready-for-human", confidence: 0.98,
    probabilities: {"needs-triage": 0.0, "needs-info": 0.01, "ready-for-agent": 0.01,
                    "ready-for-human": 0.98, "wontfix": 0.0}}},
  usage: {input_tokens: 700, output_tokens: 32}
}' > "$PRESET_RESPONSE"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_RESPONSE="$PRESET_RESPONSE" run code out err --state "$STATE" --preset triage
expect_code 0 "$code" "the preset path exits 0"
assert_contains "$out" '  answer: label  choice: ready-for-human  confidence: 0.98  -> clear' "the preset answers the triage label question"
assert_equals '["label"]' "$(jq -c '.questions | keys' <<<"$(cat "$LOG/body")")" "the preset asks exactly one question"
preset=$(jq -c '.questions' "$LOG/body")
assert_equals '["needs-info","needs-triage","ready-for-agent","ready-for-human","wontfix"]' \
  "$(jq -c '.label.criteria | keys' <<<"$preset")" "the triage preset offers the canonical five labels"
assert_equals 'choice' "$(jq -r '.label.type' <<<"$preset")" "the preset question is a Choice"
assert_equals 'true' "$(jq -r '[.label.criteria[] | length > 0] | all' <<<"$preset")" "every label declares the condition under which it is right"
reset_log
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --preset triage --questions "$QUESTIONS"
expect_code 2 "$code" "--preset with --questions is a usage error"
assert_contains "$err" 'mutually exclusive' "the conflict is named"
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --preset nosuch
expect_code 2 "$code" "an unknown preset is a usage error"
assert_contains "$err" 'unknown preset: nosuch' "the unknown preset is named"
pass "the triage preset offers the canonical five labels and is what the request carries"

# --- stdin input ----------------------------------------------------------------
reset_log
write_response ready-for-agent 0.91 internal-only 0.88
out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=$KEY \
  "$TOOL" --state - --preset triage < "$STATE" 2>/dev/null)
assert_equals 'Pager shows one row too many' "$(jq -r .state.issue.title <<<"$(cat "$LOG/body")")" "--state - reads the state from stdin"
TYPESAFE_API_KEY=$KEY run code out err --state - --questions -
expect_code 2 "$code" "two stdin inputs is a usage error"
assert_contains "$err" 'only one of --state and --questions may read stdin' "the stdin conflict is named"
pass "--state - and --questions - read stdin, and only one of them may"

# --- malformed input is an actionable exit 2 ------------------------------------
BAD="$TMP_ROOT/bad.json"
printf 'not json\n' > "$BAD"
TYPESAFE_API_KEY=$KEY run code out err --state "$BAD" --preset triage
expect_code 2 "$code" "a non-JSON state is a configuration error"
assert_contains "$err" 'state is not JSON' "the bad state is named"
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --questions "$BAD"
expect_code 2 "$code" "a non-JSON question set is a configuration error"
assert_contains "$err" 'questions is not JSON' "the bad question set is named"
while IFS='|' read -r json fragment; do
  [ -n "$json" ] || continue
  printf '%s\n' "$json" > "$BAD"
  TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --questions "$BAD"
  expect_code 2 "$code" "malformed questions is a configuration error: $fragment"
  assert_contains "$err" "$fragment" "malformed questions names the problem: $fragment"
done <<'CASES'
{}|questions must declare at least one question
{"q": {"type": "rank", "instructions": "x", "criteria": {"a": "A", "b": "B"}}}|each question needs type "choice"
{"q": {"type": "choice", "instructions": "", "criteria": {"a": "A", "b": "B"}}}|each question needs non-empty instructions
{"q": {"type": "choice", "instructions": "x", "criteria": {"a": "A"}}}|each question needs at least two criteria
{"q": {"type": "choice", "instructions": "x", "criteria": {"a": "A", "b": ""}}}|each criterion needs a non-empty condition
CASES
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --preset triage --floor 1.5
expect_code 2 "$code" "a floor above 1 is a configuration error"
assert_contains "$err" '--floor must be a number from 0 through 1' "the bad floor is named"
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --preset triage --floor high
expect_code 2 "$code" "a non-numeric floor is a configuration error"
TYPESAFE_API_KEY=$KEY run code out err --preset triage
expect_code 2 "$code" "a missing state is a configuration error"
assert_contains "$err" '--state required' "the missing state is named"
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE"
expect_code 2 "$code" "a missing question set is a configuration error"
assert_contains "$err" '--questions or --preset required' "the missing question set is named"
pass "malformed or missing input exits 2 and is never selected around"

# --- never-send list withholds the request --------------------------------------
NEVER_SEND="$HOME_DIR/config/dispatch-never-send"
printf '%s\n' '# Client names' 'one row too many' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --preset triage
expect_code 0 "$code" "a never-send match exits 0"
assert_equals '' "$out" "a never-send match prints nothing on stdout"
assert_contains "$err" 'classify: off (' "a never-send match says the tool is off"
assert_contains "$err" 'nothing sent)' "a never-send match says nothing was sent"
assert_not_contains "$err" 'one row too many' "the diagnostic never prints the listed value"
assert_absent "$LOG/argv" "a never-send match never calls curl"
rm -f "$NEVER_SEND"
mkdir -p "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err --state "$STATE" --preset triage
expect_code 0 "$code" "an unreadable never-send list exits 0"
assert_equals '' "$out" "an unreadable never-send list prints nothing on stdout"
assert_contains "$err" 'is not a readable regular file' "the unreadable list is named"
assert_absent "$LOG/argv" "an unreadable never-send list never calls curl"
rmdir "$NEVER_SEND"
pass "the never-send list withholds the request without naming the listed value"

# --- API, response, and environment failures are error outcomes, exit 0 ---------
reset_log
run_without_curl code out err --state "$STATE" --preset triage
expect_code 0 "$code" "missing curl exits 0"
assert_contains "$out" '  status: error' "missing curl is an error outcome"
assert_contains "$out" '  reason: curl not installed' "missing curl is named"
reset_log
write_response ready-for-agent 0.91 internal-only 0.88
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=503 run code out err --state "$STATE" --questions "$QUESTIONS"
expect_code 0 "$code" "a non-200 exits 0"
assert_contains "$out" '  status: error' "a non-200 is an error outcome"
assert_contains "$out" '  reason: http 503' "the status code is named"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_FAIL=1 run code out err --state "$STATE" --questions "$QUESTIONS"
expect_code 0 "$code" "a curl failure exits 0"
assert_contains "$out" '  reason: http 000' "a transport failure is reported as http 000"
pass "API and environment failures are structured error outcomes that exit 0"

# --- an answer that is not a well-formed Choice is an error outcome -------------
BAD_RESPONSE="$TMP_ROOT/bad-response.json"
while IFS='|' read -r program label; do
  [ -n "$program" ] || continue
  write_response ready-for-agent 0.91 internal-only 0.88
  jq "$program" "$RESPONSE" > "$BAD_RESPONSE"
  reset_log
  TYPESAFE_API_KEY=$KEY FAKE_CURL_RESPONSE="$BAD_RESPONSE" run code out err --state "$STATE" --questions "$QUESTIONS"
  expect_code 0 "$code" "$label exits 0"
  assert_contains "$out" '  status: error' "$label is an error outcome"
  assert_contains "$out" '  reason: response is not a Choice answer for every question' "$label is named"
done <<'CASES'
del(.answers.blast_radius)|a missing answer for a declared question
.answers.label.confidence = 2|a confidence outside 0..1
.answers.label.probabilities = {"ready-for-agent": 1.0}|probabilities missing a declared option
.answers.label.probabilities["extra"] = 0.0|probabilities carrying an undeclared option
.answers.label.probabilities["ready-for-agent"] = 0.2|probabilities that do not sum to one
.answers.label.choice = 7|a non-string choice
.answers.label.choice = "ready_for_agent"|a choice outside the declared options
.usage.input_tokens = "many"|non-numeric usage
CASES
pass "every declared question must come back as a well-formed Choice answer over its own options"

printf '# all fm-classify-jev tests passed\n'
