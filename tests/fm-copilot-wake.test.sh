#!/usr/bin/env bash
# Portable regression for bin/fm-copilot-wake.sh: the typed wake for an idle
# GitHub Copilot CLI primary. A real tmux pane on a private socket runs a stand-in
# that draws Copilot's rule-box composer (tests/captures/copilot-1.0.105-tmux) and
# logs every submitted line, and a real watcher drives the first wake. Vendor
# facts are recorded in docs/verification/copilot.md; no Copilot install is needed.
# shellcheck disable=SC2016 # single-quoted conditions are expanded by wait_until's eval
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-copilot-wake)
REAL_TMUX=$(command -v tmux)
SOCKET="copilot-wake-$$"
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
WAKE="$ROOT/bin/fm-copilot-wake.sh"
SUBMITTED="$TMP_ROOT/submitted"
FOOTER="$TMP_ROOT/footer"
MODE="$TMP_ROOT/mode"
DROP="$TMP_ROOT/drop-enters"
GEN_RING=0
WAKE_PID=

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup_all() {
  [ -z "$WAKE_PID" ] || kill "$WAKE_PID" 2>/dev/null
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_all EXIT

SHIM="$TMP_ROOT/shim"
mkdir -p "$SHIM" "$STATE" "$HOME_DIR/bin"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"
export PATH="$SHIM:$PATH"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
git init -q "$HOME_DIR"
: > "$HOME_DIR/AGENTS.md"
export FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_GUARD_GRACE=300
export FM_COPILOT_WAKE_POLL=1 FM_COPILOT_WAKE_GRACE=2 FM_COPILOT_WAKE_MAX=3 FM_COPILOT_WAKE_INTERRUPT_GRACE=3 FM_COPILOT_WAKE_START_WAIT=30

: > "$SUBMITTED"
printf ' Working · 130 B esc esc interrupt\n' > "$FOOTER"
printf 'box\n' > "$MODE"
printf '0\n' > "$DROP"

# Argv[0] `copilot` is what bin/fm-agent-process-lib.sh reads as the live agent.
cat > "$TMP_ROOT/pane.sh" <<'SH'
#!/usr/bin/env bash
dir=$1
buf=
rule=$(printf '─%.0s' $(seq 1 60))
draw() {
  printf '\033[2J\033[H'
  case "$(cat "$dir/mode")" in
    box) printf '  <worktree>\n%s\n❯ %s\n%s\n%s\n' "$rule" "$buf" "$rule" "$(cat "$dir/footer")" ;;
    *) printf 'Pick something\n  1. one\n  2. two\n' ;;
  esac
}
while :; do
  draw
  if IFS= read -rsn1 -t 0.2 ch; then
    case "$ch" in
      '')
        drop=$(cat "$dir/drop-enters")
        if [ "$drop" -gt 0 ]; then
          printf '%s\n' "$((drop - 1))" > "$dir/drop-enters"
        else
          printf '%s\n' "$buf" >> "$dir/submitted"
          buf=
        fi
        ;;
      $'\x15') buf= ;;
      *) buf=$buf$ch ;;
    esac
  fi
done
SH
chmod +x "$TMP_ROOT/pane.sh"
# shellcheck disable=SC2016 # expanded by the pane's own bash
LC_ALL=C.UTF-8 tmux new-session -d -s lab -n main -x 100 -y 20 "bash -c 'exec -a copilot bash \"\$0\" \"\$1\"' $TMP_ROOT/pane.sh $TMP_ROOT"
tmux new-window -d -t lab:1 'sleep 600'
export FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=lab:main

count() { grep -c 'operational input waiting' "$SUBMITTED" 2>/dev/null; }
hook() { printf '{"sessionId":"s"%s}' "${3:-}" | "$WAKE" turn "$1" "$2"; }
row() {  # one queued wake with a fresh sequence number
  GEN_RING=$((GEN_RING + 1))
  printf '%s\t%s\tsignal\tk\tp\n' "$(date +%s)" "$((1000 + GEN_RING))" >> "$STATE/.wake-queue"
}
clear_queue() { : > "$STATE/.wake-queue"; }
wait_until() {  # <seconds> <bash condition>
  local end=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    eval "$2" && return 0
    sleep 0.2
  done
  return 1
}
expect_no_ring_for() {  # <seconds> <from-count> <label>
  ! wait_until "$1" "[ \"\$(count)\" -gt $2 ]" || fail "$3: a wake was typed, submitted: $(cat "$SUBMITTED")"
}
pane_text() { tmux capture-pane -p -t lab:main; }

out=$("$WAKE" start 2>&1) || fail "start failed: $out; log: $(cat "$STATE/.copilot-wake.log" 2>/dev/null)"
case "$out" in 'copilot wake: running pid='*) ;; *) fail "start must report a running process: $out" ;; esac
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")
out=$("$WAKE" start 2>&1) || fail "a second start failed: $out"
[ "$(cat "$STATE/.copilot-wake.lock/pid")" = "$WAKE_PID" ] || fail "a second start replaced the running process"
pass "fm-copilot-wake start: confirms a live watcher and is idempotent"

