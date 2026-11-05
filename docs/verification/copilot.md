# GitHub Copilot CLI worker verification

Verified on 2026-11-04 on Linux (WSL2) with `GitHub Copilot CLI 1.0.105.` through a real pty.
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/copilot.md) owns operating limits; the [spawn header](../../bin/fm-spawn.sh) owns launch mechanics.
Primary, secondmate, and every backend other than tmux and Herdr are unsupported and refused.
Vendor observations marked as a pty were made through a private pty; the Herdr trial section records what a real pane showed.

## Real Herdr pane trial

On 2026-11-05 a supervised Copilot 1.0.105 ship worker ran in a real Herdr pane: the `fm-spawn.sh` launch, brief pickup, status reports, and the busy and idle hook records all worked.
Steer delivery through `fm-send` started a busy turn on that pane.

- A real pane draws the composer as a block-glyph box (`╻▄▄▄…` above, `┃`-led input rows, `╹▀▀▀…` below), with no `❯`. An empty composer is a bare `┃` and a draft is `┃ text`. The plain pty shape (`❯` between `─` rules) is read as well, and both are pinned by the real captures in `tests/captures/copilot-1.0.105-herdr`.
- The armed footer `esc again to interrupt` stays visible for about 0.5 s after the first Escape (measured by polling the pane), so the control plane sends the second Escape 0.05 s after the first. The armed proof keeps an idle agent out of the rewind picker, which renders `again to rewind`.
- `fm-control interrupt` on a busy turn delivered both presses and the pane printed `Operation cancelled by user` (claim `cancel=unconfirmed`, as for every adapter without a recorded cancel signal).
- `fm-control exit` stopped the agent, and the pane returned to its shell and printed `Resume copilot --resume=<session-id>`.

## Real tmux pane trial

On 2026-11-05 Copilot CLI 1.0.105 ran as a real scout on tmux 3.7c (Linux, WSL2) through `fm-spawn.sh --scout --harness copilot --backend tmux`, in a scratch Firstmate home with a private tmux socket and a local-origin project, so no real fleet state or Herdr was touched.
Every step below used the real control plane against the live pane and found no defect in the adapter:

- **Launch:** the worker started in a never-trusted worktree with no trust dialog, picked up its brief, ran a foreground `sleep 240` shell tool, wrote its report, and appended `done`. `#{pane_current_command}` read `copilot`.
- **Busy record:** `userPromptSubmitted` opened a `copilot-hook` busy record, and `agentStop` closed it after the finished turn.
- **Interrupt:** `fm-control interrupt` on the busy turn returned `interrupt-delivered … verified=agent-alive cancel=unconfirmed`, and the pane printed `Operation cancelled by user` with the composer back to a bare `❯`. As the reference records, `agentStop` does not fire after a cancel, so the busy record stayed open until the next prompt.
- **Exit:** `fm-control exit` returned `stopped`; the pane fell back to its login shell and printed `Resume copilot --resume=<session-id>`.
- **Relaunch:** `fm-control relaunch` (a scout requires `--note`) started a replacement agent in the same window and worktree; it re-armed the busy record, picked up the note, wrote its report, and the record closed at `agentStop`.
- **Teardown:** `fm-teardown.sh` on a finished scout returned the worktree and closed the backlog item. It reported the pane's own login shell as a leaked worktree process and removed it; no `copilot` process survived `/exit` (checked by scanning process working directories before and after).
- **Draft safety:** with `zzdraft words` typed and not submitted, `fm-control exit` refused because the composer holds pending text, and the agent kept running.

On tmux a pane draws the plain rule-bounded `❯` composer with a status row above the top rule, not the Herdr block-glyph box, and both shapes classify correctly.
The real screens are in `tests/captures/copilot-1.0.105-tmux` and pinned by `tests/fm-copilot-harness.test.sh`.
Two incidental observations are not adapter defects: `fm-spawn` and `fm-teardown` printed a "worktree tangle" banner because the code root was itself a feature-branch checkout, and a "watcher down" banner because the scratch home has no supervision cycle.

## Full-suite and live-guard run

SUITE_RESULT_PLACEHOLDER

## Still not exercised

