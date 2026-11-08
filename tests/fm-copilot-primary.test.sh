#!/usr/bin/env bash
# Portable regression for GitHub Copilot CLI's native primary hooks:
# bin/fm-sessionstart-copilot.sh (sessionStart), bin/fm-pretool-copilot.sh
# (preToolUse), and their tracked registration .github/hooks/firstmate-primary.json
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
SUB_MEMBERS=',"agentId":"a1","agentType":"task","parentAgentId":"00000000-0000-4000-8000-000000000001"'

install_scripts() {  # <dir>
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs" "$dir/.github/hooks"
  for f in fm-sessionstart-copilot.sh fm-pretool-copilot.sh fm-sessionstart-run.sh \
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

test_sessionstart_emits_additional_context_for_a_new_session
test_sessionstart_routes_the_payload_source
test_sessionstart_unrecognized_source_gets_the_full_digest
test_sessionstart_silent_in_a_worker_worktree