printf 'done [at=%s]: lab event\n' "$(date +%s)" >> "$STATE/lab1.status"
: > "$STATE/lab1.meta"
wait_until 30 '[ -s "$STATE/.wake-queue" ]' || fail "the real watcher did not queue the status line; log: $(cat "$STATE/.copilot-wake.log")"
expect_no_ring_for 5 0 "a running turn"
pass "fm-copilot-wake: a wake waits while the busy record and footer both show a turn running"

hook idle agent-stop
wait_until 15 '[ "$(count)" -ge 1 ]' || fail "an idle pane was never woken; log: $(cat "$STATE/.copilot-wake.log")"
line=$(sed -n 1p "$SUBMITTED")
kind=$(printf '%s' "$line" | FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-operational-input.sh" doorbell-kind) || fail "not a verifiable doorbell: $line"
[ "$kind" = watcher ] || fail "the doorbell record must be a watcher input: $kind"
pass "fm-copilot-wake: a real watcher event reaches an idle pane as a watcher doorbell"

hook busy user-prompt-submit
wait_until 15 '[ "$(cat "$STATE/.watch.lock/pid" 2>/dev/null)" != "" ]' || fail "the watcher was not re-armed after its close"
fm_pid=$(cat "$STATE/.watch.lock/pid")
kill -0 "$fm_pid" 2>/dev/null || fail "no live watcher after the wake closed the first cycle"
pass "fm-copilot-wake: the watcher runs again after the wake's close"

hook idle agent-stop
n=$(count)
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "an unacknowledged wake was not re-rung"
pass "fm-copilot-wake: an unacknowledged wake is re-rung"

clear_queue
sleep 1
n=$(count)
expect_no_ring_for 5 "$n" "an acknowledged queue"
pass "fm-copilot-wake: an acknowledged queue stops the rings"

tmux send-keys -t lab:main -l 'half written'
wait_until 5 'pane_text | grep -q "half written"' || fail "the draft did not reach the composer"
row
n=$(count)
expect_no_ring_for 5 "$n" "a half-written operator line"
pane_text | grep -q '❯ half written$' || fail "the operator's draft changed: $(pane_text)"
tmux send-keys -t lab:main C-u
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the wake was lost after the draft cleared"
grep -q 'half written' "$SUBMITTED" && fail "the wake merged with the draft: $(cat "$SUBMITTED")"
pass "fm-copilot-wake: a half-written line defers the wake, stays intact, and the wake lands after it clears"

clear_queue
printf 'picker\n' > "$MODE"
sleep 1
row
n=$(count)
expect_no_ring_for 5 "$n" "an unrecognized screen"
printf 'box\n' > "$MODE"
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the wake was lost after the picker closed"
pass "fm-copilot-wake: an unrecognized screen defers the wake"

clear_queue
printf '5\n' > "$DROP"
row
n=$(count)
wait_until 20 'pane_text | grep -q "operational input waiting"' || fail "the doorbell was never typed"
wait_until 20 '[ "$(cat "$DROP")" = 0 ]' || fail "the swallowed Enters were not retried: $(cat "$DROP")"
wait_until 20 "[ \"\$(count)\" -gt $n ]" || fail "the unsent doorbell was never submitted: $(pane_text)"
[ "$(tail -n 1 "$SUBMITTED" | grep -o 'operational input waiting' | wc -l | tr -d ' ')" = 1 ] \
  || fail "a retyped doorbell was concatenated: $(tail -n 1 "$SUBMITTED")"
pass "fm-copilot-wake: a swallowed Enter resubmits the unsent doorbell without retyping it"

clear_queue
hook busy user-prompt-submit
: > "$FOOTER"
sleep 1
row
n=$(count)
wait_until 12 "[ \"\$(count)\" -gt $n ]" || fail "an interrupted turn's stale busy record starved the wake"
pass "fm-copilot-wake: a stale busy record with no busy footer is treated as an interrupted turn"

clear_queue
hook idle agent-stop
sleep 1
n=$(cat "$STATE/.copilot-primary.busy-state")
hook busy user-prompt-submit ',"parentAgentId":"p1"'
[ "$(cat "$STATE/.copilot-primary.busy-state")" = "$n" ] || fail "a subagent's event changed the primary's record"
printf '{}' | FM_ROOT_OVERRIDE="$TMP_ROOT" "$WAKE" turn busy user-prompt-submit
[ "$(cat "$STATE/.copilot-primary.busy-state")" = "$n" ] || fail "a non-primary directory changed the record"
pass "fm-copilot-wake turn: subagent payloads and non-primary directories leave the record alone"

: > "$STATE/.afk"
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process kept running in away mode"
WAKE_PID=
rm -f "$STATE/.afk"
pass "fm-copilot-wake: stands down when away mode starts"

out=$("$WAKE" start 2>&1) || fail "a restart failed: $out"
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")
tmux kill-window -t lab:main
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process outlived its pane"
WAKE_PID=
pass "fm-copilot-wake: stops when its pane is gone"
