#!/usr/bin/env bash
# fm-jev-lib.sh - the one typesafe.ai (Jev) System One call path firstmate owns.
#
# Source it from a consumer:
#   # shellcheck source=bin/fm-jev-lib.sh
#   . "$SCRIPT_DIR/fm-jev-lib.sh"
#
# It owns what every System One caller must do identically: the opt-in key
# lookup, the POST that keeps the key off argv, the never-send guard, and the
# Choice-answer validation. bin/fm-dispatch-resolve.sh (one rule question) and
# bin/fm-classify-jev.sh (any declared question set) are its consumers;
# docs/configuration.md "Typed dispatch resolution" owns the operator contract
# both of them publish.
#
# Key handling, which every consumer must preserve:
#   The key lives in one non-exported shell variable and reaches curl as a
#   header read from a file descriptor, never on argv; nothing here prints,
#   logs, or writes it. A consumer copies an environment-provided
#   TYPESAFE_API_KEY into its own private variable and unsets the exported name
#   before it spawns any child, so the secret is absent from child
#   environments; that scrub must happen in the consumer's own prologue,
#   before the first subprocess, so it cannot be done here.
#
# Requires bin/fm-env-lib.sh (fmx_env_get) and bin/fm-timing-lib.sh
# (fm_timing_now_ms) to be sourced by the consumer first.

# Fixed settings shared by every consumer.
FM_JEV_MODEL=jev-latest
FM_JEV_BASE=https://api.typesafe.ai
FM_JEV_TIMEOUT=5
FM_JEV_CONFIDENCE_FLOOR=0.6

# Choice-answer validation, as jq definitions a consumer prepends to its own
# program. The response contract is the same whatever the question asks:
#   jev_answer_ok($a; $choices)  one answer object against its offered options
#   jev_usage_ok                 the optional top-level usage block
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_JEV_ANSWER_JQ='
  def jev_answer_ok($a; $choices):
    ($a | type) == "object" and
    ($a.choice | type) == "string" and
    ($choices | index([$a.choice])) != null and
    ($a.confidence | type) == "number" and
    $a.confidence >= 0 and $a.confidence <= 1 and
    ($a.probabilities | type) == "object" and
    (($a.probabilities | keys | sort) == ($choices | sort)) and
    all($a.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    (($a.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01);
  def jev_usage_ok:
    (has("usage") | not) or
      ((.usage | type) == "object" and
       (.usage.input_tokens | type) == "number" and
       (.usage.output_tokens | type) == "number");
'

# Resolves the opt-in key for $1 (the effective home): this process
# environment's already-copied private value first, then the home's .env,
# matching the Relay and mail-plane contracts. Prints the key on stdout, so it
# reaches the caller through command substitution rather than argv, or prints
# nothing when the caller is opted out.
fm_jev_resolve_key() {
  local home=$1 key=${TYPESAFE_API_KEY_PRIVATE:-}
  if [ -z "$key" ]; then
    key=$(fmx_env_get TYPESAFE_API_KEY "$home/.env")
  fi
  printf '%s' "$key"
}

# Checks every string the built request carries against the never-send list, so
# no text reaches the network unchecked. Returns 0 when the request may be
# sent; returns 1 and sets FM_JEV_NEVER_SEND_REASON when it must not.
# The reason names at most the list line number, never its value or the
# matching text. grep's own stderr is discarded because it can echo the pattern.
#
# <noun> names the checked text in the match reason, so each consumer can say
# what it withheld; it defaults to "brief", the resolver's wording.
#
#   fm_jev_never_send_check <list-path> <request-json> <scratch-file> [<noun>]
FM_JEV_NEVER_SEND_REASON=''
fm_jev_never_send_check() {
  local list_path=$1 request=$2 scratch=$3 noun=${4:-brief} list value n=0 rc
  FM_JEV_NEVER_SEND_REASON=''
  [ -e "$list_path" ] || [ -L "$list_path" ] || return 0
  if ! { [ -f "$list_path" ] && [ -r "$list_path" ]; }; then
    FM_JEV_NEVER_SEND_REASON="$list_path is not a readable regular file"
    return 1
  fi
  # Collapse whitespace runs on both sides so a value the text wraps across
  # lines or spaces differently still matches
  if ! jq -r '.. | strings | gsub("\\s+"; " ")' <<<"$request" > "$scratch" 2>/dev/null; then
    FM_JEV_NEVER_SEND_REASON="could not extract the request text to check"
    return 1
  fi
  if ! list=$(jq -Rr 'gsub("\\s+"; " ")' "$list_path" 2>/dev/null); then
    FM_JEV_NEVER_SEND_REASON="could not read $list_path"
    return 1
  fi
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" "$scratch" 2>/dev/null; rc=$?
    case "$rc" in
      0) FM_JEV_NEVER_SEND_REASON="$noun text matches $list_path line $n"; return 1 ;;
      1) ;;
      *) FM_JEV_NEVER_SEND_REASON="could not check the request text against $list_path line $n"; return 1 ;;
    esac
  done <<<"$list"
  return 0
}

# Posts one built request to System One, writing the body to <response-file>.
# Sets FM_JEV_HTTP to the status code (000 when curl itself failed) and
# FM_JEV_LATENCY_MS to the measured round trip. The key reaches curl only as a
# header read from file descriptor 3.
#
#   fm_jev_post <request-json> <response-file> <key>
FM_JEV_HTTP=''
FM_JEV_LATENCY_MS=null
fm_jev_post() {
  local request=$1 out=$2 key=$3 t0 t1
  t0=$(fm_timing_now_ms)
  FM_JEV_HTTP=$(printf '%s' "$request" | curl -sS --max-time "$FM_JEV_TIMEOUT" -o "$out" -w '%{http_code}' \
    -X POST "$FM_JEV_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$key") \
    --data-binary @- 2>/dev/null) || FM_JEV_HTTP=000
  t1=$(fm_timing_now_ms)
  FM_JEV_LATENCY_MS=$(( t1 - t0 ))
}
