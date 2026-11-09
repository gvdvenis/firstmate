#!/usr/bin/env bash
# Wake an idle GitHub Copilot CLI primary when the watcher has an event.
#
# Copilot has no asynchronous rewake, and a parked agentStop hook leaves the pane
# deaf to typing, Escape, Ctrl-C and /exit (docs/verification/copilot.md "Parked
# hooks"), so nothing waits inside a turn boundary. This one detached process
# keeps bin/fm-watch-arm.sh running as a tracked child and, while the durable
# wake queue holds an unacknowledged row, types the record-backed doorbell owned
# by bin/fm-operational-input.sh into the primary's own pane. Every typed prompt
# resets Copilot's cap of eight stop-hook continuations, so a chain of wakes is
# not capped.
#
# Usage:
#   fm-copilot-wake.sh start              start or find the wake process and
#                                         confirm a live watcher; one status line
#   fm-copilot-wake.sh run                the loop itself (start launches it)
#   fm-copilot-wake.sh turn <busy|idle> <event>
#                                         record a turn boundary from a native
#                                         hook; the payload is on stdin
#
# A ring needs both of these to pass, each from its existing owner:
#   - no turn runs: the busy record says idle (bin/fm-busy-lib.sh, written by the
#     tracked userPromptSubmitted, agentStop and sessionEnd hooks through the
#     `turn` subcommand). agentStop never fires on an interrupted turn, so a
#     record that has said busy for FM_COPILOT_WAKE_INTERRUPT_GRACE seconds also
#     passes when the pane no longer draws Copilot's busy footer
#     (fm_busy_lines_match in bin/fm-composer-lib.sh);
#   - the composer reads exactly `empty` (bin/fm-composer-lib.sh). A half-written
#     operator line reads `pending` and an unrecognized screen, such as a picker,
#     reads `unknown`; both wait. Terminal input has no compare-and-type, so a
#     keystroke landing in the instant between this check and the typed line can
#     still merge with it.
#
# The queue is the only delivery proof. A row stays until the session acknowledges
# it with bin/fm-wake-drain.sh --ack-through, so a wake that waits, a doorbell
# whose Enter is swallowed, and a crash of this process lose nothing. An
# unacknowledged head row is re-rung after FM_COPILOT_WAKE_GRACE seconds, doubling
# up to FM_COPILOT_WAKE_MAX; a new head row starts over. A doorbell left unsent in
# the composer gets Enter only and is never retyped.
#
# It stands down when away mode starts, whose daemon owns the watcher, and when
# the pane's agent exits. A tmux or Herdr pane is supported, found through
# bin/fm-supervisor-target-lib.sh; start refuses any other backend. Its log is
# state/.copilot-wake.log.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
# The busy-contract id of the primary's turn record; a dotfile so no *.meta or
# task glob ever reads it as a task.
ID=.copilot-primary
LOCK="$STATE/.copilot-wake.lock"
LOG="$STATE/.copilot-wake.log"

POLL=${FM_COPILOT_WAKE_POLL:-2}
RING_GRACE=${FM_COPILOT_WAKE_GRACE:-60}
RING_MAX=${FM_COPILOT_WAKE_MAX:-1800}
INTERRUPT_GRACE=${FM_COPILOT_WAKE_INTERRUPT_GRACE:-120}
START_WAIT=${FM_COPILOT_WAKE_START_WAIT:-30}
case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
case "$RING_GRACE" in ''|*[!0-9]*|0) RING_GRACE=60 ;; esac
case "$RING_MAX" in ''|*[!0-9]*|0) RING_MAX=1800 ;; esac
case "$INTERRUPT_GRACE" in ''|*[!0-9]*) INTERRUPT_GRACE=120 ;; esac
case "$START_WAIT" in ''|*[!0-9]*|0) START_WAIT=30 ;; esac

WAKE_BODY='firstmate watcher wake - supervision events are queued. Run bin/fm-wake-drain.sh first, handle every wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. bin/fm-copilot-wake.sh owns watcher continuity, so do not run bin/fm-watch-arm.sh after an ordinary wake.'

usage() {
  sed -n '/^# Usage:/,/^# A ring needs/{ /^# A ring needs/d; s/^# \{0,1\}//; p; }' "$0" >&2
  exit 2
}

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

