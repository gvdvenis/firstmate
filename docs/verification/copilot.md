# GitHub Copilot CLI worker verification

Verified on 2026-11-04 on Linux (WSL2) with `GitHub Copilot CLI 1.0.105.` through a real pty.
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/copilot.md) owns operating limits; the [spawn header](../../bin/fm-spawn.sh) owns launch mechanics.
Primary, secondmate, and every backend other than tmux and Herdr are unsupported and refused.

## Not exercised

Neither tmux nor Herdr has run a real Copilot pane: this host has no tmux, and Herdr lifecycle commands were out of scope for the task.
Everything vendor-side was observed through a private pty, and the backend side is covered only by the portable regression with simulated process readings and fake executables.
The spawn accepts tmux and Herdr because they share the backend-neutral code that regression pins (argv[0] liveness, the recorded-harness composer read, screen-gated interrupt arming), not because a pane run proved them.
Do not treat either placement as verified until a supervised spawn, steer, interrupt, exit, and cleanup has run on it.

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
