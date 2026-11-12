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
# The shim below execs REAL_TMUX, so it must be a binary: a version-manager shim (a script with a
# shebang) first on PATH would resolve back to this test's own shim and recurse without end.
REAL_TMUX=
while IFS= read -r candidate; do
  [ "$(head -c 2 "$candidate" 2>/dev/null)" = '#!' ] || { REAL_TMUX=$candidate; break; }
done < <(type -aP tmux)
[ -n "$REAL_TMUX" ] || { echo "skip: no real tmux binary on PATH (only shebang shims); put the tmux binary's directory first on PATH"; exit 0; }
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
# While $INJECT exists, the first composer read (capture-pane -e) is followed by one typed key: a
# keystroke landing right after the ring's composer read, drawn before the ring goes on.
INJECT="$TMP_ROOT/inject-key"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
"$REAL_TMUX" -L "$SOCKET" "\$@"
rc=\$?
if [ "\$1 \$2" = "capture-pane -e" ] && [ -e "$INJECT" ]; then
  rm -f "$INJECT"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t lab:main -l Q
  sleep 0.5
fi
exit \$rc
SH
chmod +x "$SHIM/tmux"
export PATH="$SHIM:$PATH"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
git init -q "$HOME_DIR"
: > "$HOME_DIR/AGENTS.md"
export FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_GUARD_GRACE=300
export COPILOT_HOME="$TMP_ROOT/copilot-home"
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
    # The cursor rests at the end of the composer line, as in Copilot, so a typed key moves it.
    box) printf '  <worktree>\n%s\n❯ %s\n%s\n%s\033[3;%dH' "$rule" "$buf" "$rule" "$(cat "$dir/footer")" "$((3 + ${#buf}))" ;;
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
: > "$INJECT"
row
n=$(count)
wait_until 15 '[ ! -e "$INJECT" ]' || fail "the key was never injected"
wait_until 15 'grep -q "the composer changed before the doorbell landed" "$STATE/.copilot-wake.log"' \
  || fail "the ring did not refuse after the key landed; log: $(cat "$STATE/.copilot-wake.log")"
pane_text | grep -q '❯ Q$' || fail "the operator's key was not left alone: $(pane_text)"
grep -q 'Q' "$SUBMITTED" && fail "the key merged with the doorbell: $(cat "$SUBMITTED")"
tmux send-keys -t lab:main C-u
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the wake was lost after the refused ring"
pass "fm-copilot-wake: a key landing right after the composer read makes the ring refuse and stay out of the draft"

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