cmd_turn() {  # <busy|idle> <event>
  local payload
  case "${1:-}" in busy|idle) ;; *) usage ;; esac
  [ -n "${2:-}" ] || usage
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  payload=$(cat 2>/dev/null || true)
  # A subagent raises its own events, and its stop would close the parent's turn.
  case "$payload" in *'"parentAgentId":"'*) return 0 ;; esac
  "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" "$1" --current-gen \
    --source copilot-hook --event "$2" >/dev/null 2>&1 || true
}

load_libs() {
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
  # shellcheck source=bin/fm-busy-lib.sh
  . "$SCRIPT_DIR/fm-busy-lib.sh"
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
}

watcher_live() { fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; }

cmd_start() {
  local backend target pid deadline monitor_was_on=0
  [ -d "$STATE" ] || { echo "copilot wake: FAILED - no state directory at $STATE"; exit 1; }
  load_libs
  if [ -e "$STATE/.afk" ]; then
    echo 'copilot wake: not started - away mode owns supervision'
    return 0
  fi
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if ! fm_pid_alive "$pid"; then
    backend=$(discover_supervisor_backend) || backend=
    target=$(discover_supervisor_target) || target=
    case "$backend" in tmux|herdr) ;; *) backend= ;; esac
    if [ -z "$backend" ] || ! fm_backend_target_exists "$backend" "$target"; then
      echo "copilot wake: FAILED - needs a live tmux or Herdr pane for this session (backend=${backend:-none}, target=${target:-none})"
      exit 1
    fi
    # The caller is a model tool call, so a turn is running right now.
    [ -f "$(fm_busy_gen_path "$STATE" "$ID")" ] \
      || "$SCRIPT_DIR/fm-busy-event.sh" arm "$STATE" "$ID" --state busy --source fm-recovery --event wake-start >/dev/null 2>&1 \
      || { echo 'copilot wake: FAILED - could not arm the turn record'; exit 1; }
    # Its own process group, away from the tool call's pipes, so it outlives the
    # call (the shape bin/fm-claude-stop-autoarm.sh uses for its detached arm).
    case $- in *m*) monitor_was_on=1 ;; esac
    set -m 2>/dev/null || true
    FM_SUPERVISOR_BACKEND=$backend FM_SUPERVISOR_TARGET=$target \
      nohup "$SCRIPT_DIR/fm-copilot-wake.sh" run </dev/null >"$LOG" 2>&1 &
    pid=$!
    [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  fi
  deadline=$(( $(date +%s) + START_WAIT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if watcher_live; then
      echo "copilot wake: running pid=$pid (live watcher pid=$FM_WATCHER_HEALTHY_PID)"
      return 0
    fi
    fm_pid_alive "$pid" || break
    sleep 0.2
  done
  echo "copilot wake: FAILED - no live watcher confirmed; see $LOG"
  exit 1
}

# 0 iff no turn is running; the header owns the interrupted-turn exception.
pane_idle() {
  local verdict
  verdict=$(fm_busy_classify_live "$BACKEND" "$TARGET" copilot "$ID" "$STATE")
  case "$verdict" in
    idle\ *) return 0 ;;
    busy\ *)
      [ "$(fm_path_age "$(fm_busy_record_path "$STATE" "$ID")")" -ge "$INTERRUPT_GRACE" ] || return 1
      fm_backend_capture "$BACKEND" "$TARGET" 12 2>/dev/null | fm_busy_lines_match copilot && return 1
      return 0
      ;;
  esac
  return 1
}

# 0 iff the doorbell was typed, or its unsent copy was given Enter.
ring_once() {
  local composer doorbell verdict
  pane_idle || return 1
  composer=$(FM_COMPOSER_HARNESS=copilot fm_backend_composer_state "$BACKEND" "$TARGET" 2>/dev/null)
  case "$composer" in
    empty) ;;
    pending)
      [ -n "$LAST_LINE" ] || return 1
      FM_COMPOSER_HARNESS=copilot fm_task_inbox_composer_holds "$BACKEND" "$TARGET" "$LAST_LINE" || return 1
      fm_backend_send_key "$BACKEND" "$TARGET" Enter >/dev/null 2>&1 || return 1
      log 'ring: resubmitted an unsent doorbell'
      return 0
      ;;
    *) return 1 ;;
  esac
  fm_operational_record_write "$STATE" watcher "$WAKE_BODY" doorbell || return 1
  verdict=$(FM_COMPOSER_HARNESS=copilot fm_backend_send_text_submit "$BACKEND" "$TARGET" "$doorbell" 3 0.5 0.5 2>/dev/null)
  [ "$verdict" != send-failed ] || return 1
  LAST_LINE=$doorbell
  log "ring: typed the doorbell (verdict=${verdict:-none}, head=$RING_HEAD)"
}

