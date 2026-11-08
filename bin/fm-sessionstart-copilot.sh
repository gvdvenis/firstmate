#!/usr/bin/env bash
# GitHub Copilot CLI session-open adapter: the RUN tier transport for Copilot.
#
# Registered in tracked .github/hooks/firstmate-primary.json for Copilot's
# `sessionStart` hook. It is a thin transport around bin/fm-sessionstart-run.sh,
# which remains the single owner of source routing, eligibility, and the digest
# itself.
#
# Copilot puts a sessionStart hook's `{"additionalContext":"..."}` stdout in
# front of the model before its first reply (docs/verification/copilot.md). The
# hook fires at the first prompt, not at launch, and its payload carries the
# `source` (`new`, `resume`) that the run wrapper routes, so this adapter reads
# it from stdin; `--source` overrides it for a registration that knows better.
#
# In a linked crewmate worktree or a foreign checkout fm-sessionstart-run.sh
# stands down silently and this adapter prints nothing.
#
# Every path exits 0 and prints either nothing or one JSON object, so a failed
# session start reaches the agent as digest text and never blocks the session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE=
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE=${2:-}
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    *) shift ;;
  esac
done

if [ -z "$SOURCE" ] && [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  SOURCE=$(cat 2>/dev/null | jq -r '(.source // empty) | strings' 2>/dev/null || true)
fi

DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source "${SOURCE:-startup}" </dev/null 2>/dev/null || true)
[ -n "$DIGEST" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -cn --arg c "$DIGEST" '{additionalContext:$c}' 2>/dev/null || true
exit 0
