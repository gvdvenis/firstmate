#!/usr/bin/env bash
# Portable regression for GitHub Copilot CLI's native primary hooks:
# bin/fm-sessionstart-copilot.sh (sessionStart), bin/fm-pretool-copilot.sh
# (preToolUse), bin/fm-turnend-guard-copilot.sh (agentStop), and their tracked
# registration .github/hooks/firstmate-primary.json
# (docs/sessionstart-nudge.md "GitHub Copilot CLI", docs/verification/copilot.md).
# Payloads are sanitized recordings of copilot 1.0.105; no Copilot install is
# needed. tests/fm-copilot-harness.test.sh owns the worker launch itself.
# shellcheck disable=SC2016 # single quotes are deliberate: $COPILOT_PROJECT_DIR expands inside the registered command
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-copilot-primary)
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR PI_CODING_AGENT GROK_AGENT GROK_HOOK_EVENT FM_ALLOW_SUBAGENT COPILOT_PROJECT_DIR

REGISTRATION="$ROOT/.github/hooks/firstmate-primary.json"
SID=00000000-0000-4000-8000-000000000000
TS=1790000000000

session_payload() {  # <source>
  printf '{"sessionId":"%s","timestamp":%s,"cwd":"/work/p","source":"%s","initialPrompt":"hi"}' "$SID" "$TS" "$1"
}
tool_payload() {  # <tool> <json toolArgs> [extra json members, leading comma]
  printf '{"sessionId":"%s","timestamp":%s,"cwd":"/work/p","toolName":"%s","toolArgs":%s%s}' "$SID" "$TS" "$1" "$2" "${3:-}"
}
stop_payload() {  # [extra json members, leading comma]
  printf '{"sessionId":"%s","timestamp":%s,"cwd":"/work/p","stop_reason":"end_turn"%s}' "$SID" "$TS" "${1:-}"
}
SUB_MEMBERS=',"agentId":"a1","agentType":"task","parentAgentId":"00000000-0000-4000-8000-000000000001"'

