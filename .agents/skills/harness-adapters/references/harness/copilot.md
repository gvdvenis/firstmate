# GitHub Copilot CLI

Copilot is a spawned crewmate/scout TUI adapter on tmux and Herdr only.
Primary and secondmate supervision and every other runtime backend are unsupported and refused. A real Herdr pane has run it; tmux has not.
[Copilot verification](../../../../../docs/verification/copilot.md) owns dated vendor evidence and what the backends have not yet exercised.

## Operating facts

| Fact | Value |
|---|---|
| Launch | `copilot --allow-all --no-auto-update --plugin-dir <state>/<id>.copilot-plugin [--model <id>] [--reasoning-effort <level>] -i "<typed launch envelope>"`; `-i` starts the interactive session and auto-submits the prompt. [`fm-spawn.sh`](../../../../../bin/fm-spawn.sh)'s header owns flags. |
| Autonomy | `--allow-all` grants every tool, path, and URL permission but still shows a folder-trust dialog in a fresh worktree, which holds the `-i` prompt unsent. The launch therefore also sets `COPILOT_ALLOW_ALL=true`, which trusts the directory without prompting and so loads the worktree's own skills, MCP servers, and hooks. Firstmate maps no other permission mode. |
| Model and effort | `--model <id>` takes a catalog id such as `claude-sonnet-5.5`; an unknown id exits at launch with `Model "<id>" from --model flag is not available.` `--reasoning-effort low\|medium\|high\|xhigh\|max` passes through. |
| Busy and turn end | Plugin hooks written by [`fm-copilot-plugin.sh`](../../../../../bin/fm-copilot-plugin.sh): `userPromptSubmitted` opens a turn, `agentStop` and `sessionEnd` close it, written as the `copilot-hook` record in [`fm-busy-lib.sh`](../../../../../bin/fm-busy-lib.sh). A copilot task with no record classifies `unknown missing`. |
| Interrupt | Two Escape presses. On a running turn the first renders `esc again to interrupt` for only about half a second, and the control plane sends the second immediately after that proof (press gap 0.05 s); the turn prints `Operation cancelled by user`. `agentStop` does not fire, so the busy record stays until the next prompt. On an idle agent with history the second press opens a `Rewind to a previous point` picker, which one more Escape closes without restoring. |
| Exit | `/exit`, one Enter; the pane prints a summary and `Resume copilot --resume=<session-id>`. |
| Identity | None published. The kernel process name is the thread name `MainThread`; only argv[0] `copilot` identifies it, matched by exact basename in [`fm-harness.sh`](../../../../../bin/fm-harness.sh) and [`fm-agent-process-lib.sh`](../../../../../bin/fm-agent-process-lib.sh). The spawn clears foreign markers such as `CLAUDECODE`. |
| Composer | Two shapes, each with one footer row below and unchanged while a turn runs: a `❯` row between two full-width `─` rules (a plain pty), and the block-glyph box a real Herdr pane draws (`╻▄▄▄…`, `┃` input rows, `╹▀▀▀…`; empty is a bare `┃`). Read only when the caller names the recorded harness `copilot`, by `_fm_composer_copilot_state` in [`fm-composer-lib.sh`](../../../../../bin/fm-composer-lib.sh); more than one row between the rules reads `pending`, and a picker or dialog reads `unknown`. |
| Herdr | Herdr's own `copilot` integration reports the pane identity and session, so the hooks here carry no Herdr reporting. |
| Skills | Use ordinary text pointing at the installed skill's `SKILL.md`; native slash skill invocation has not been verified. |

## Hook carrier

A plugin directory is the per-task hook channel because every other source is a user or project file (`~/.copilot/hooks`, `.github/hooks` in the worktree).
`--plugin-dir` loads the hooks once the directory is trusted.
The directory holds `plugin.json` and `hooks/hooks.json` and is retired by relaunch and removed whole by teardown.
A raw launch command carries no `--plugin-dir`, so nothing is armed for it.

## Limits

Early provider or build errors can leave the spawn-owned busy record open when `agentStop` does not run; inspect the visible pane and use the ordinary recovery procedure.
Typing while a turn runs queues the line (`Queued (1)`) rather than failing, so a draft is detectable but an in-flight steer is not refused.
Subagent turns were not exercised, so whether `agentStop` fires once per prompt when subagents run is unproven.
No primary Stop guard, pre-tool protection, watcher protocol, or secondmate hook was verified.