ring_tick() {
  local head now delay
  head=$(awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/ { print $2; exit }' "$FM_WAKE_QUEUE" 2>/dev/null)
  if [ "$head" != "$RING_HEAD" ]; then
    RING_HEAD=$head
    RING_COUNT=0
    NEXT_RING=0
  fi
  [ -n "$head" ] || return 0
  now=$(date +%s)
  [ "$now" -ge "$NEXT_RING" ] || return 0
  ring_once || return 0
  delay=$RING_GRACE
  [ "$RING_COUNT" -lt 16 ] && delay=$(( RING_GRACE << RING_COUNT ))
  { [ "$RING_COUNT" -lt 16 ] && [ "$delay" -lt "$RING_MAX" ]; } || delay=$RING_MAX
  RING_COUNT=$((RING_COUNT + 1))
  NEXT_RING=$((now + delay))
}

# fm_backend_tmux_agent_state needs a named session:window, and this target is the
# pane id from $TMUX_PANE, so read the pane's foreground argv[0] list directly;
# a Herdr pane gives the same list through its own process-info read.
# A foreground list without Copilot must repeat before it counts, because a
# transient read can come back empty or partial.
agent_gone() {
  local names name
  if ! fm_backend_target_exists "$BACKEND" "$TARGET"; then
    return 0
  fi
  case "$BACKEND" in
    herdr) names=$(fm_backend_herdr_foreground_argv0s "$TARGET" 2>/dev/null) ;;
    *) names=$(fm_backend_tmux_foreground_argv0s "$TARGET" 2>/dev/null) ;;
  esac
  while IFS= read -r name; do
    [ "${name##*/}" != copilot ] || { GONE_POLLS=0; return 1; }
  done <<NAMES
$names
NAMES
  GONE_POLLS=$((GONE_POLLS + 1))
  [ "$GONE_POLLS" -ge 5 ]
}

# One tracked arm at a time. A close leaves its wake in the durable queue, and
# the next arm names the closed one so it does not announce that wake again.
arm_tick() {
  local status=0
  if [ -n "$ARM_PID" ]; then
    kill -0 "$ARM_PID" 2>/dev/null && return 0
    wait "$ARM_PID" 2>/dev/null || status=$?
    if [ "$status" -eq 0 ]; then
      ARM_FAILS=0
      PREDECESSOR=$ARM_PID
    else
      ARM_FAILS=$((ARM_FAILS + 1))
      PREDECESSOR=
      NEXT_ARM=$(( $(date +%s) + ARM_FAILS * ARM_FAILS ))
      log "arm: closed with status $status (failure $ARM_FAILS)"
    fi
    ARM_PID=
  fi
  [ "$(date +%s)" -ge "$NEXT_ARM" ] || return 0
  if [ -n "$PREDECESSOR" ]; then
    FM_WATCH_PREDECESSOR_ARM_PID=$PREDECESSOR "$SCRIPT_DIR/fm-watch-arm.sh" &
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" &
  fi
  ARM_PID=$!
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup_run() {
  [ -z "$ARM_PID" ] || { kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null; }
  fm_lock_release "$LOCK"
}

cmd_run() {
  load_libs
  BACKEND=${FM_SUPERVISOR_BACKEND:-tmux}
  TARGET=${FM_SUPERVISOR_TARGET:-}
  [ -n "$TARGET" ] || { log 'stopped: no target pane'; exit 1; }
  fm_lock_try_acquire "$LOCK" || { log "already running: pid ${FM_LOCK_HELD_PID:-unknown}"; exit 0; }
  ARM_PID=
  PREDECESSOR=
  ARM_FAILS=0
  NEXT_ARM=0
  RING_HEAD=
  RING_COUNT=0
  NEXT_RING=0
  LAST_LINE=
  GONE_POLLS=0
  trap cleanup_run EXIT
  trap 'exit 0' TERM INT HUP
  log "started: target=$TARGET"
  while :; do
    if [ -e "$STATE/.afk" ]; then
      log 'stopped: away mode owns supervision'
      exit 0
    fi
    if agent_gone; then
      log 'stopped: the pane agent is gone'
      exit 0
    fi
    arm_tick
    ring_tick
    sleep "$POLL"
  done
}

case "${1:-}" in
  start) cmd_start ;;
  run) cmd_run ;;
  turn) shift; cmd_turn "$@" ;;
  *) usage ;;
esac