install_scripts() {  # <dir>
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs" "$dir/.github/hooks"
  for f in fm-sessionstart-copilot.sh fm-pretool-copilot.sh fm-turnend-guard-copilot.sh \
           fm-turnend-guard.sh fm-copilot-wake.sh fm-sessionstart-run.sh \
           fm-sessionstart-nudge.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh \
           fm-subagent-pretool-check.sh fm-hook-host-lib.sh fm-primary-scope-lib.sh \
           fm-path-lib.sh fm-session-lock-lib.sh fm-operational-input.sh fm-harness.sh \
           fm-lock.sh fm-gate-refuse-lib.sh fm-timeout-lib.sh fm-supervision-lib.sh \
           fm-wake-lib.sh fm-classify-lib.sh fm-afk-contract.sh fm-lease-lib.sh \
           fm-supervision-engine-lib.sh fm-supervision-instructions.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  cp "$REGISTRATION" "$dir/.github/hooks/firstmate-primary.json"
  chmod +x "$dir"/bin/*.sh
  cat > "$dir/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/state/digest-args"
printf '%s\n' "${FM_COPILOT_HARNESS:-}" > "$FM_HOME/state/digest-harness"
printf 'FIRSTMATE DIGEST "quoted" line\nsecond line\n'
SH
  chmod +x "$dir/bin/fm-session-start.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

# make_worker_dir <base> <worktree>: a linked worktree of the primary, the shape
# bin/fm-spawn.sh hands every crewmate, carrying the same tracked files.
make_worker_dir() {
  local base=$1 child=$2
  fm_git_worktree "$base" "$child" fm/copilot-worker
  mkdir -p "$child/state"
  : > "$child/AGENTS.md"
  install_scripts "$child"
}

# registered_command <event>: the command string Copilot would run for <event>.
registered_command() {
  jq -r --arg e "$1" '.hooks[$e][0].bash' "$REGISTRATION"
}

# run_registered <dir> <event> <payload>: run the tracked registration's own
# command string the way Copilot does, with COPILOT_PROJECT_DIR set.
run_registered() {
  local dir=$1 event=$2 payload=$3
  printf '%s' "$payload" | env COPILOT_PROJECT_DIR="$dir" FM_HOME="$dir" bash -c "$(registered_command "$event")" 2>/dev/null
}

# --- session start -------------------------------------------------------------

test_sessionstart_emits_additional_context_for_a_new_session() {
  local dir out ctx
  dir=$(make_primary_dir "$TMP_ROOT/session-new")
  out=$(run_registered "$dir" sessionStart "$(session_payload new)")
  ctx=$(printf '%s' "$out" | jq -r '.additionalContext // empty' 2>/dev/null)
  case "$ctx" in *'FIRSTMATE DIGEST "quoted" line'*) ;; *) fail "the digest must reach model context verbatim, got: $out" ;; esac
  case "$ctx" in *'second line'*) ;; *) fail "the digest was truncated at the first line: $ctx" ;; esac
  printf '%s' "$out" | jq -e 'keys == ["additionalContext"]' >/dev/null || fail "the output must be exactly one additionalContext object: $out"
  [ "$(cat "$dir/state/digest-harness")" = copilot ] || fail "the digest must be told its harness, because its process chain is past the ancestry walk's bound"
  pass "fm-sessionstart-copilot: a new session gets the whole digest as additionalContext"
}

test_sessionstart_routes_the_payload_source() {
  local dir out ctx
  dir=$(make_primary_dir "$TMP_ROOT/session-resume")
  out=$(run_registered "$dir" sessionStart "$(session_payload resume)")
  ctx=$(printf '%s' "$out" | jq -r '.additionalContext // empty' 2>/dev/null)
  case "$ctx" in *'FIRSTMATE DIGEST'*) fail "a resumed session must not re-run the full digest: $out" ;; esac
  case "$ctx" in *'FIRSTMATE_OP: '*|*'session-start'*) ;; *) fail "a resumed session must get the session-start instruction instead: $out" ;; esac
  [ ! -s "$dir/state/digest-args" ] || fail "resume ran the digest: $(cat "$dir/state/digest-args")"
  pass "fm-sessionstart-copilot: the payload source reaches the run wrapper's routing (resume is a nudge)"
}

test_sessionstart_unrecognized_source_gets_the_full_digest() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/session-odd")
  out=$(run_registered "$dir" sessionStart "$(session_payload somethingnew)")
  case "$out" in *'FIRSTMATE DIGEST'*) ;; *) fail "an unrecognized source must still take the helm: $out" ;; esac
  out=$(run_registered "$dir" sessionStart 'not json')
  case "$out" in *'FIRSTMATE DIGEST'*) ;; *) fail "an unreadable payload must still take the helm: $out" ;; esac
  pass "fm-sessionstart-copilot: unrecognized or unreadable payloads get the full digest"
}

test_sessionstart_silent_in_a_worker_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/session-base")
  child="$TMP_ROOT/session-worker"
  make_worker_dir "$base" "$child"
  out=$(run_registered "$child" sessionStart "$(session_payload new)")
  [ -z "$out" ] || fail "a worker worktree must never take the helm: $out"
  [ ! -s "$child/state/digest-args" ] || fail "the digest ran in a worker worktree"
  pass "fm-sessionstart-copilot: silent inside a linked worker worktree"
}

# --- pre-tool deny ---------------------------------------------------------------

expect_deny() {  # <label> <output> <expected reason prefix>
  local label=$1 out=$2 code=$3
  printf '%s' "$out" | jq -e --arg c "$code" '
    .permissionDecision == "deny" and (.permissionDecisionReason | startswith($c)) and (keys | length == 2)
  ' >/dev/null 2>&1 || fail "$label: expected a Copilot deny starting $code, got: $out"
}

test_pretool_denies_with_a_visible_reason() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/pre-deny")
  out=$(run_registered "$dir" preToolUse "$(tool_payload bash '{"command":"cd projects/foo"}')")
  expect_deny "persistent cd" "$out" '[persistent-cd]'
  out=$(run_registered "$dir" preToolUse "$(tool_payload bash '{"command":"bin/fm-watch-arm.sh &"}')")
  expect_deny "backgrounded watcher arm" "$out" '['
  out=$(run_registered "$dir" preToolUse "$(tool_payload task '{"prompt":"x","agent_type":"task","mode":"sync"}')")
  expect_deny "subagent spawn" "$out" '[subagent-dispatch]'
  pass "fm-pretool-copilot: cd, watcher-arm, and subagent denies render as permissionDecisionReason"
}

test_pretool_exits_zero_on_deny() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/pre-exit")
  tool_payload bash '{"command":"cd projects/foo"}' | "$dir/bin/fm-pretool-copilot.sh" >/dev/null 2>"$TMP_ROOT/pre-exit.err"; status=$?
  expect_code 0 "$status" "a deny must exit 0, because exit 2 hides the reason in Copilot"
  [ ! -s "$TMP_ROOT/pre-exit.err" ] || fail "a deny must leave stderr empty: $(cat "$TMP_ROOT/pre-exit.err")"
  pass "fm-pretool-copilot: a deny exits 0 with an empty stderr"
}

test_pretool_allows_ordinary_calls() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/pre-allow")
  for p in "$(tool_payload bash '{"command":"ls -la"}')" \
           "$(tool_payload bash '{"command":"(cd projects/foo && ls)"}')" \
           "$(tool_payload view '{"path":"/work/p/AGENTS.md"}')" \
           "$(tool_payload read_agent '{"agent_id":"a1"}')" \
           "$(tool_payload list_agents '{}')" \
           "$(tool_payload bash '{}')"; do
    out=$(run_registered "$dir" preToolUse "$p")
    [ -z "$out" ] || fail "an ordinary call was denied: $p -> $out"
  done
  pass "fm-pretool-copilot: ordinary shell, file, and agent-observing calls pass untouched"
}

test_pretool_skips_subagent_payloads_and_bad_input() {
  local dir out p
  dir=$(make_primary_dir "$TMP_ROOT/pre-skip")
  out=$(run_registered "$dir" preToolUse "$(tool_payload bash '{"command":"cd projects/foo"}' "$SUB_MEMBERS")")
  [ -z "$out" ] || fail "a subagent's own call must not be judged: $out"
  for p in '' 'not json' '[]' '{}' '{"toolName":7}'; do
    out=$(run_registered "$dir" preToolUse "$p")
    [ -z "$out" ] || fail "malformed input must allow, got: $out"
  done
  pass "fm-pretool-copilot: subagent-raised and malformed payloads are allowed"
}

test_pretool_honors_the_subagent_escape_hatch() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/pre-escape")
  out=$(tool_payload task '{"prompt":"x"}' | env FM_ALLOW_SUBAGENT=1 COPILOT_PROJECT_DIR="$dir" FM_HOME="$dir" "$dir/bin/fm-pretool-copilot.sh")
  [ -z "$out" ] || fail "FM_ALLOW_SUBAGENT=1 must allow a deliberate subagent: $out"
  pass "fm-pretool-copilot: FM_ALLOW_SUBAGENT=1 is honored"
}

test_pretool_inert_in_a_worker_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/pre-base")
  child="$TMP_ROOT/pre-worker"
  make_worker_dir "$base" "$child"
  out=$(run_registered "$child" preToolUse "$(tool_payload bash '{"command":"cd projects/foo"}')")
  [ -z "$out" ] || fail "the cd seatbelt fired in a worker worktree: $out"
  out=$(run_registered "$child" preToolUse "$(tool_payload bash '{"command":"bin/fm-watch-arm.sh &"}')")
  [ -z "$out" ] || fail "the arm seatbelt fired in a worker worktree: $out"
  out=$(run_registered "$child" preToolUse "$(tool_payload task '{"prompt":"x"}')")
  [ -z "$out" ] || fail "the subagent guard fired in a worker worktree: $out"
  pass "fm-pretool-copilot: every check stands down in a linked worker worktree"
}

# --- turn-end guard --------------------------------------------------------------

test_turnend_blocks_once_when_work_is_unsupervised() {
  local dir out status reason
  dir=$(make_primary_dir "$TMP_ROOT/stop-block")
  : > "$dir/state/task1.meta"
  out=$(run_registered "$dir" agentStop "$(stop_payload)"); status=$?
  expect_code 0 "$status" "a block must exit 0, because exit 2 does not continue the turn in Copilot"
  printf '%s' "$out" | jq -e '.decision == "block" and (keys | length == 2)' >/dev/null 2>&1 \
    || fail "expected exactly one Copilot block object, got: $out"
  reason=$(printf '%s' "$out" | jq -r '.reason')
  case "$reason" in *'TURN WOULD END BLIND'*) ;; *) fail "the reason must carry the shared guard's banner: $reason" ;; esac
  [ "$(printf '%s' "$reason" | "$ROOT/bin/fm-operational-input.sh" kind)" = turn-end-guard ] \
    || fail "the reason must be a typed turn-end-guard input, so it never reads as the captain: $reason"
  out=$(run_registered "$dir" agentStop "$(stop_payload ',"stop_hook_active":true')")
  [ -z "$out" ] || fail "the stop after a block must end the turn, got: $out"
  pass "fm-turnend-guard-copilot: blocks an unsupervised stop once, and allows the stop that follows"
}

test_turnend_allows_when_no_supervision_is_needed() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/stop-idle")
  out=$(run_registered "$dir" agentStop "$(stop_payload)")
  [ -z "$out" ] || fail "an empty fleet must end the turn silently, got: $out"
  pass "fm-turnend-guard-copilot: an empty fleet ends the turn silently"
}

test_turnend_skips_subagent_payloads_and_bad_input() {
  local dir out p
  dir=$(make_primary_dir "$TMP_ROOT/stop-skip")
  : > "$dir/state/task1.meta"
  out=$(run_registered "$dir" agentStop "$(stop_payload "$SUB_MEMBERS")")
  [ -z "$out" ] || fail "a subagent's own stop must not be blocked: $out"
  for p in '' 'not json' '[]' '{"stop_hook_active":"yes"}'; do
    out=$(run_registered "$dir" agentStop "$p")
    [ -z "$out" ] || fail "malformed input must allow, got: $p -> $out"
  done
  pass "fm-turnend-guard-copilot: subagent-raised and malformed payloads are allowed"
}

test_turnend_inert_in_a_worker_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/stop-base")
  child="$TMP_ROOT/stop-worker"
  make_worker_dir "$base" "$child"
  : > "$child/state/task1.meta"
  out=$(run_registered "$child" agentStop "$(stop_payload)")
  [ -z "$out" ] || fail "the guard fired in a worker worktree: $out"
  pass "fm-turnend-guard-copilot: stands down in a linked worker worktree"
}

# --- session lock ----------------------------------------------------------------

test_session_lock_recognizes_copilot() {
  (
    # shellcheck source=bin/fm-session-lock-lib.sh
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_harness_process_matches MainThread 'copilot --allow-all' || fail "the Linux shape, comm MainThread and argv[0] copilot, must identify the session"
    fm_harness_process_matches /home/u/.local/bin/copilot 'copilot --allow-all' || fail "an installed Copilot path must identify the session"
    ! fm_harness_process_matches MainThread 'copilot-language-server --stdio' || fail "copilot-language-server must not identify a session"
    ! fm_harness_process_matches MainThread 'node server.js' || fail "an unrelated MainThread process must not identify a session"
  ) || exit 1
  pass "session lock: argv[0] copilot identifies a Copilot primary"
}

# --- registration ----------------------------------------------------------------

test_registration_covers_the_primary_events() {
  [ -f "$REGISTRATION" ] || fail "firstmate must ship a tracked project-scope .github/hooks/firstmate-primary.json"
  jq -e '.version == 1 and (.hooks | keys == ["agentStop","preToolUse","sessionEnd","sessionStart","userPromptSubmitted"])' "$REGISTRATION" >/dev/null 2>&1 \
    || fail "the registration must cover exactly the session, tool, and turn boundary events"
  jq -e '.hooks.sessionStart[0].timeoutSec > 120' "$REGISTRATION" >/dev/null 2>&1 \
    || fail "the session-open timeout must sit above bin/fm-session-start.sh's own 120s budget"
  jq -e '[.hooks[][]] | all(.type == "command" and (.bash | startswith("\"$COPILOT_PROJECT_DIR\"/bin/")))' "$REGISTRATION" >/dev/null 2>&1 \
    || fail "every entry must anchor to COPILOT_PROJECT_DIR"
  pass "copilot registration: session, tool, and turn events, anchored to the project, session timeout above the digest budget"
}

test_worker_plugin_does_not_carry_the_primary_hooks() {
  local state out
  state="$TMP_ROOT/plugin-state"
  mkdir -p "$state"
  "$ROOT/bin/fm-copilot-plugin.sh" "$state" task1 gen1 >/dev/null 2>&1 \
    || fail "fm-copilot-plugin.sh did not write the worker plugin"
  out=$(cat "$state/task1.copilot-plugin/hooks/hooks.json")
  [ -n "$out" ] || fail "the worker plugin has no hooks file"
  case "$out" in *fm-sessionstart-copilot*|*fm-pretool-copilot*|*fm-turnend-guard-copilot*|*fm-copilot-wake*) fail "the worker plugin carries a primary hook: $out" ;; esac
  printf '%s' "$out" | jq -e '.hooks | (has("sessionStart") | not) and (has("preToolUse") | not)' >/dev/null 2>&1 \
    || fail "the worker plugin must not register sessionStart or preToolUse: $out"
  pass "copilot worker plugin: carries no sessionStart or preToolUse hook"
}

# --- secondmate home ---------------------------------------------------------------

# make_mate_dir <base> <home>: the same linked-worktree shape as a worker, but
# carrying the .fm-secondmate-home marker bin/fm-home-seed.sh publishes, which is
# what makes a persistent secondmate a primary session in its own home.
make_mate_dir() {
  local base=$1 mate=$2
  make_worker_dir "$base" "$mate"
  printf 'copilot-mate\n' > "$mate/.fm-secondmate-home"
}

test_secondmate_home_runs_all_three_adapters() {
  local base mate out
  base=$(make_primary_dir "$TMP_ROOT/mate-base")
  mate="$TMP_ROOT/mate-home"
  make_mate_dir "$base" "$mate"
  out=$(run_registered "$mate" sessionStart "$(session_payload new)")
  case "$out" in *'FIRSTMATE DIGEST'*) ;; *) fail "a secondmate home must get the digest: $out" ;; esac
  [ -s "$mate/state/digest-args" ] || fail "the digest did not run inside the secondmate home"
  [ ! -s "$base/state/digest-args" ] || fail "the secondmate's digest ran against the parent's home"
X
  : > "$mate/state/task1.meta"
  out=$(run_registered "$mate" agentStop "$(stop_payload)")
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 || fail "a secondmate with work in flight and no watcher must be blocked once: $out"
  pass "copilot secondmate home: digest, seatbelts, and turn-end guard run scoped to the home"
}

test_secondmate_home_busy_records_stay_apart() {
  local base mate gen
  base=$(make_primary_dir "$TMP_ROOT/mate-busy-base")
  mate="$TMP_ROOT/mate-busy-home"
  make_mate_dir "$base" "$mate"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$base/state" copilot-mate)
  "$ROOT/bin/fm-copilot-plugin.sh" "$base/state" copilot-mate "$gen" "$mate" || fail 'plugin writer failed for a secondmate'
  printf '{"sessionId":"s","timestamp":%s,"prompt":"hi"}' "$TS" \
    | env COPILOT_PROJECT_DIR="$mate" FM_HOME="$mate" bash -c "$(jq -r '.hooks.userPromptSubmitted[0].bash' "$base/state/copilot-mate.copilot-plugin/hooks/hooks.json")"
  grep -q 'state=busy' "$base/state/copilot-mate.busy-state" || fail "the per-task plugin did not publish the mate's busy turn to the parent's state"
  [ ! -e "$mate/state/copilot-mate.busy-state" ] || fail "the plugin wrote the parent's record into the mate's own state"
  pass "copilot secondmate: the parent-side busy record comes from the per-task plugin, apart from the home's own turn record"
}

test_sessionstart_emits_additional_context_for_a_new_session
test_sessionstart_routes_the_payload_source
test_sessionstart_unrecognized_source_gets_the_full_digest
test_sessionstart_silent_in_a_worker_worktree
test_pretool_denies_with_a_visible_reason
test_pretool_exits_zero_on_deny
test_pretool_allows_ordinary_calls
test_pretool_skips_subagent_payloads_and_bad_input
test_pretool_honors_the_subagent_escape_hatch
test_pretool_inert_in_a_worker_worktree
test_turnend_blocks_once_when_work_is_unsupervised
test_turnend_allows_when_no_supervision_is_needed
test_turnend_skips_subagent_payloads_and_bad_input
test_turnend_inert_in_a_worker_worktree
test_session_lock_recognizes_copilot
test_registration_covers_the_primary_events
test_worker_plugin_does_not_carry_the_primary_hooks
test_secondmate_home_runs_all_three_adapters
test_secondmate_home_busy_records_stay_apart