Relaunch after an exit and teardown were exercised on tmux only, not on Herdr.
Subagent turns, native slash skills, and secondmate use were not exercised.

## Reusable guards

```bash
FM_COPILOT_SIGNALS_LIVE=1 bash bin/fm-test-run.sh tests/fm-copilot-signals-live-e2e.test.sh
bash bin/fm-test-run.sh tests/fm-copilot-harness.test.sh
```

The live guard needs a signed-in `copilot`, `python3`, and `jq`, creates its own pty and temporary directory, and spends one small prompt.
An unavailable required tool is reported by the shared `fm_live_gate`; explicit opt-in refuses missing capabilities.
It launches in an untrusted temporary directory, asserts that a real prompt produces `busy copilot-hook`, then the idle transition and turn-end notification, and that `/exit` ends the process with status 0.

## Process identity

A live interactive process reported `comm` `MainThread` (the thread name) and `/proc/<pid>/exe` `~/.local/bin/copilot`, with argv `copilot --no-auto-update`.
No `COPILOT_*` identity variable reached the process environment.
Only argv[0] therefore names the harness, and both the tool-side detector and the liveness classifier match its exact basename `copilot`.

## Hooks

A plugin directory passed with `--plugin-dir` (`plugin.json` plus `hooks/hooks.json`, `{"version":1,"hooks":{...}}` with `{"type":"command","bash":"...","timeoutSec":N}` entries) loaded in both `-p` and interactive runs, once the directory is trusted.
Events observed in an interactive run, in order, each receiving a JSON object on stdin that carries `sessionId`, `timestamp`, and `cwd`:

```text
userPromptSubmitted  {"prompt":"..."}
sessionStart         {"source":"new","initialPrompt":"..."}            (fires after the first prompt, not at launch)
preToolUse           {"toolName":"bash","toolArgs":{...}}
agentStop            {"transcriptPath":"...","stopReason":"end_turn","stop_hook_active":false}
sessionEnd           {"reason":"complete"}   (non-interactive)  /  {"reason":"user_exit"}   (interactive /exit)
```

`agentStop` did not fire when a double Escape cancelled a running shell tool, and `sessionEnd` fired only at exit, so an interrupted turn leaves the busy record open until the next prompt.
The turn-end notification is raised by the generation-bound apply, which the portable regression pins against a stale generation.

## Composer and lifecycle

Screens below are the plain rendering of the captured byte stream; the idle and working composers have the same shape.

```text
────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────
 ← open sidebar · Interactive · Allow All · / commands · ? help      GPT-6 Luna · Medium · (18%)

 ○ Working · 90 B esc esc interrupt                                  GPT-6 Luna · Medium · (18%)
```

A typed draft rendered as `❯ half typed draft` between the same rules, and the idle footer became `Interactive · Allow All · @ files · # issues`.
Text typed while a turn ran was queued (`Queued (1)`).
The first Escape on a running tool rendered `esc again to interrupt`, the second printed `Operation cancelled by user`, and the composer returned to a bare `❯`.
On an idle agent with history the first Escape rendered `esc again to rewind` and the second opened `Rewind to a previous point` with `↑↓ Navigate · Enter Select · Esc Cancel`; with no history it printed `Nothing to rewind yet. Start a conversation first.`
`/exit` printed a usage summary and `Resume copilot --resume=<session-id>` and fired `sessionEnd` with `user_exit`.

## Launch

`copilot --allow-all --no-auto-update -i "<prompt>"` in a never-trusted temporary directory stopped at `Do you trust the files in this folder?` with the prompt unsent, so `--allow-all` alone is not enough.
With `COPILOT_ALLOW_ALL=true` in the environment the same launch showed no dialog, auto-submitted the prompt, and delivered the plugin's hooks (`busy copilot-hook` at 4.0 s, `idle copilot-hook` at 9.5 s).
An earlier observation of "no dialog" came from a directory already in Copilot's trusted-folder list and is withdrawn.
`--model bogus-model` exited at launch with `Error: Model "bogus-model" from --model flag is not available.`
`--reasoning-effort xhigh` on `gpt-6-luna` and `--reasoning-effort max` on `claude-sonnet-5.5` were accepted.
No catalog listing command was found, so the spawn does not pre-validate the model.