# A long interrupt grace from here on, so only the transcript can end a busy turn early.
kill "$WAKE_PID"
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process ignored TERM"
CODE="$TMP_ROOT/code/bin"
mkdir -p "$CODE"
for f in "$ROOT"/bin/*; do ln -s "$f" "$CODE/$(basename "$f")"; done
rm "$CODE/fm-copilot-wake.sh"
cp "$WAKE" "$CODE/fm-copilot-wake.sh"
export FM_COPILOT_WAKE_INTERRUPT_GRACE=60 FM_COPILOT_WAKE_LOG_MAX=2500
# A date shim whose epoch can be stepped, for the loop's own timers only.
DSHIM="$TMP_ROOT/dshim"
mkdir -p "$DSHIM"
printf '0\n' > "$DSHIM/offset"
REAL_DATE=$(command -v date)
cat > "$DSHIM/date" <<SH
#!/usr/bin/env bash
if [ "\$*" = "+%s" ]; then echo \$(( \$("$REAL_DATE" +%s) + \$(cat "$DSHIM/offset") )); else exec "$REAL_DATE" "\$@"; fi
SH
chmod +x "$DSHIM/date"
# An old log longer than the cap: start appends and trims it to its newest bytes.
for i in $(seq 1 400); do printf 'old-%05d padding padding\n' "$i"; done > "$STATE/.copilot-wake.log"
out=$(PATH="$DSHIM:$PATH" "$CODE/fm-copilot-wake.sh" start 2>&1) || fail "start from the copy failed: $out"
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")
[ "$(wc -c < "$STATE/.copilot-wake.log")" -le 3000 ] || fail "start did not trim the log: $(wc -c < "$STATE/.copilot-wake.log")"
grep -q 'old-00400' "$STATE/.copilot-wake.log" || fail "start must keep the newest old lines"
! grep -q 'old-00001 ' "$STATE/.copilot-wake.log" || fail "start must drop the oldest lines"
for i in $(seq 1 200); do printf 'junk-%05d padding padding padding\n' "$i"; done >> "$STATE/.copilot-wake.log"
wait_until 15 '[ "$(wc -c < "$STATE/.copilot-wake.log")" -le 3000 ]' || fail "the running loop never trimmed its log"
pass "fm-copilot-wake: the log is appended to, and trimmed in place to its newest bytes at start and while running"
sed 's/ring: typed the doorbell/ring U2: typed the doorbell/' "$WAKE" > "$CODE/fm-copilot-wake.sh.new"
chmod +x "$CODE/fm-copilot-wake.sh.new"
mv "$CODE/fm-copilot-wake.sh.new" "$CODE/fm-copilot-wake.sh"
wait_until 15 'grep -q "restarting: script updated" "$STATE/.copilot-wake.log"' || fail "the loop kept running the old script; log: $(cat "$STATE/.copilot-wake.log")"
wait_until 15 'sed -n "/restarting: script updated/,\$p" "$STATE/.copilot-wake.log" | grep -q "started: target"' || fail "the loop did not come back: $(cat "$STATE/.copilot-wake.log")"
[ "$(cat "$STATE/.copilot-wake.lock/pid")" = "$WAKE_PID" ] || fail "the re-executed loop changed pid"
kill -0 "$WAKE_PID" 2>/dev/null || fail "the re-executed loop died"
clear_queue
hook idle agent-stop
sleep 1
row
n=$(count)
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the re-executed loop never rang"
grep -q 'ring U2: typed the doorbell' "$STATE/.copilot-wake.log" || fail "the loop still runs pre-update code: $(cat "$STATE/.copilot-wake.log")"
[ "$(pgrep -fc "$CODE/fm-copilot-wake.sh run")" = 1 ] || fail "more than one wake loop is running"
pass "fm-copilot-wake: a loop re-executes itself under the same pid after its script file is replaced"

clear_queue
hook idle agent-stop
row
n=$(count)
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the first ring never came"
printf -- '-300\n' > "$DSHIM/offset"
wait_until 15 "[ \"\$(count)\" -gt $((n + 1)) ]" || fail "a clock stepped back 300 s held the re-ring"
printf '0\n' > "$DSHIM/offset"
pass "fm-copilot-wake: a backward clock step does not hold the next ring"

TRANSCRIPT="$COPILOT_HOME/session-state/s/events.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"
clear_queue
hook idle agent-stop
: > "$FOOTER"
printf '{"type":"user.message","data":{}}\n{"type":"assistant.turn_end","data":{}}\n{"type":"abort","data":{"reason":"user_abort"}}\n' > "$TRANSCRIPT"
hook busy user-prompt-submit
row
n=$(count)
wait_until 12 "[ \"\$(count)\" -gt $n ]" || fail "an abort in the transcript did not release the wake before the grace"
pass "fm-copilot-wake: a transcript abort rings the wake without waiting out the interrupt grace"

clear_queue
hook idle agent-stop
printf '{"type":"abort","data":{}}\n{"type":"user.message","data":{}}\n' > "$TRANSCRIPT"
hook busy user-prompt-submit
row
n=$(count)
expect_no_ring_for 6 "$n" "a stale abort followed by a new prompt"
printf '{"type":"abort","data":{}}\n' >> "$TRANSCRIPT"
wait_until 12 "[ \"\$(count)\" -gt $n ]" || fail "the new turn's abort did not release the wake"
pass "fm-copilot-wake: an abort older than the newest prompt does not release the wake"

clear_queue
hook idle agent-stop
printf '{"type":"user.message","data":{}}\n' > "$TRANSCRIPT"
hook busy user-prompt-submit
: > "$FOOTER"
touch -d '+1 hour' "$STATE/.copilot-primary.busy-state"
row
n=$(count)
wait_until 12 "[ \"\$(count)\" -gt $n ]" || fail "a busy record dated in the future starved the wake"
pass "fm-copilot-wake: a busy record dated in the future counts as old"

kill -9 "$WAKE_PID"
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process survived kill -9"
clear_queue
hook busy user-prompt-submit
wait_until 20 '[ -n "$(cat "$STATE/.copilot-wake.lock/pid" 2>/dev/null)" ] && [ "$(cat "$STATE/.copilot-wake.lock/pid")" != "$WAKE_PID" ] && kill -0 "$(cat "$STATE/.copilot-wake.lock/pid")" 2>/dev/null' \
  || fail "a prompt did not restart the dead wake process; log: $(tail -n 5 "$STATE/.copilot-wake.log")"
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")
grep -q 'restarting: the wake process was gone at a prompt' "$STATE/.copilot-wake.log" || fail "the restart was not logged"
hook busy user-prompt-submit
sleep 1
[ "$(cat "$STATE/.copilot-wake.lock/pid")" = "$WAKE_PID" ] || fail "a prompt replaced a live wake process"
pass "fm-copilot-wake turn: a prompt restarts a dead wake process once and leaves a live one alone"

: > "$STATE/.afk"
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process kept running in away mode"
WAKE_PID=
rm -f "$STATE/.afk"
pass "fm-copilot-wake: stands down when away mode starts"

# The kill -9 above left a deliberately orphaned watcher; away mode did not close it.
orphan=$(cat "$STATE/.watch.lock/pid" 2>/dev/null)
[ -z "$orphan" ] || kill "$orphan" 2>/dev/null
wait_until 10 '[ -z "$orphan" ] || ! kill -0 "$orphan" 2>/dev/null' || fail "the orphaned watcher ignored TERM"
out=$("$WAKE" start 2>&1) || fail "a restart failed: $out; log: $(tail -n 20 "$STATE/.copilot-wake.log")"
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")
tmux kill-window -t lab:main
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process outlived its pane"
WAKE_PID=
pass "fm-copilot-wake: stops when its pane is gone"
