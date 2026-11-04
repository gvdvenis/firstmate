#!/usr/bin/env bash
# Credentialed GitHub Copilot CLI worker guard. Opt in with FM_COPILOT_SIGNALS_LIVE=1.
# FM_COPILOT_MODEL optionally chooses a catalog model id (default: the account's own).
# Drives the real copilot binary in a private pty with the plugin that
# bin/fm-copilot-plugin.sh writes, so it needs no multiplexer and touches no
# shared endpoint. It spends one tiny prompt of the caller's own Copilot quota
# and edits nothing under ~/.copilot or the repository.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_COPILOT_SIGNALS_LIVE copilot python3 jq
VERSION="copilot $(copilot --version 2>/dev/null | head -1)"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/cpl.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
trap 'rm -rf "$LAB"' EXIT
fail() { printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
STATE="$LAB/state"
WORK="$LAB/work"
mkdir -p "$STATE" "$WORK"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" live) || fail 'busy arm failed'
"$ROOT/bin/fm-copilot-plugin.sh" "$STATE" live "$gen" || fail 'plugin writer failed'
model_args=()
[ -z "${FM_COPILOT_MODEL:-}" ] || model_args=(--model "$FM_COPILOT_MODEL")

# The driver prints "<comm>\t<argv0>" of the live copilot process once the first
# turn has settled, then types /exit and reports the child's exit status.
driver=$(cat <<'PY'
import os, pty, select, struct, fcntl, termios, sys, time, signal
state, plugin, work = sys.argv[1:4]
extra = sys.argv[4:]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(work)
    os.environ['TERM'] = 'xterm-256color'
    os.execvp('copilot', ['copilot', '--allow-all', '--no-auto-update', '--plugin-dir', plugin] + extra + ['-i', 'Reply with the single word PONG'])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 45, 140, 0, 0))
def pump(t):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                if not os.read(fd, 65536): return False
            except OSError:
                return False
    return True
def settled():
    rec = os.path.join(state, 'live.busy-state')
    try:
        return ' state=idle ' in open(rec).read()
    except OSError:
        return False
deadline = time.time() + 120
while time.time() < deadline and not settled():
    pump(1)
comm = open('/proc/%d/comm' % pid).read().strip()
argv0 = open('/proc/%d/cmdline' % pid, 'rb').read().split(b'\0')[0].decode()
print('%s\t%s' % (comm, argv0), flush=True)
pump(2)
os.write(fd, b'/exit'); pump(1); os.write(fd, b'\r')
pump(15)
try:
    os.kill(pid, signal.SIGKILL)
except OSError:
    pass
PY
)
identity=$(cd "$LAB" && python3 -I -c "$driver" "$STATE" "$STATE/live.copilot-plugin" "$WORK" "${model_args[@]}") \
  || fail 'driver failed'
comm=${identity%%$'\t'*}
argv0=${identity#*$'\t'}
[ "$(fm_agent_process_classify "$comm" "$argv0" "$argv0")" = agent ] \
  || fail "liveness did not recognize the live process (comm=$comm argv0=$argv0)"
echo "ok - $VERSION: live process comm=$comm argv0=$argv0 classified as an agent"
[ "$(fm_busy_classify tmux fake:w copilot live "$STATE")" = 'idle copilot-hook' ] \
  || fail "busy record did not end idle: $(cat "$STATE/live.busy-state" 2>/dev/null)"
assert_present "$STATE/live.turn-ended" 'agentStop raised no turn-end notification'
echo "ok - $VERSION: userPromptSubmitted opened the turn, agentStop closed it and raised the turn-end notification"
