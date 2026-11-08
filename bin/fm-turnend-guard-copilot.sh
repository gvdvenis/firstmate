#!/usr/bin/env bash
# GitHub Copilot CLI agentStop adapter for the primary turn-end guard.
#
# Registered in tracked .github/hooks/firstmate-primary.json. bin/fm-turnend-guard.sh
# stays the single owner of the block decision and its banner; this adapter only
# translates its exit status 2 into Copilot's own decision object:
#   {"decision":"block","reason":"..."}
# Exit status 2 from an agentStop hook only prints a warning line and does not
# continue the turn (verified, copilot 1.0.105).
#
# The block is bounded to once per turn: Copilot sets stop_hook_active on the stop
# that follows a block, and the shared guard allows that stop. This adapter never
# parks or waits, because a parked Copilot pane ignores typing, Escape, Ctrl-C and
# /exit until the hook returns (docs/verification/copilot.md "Parked hooks").
#
# The guard reads a synthesized payload that deliberately carries no `timestamp`,
# so bin/fm-hook-host-lib.sh does not take it for the Claude-shaped duplicate that
# Copilot delivers from .claude/settings.json and stand the guard down.
#
# Scoped to a genuine primary home through bin/fm-primary-scope-lib.sh, because a
# worker's trusted worktree loads this tracked registration too. Payloads raised
# by a subagent (they carry parentAgentId) are skipped. Malformed or empty input,
# a missing jq, and a failed guard all allow the stop: this adapter prints nothing
# and exits 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_ROOT}/state}
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
SYNTH=$(printf '%s' "$PAYLOAD" | jq -ce '
  select(type == "object" and (has("parentAgentId") | not))
  | {stop_hook_active: (.stop_hook_active // false)}
' 2>/dev/null) || exit 0

REASON=$(printf '%s' "$SYNTH" | "$SCRIPT_DIR/fm-turnend-guard.sh" 2>&1 >/dev/null)
[ "$?" -eq 2 ] || exit 0
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
fm_operational_input_encode turn-end-guard "$REASON" ENCODED || exit 0
jq -cn --arg r "$ENCODED" '{decision:"block",reason:$r}' 2>/dev/null || true
exit 0
