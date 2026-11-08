# GitHub Copilot CLI worker verification

Verified on 2026-11-04 on Linux (WSL2) with `GitHub Copilot CLI 1.0.105.` through a real pty.
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/copilot.md) owns operating limits; the [spawn header](../../bin/fm-spawn.sh) owns launch mechanics.
Primary, secondmate, and every backend other than tmux and Herdr are unsupported and refused.
Vendor observations marked as a pty were made through a private pty; the Herdr trial section records what a real pane showed.

## Unanswerable questions

On 2026-11-07, two real tmux 3.7c panes ran Copilot 1.0.105 with the same prompt, which told the model to use its `ask_user` tool and then append a line to a status file with a shell command.
Without `--no-ask-user` the pane showed `Asking user`, a `Copilot needs information` picker with `red`, `blue`, and `Other (type your answer)`, and waited with no status line written.
With `--no-ask-user` the model reported that no question tool was available, decided alone, appended its status line, and finished with no picker.
`copilot --help` lists the flag as `--no-ask-user` (disable the `ask_user` tool; the agent works autonomously without asking questions).
The shipped launch passes it, and the ordinary shell tool and status-line appends are unaffected.

## Subagent turns

On 2026-11-07, in a real tmux 3.7c pane with Copilot 1.0.105, a worker was told to use its `task` tool to have a subagent run `sleep 20; echo hi`.
The hooks fired in this order: the parent's `userPromptSubmitted`, `preToolUse` for `task`, `subagentStart`, then a second `userPromptSubmitted` and later a second `agentStop` for the subagent, then `subagentStop`, `postToolUse` for `task`, and finally the parent's own `agentStop`.
Subagent payloads carry `agentId`, `agentType`, and `parentAgentId`, and their `sessionId` is the subagent's own; the parent's payloads carry none of those three keys.
The subagent's `agentStop` arrived about 1.5 s before the parent's, so before the fix it closed the parent's busy record and raised the turn-end notification while the parent was still working (the record's sequence counter reached 5 for one parent turn, against 3 after the fix).
The plugin hooks now skip `userPromptSubmitted` and `agentStop` payloads that contain `"parentAgentId":"`, and a repeat run of the same task kept the record `busy copilot-hook` until the parent's `agentStop`, with the turn-end notification raised once at the end.
`subagentStart`, `subagentStop`, and `sessionEnd` are not wired; `sessionEnd` was seen only at exit.

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

On 2026-11-05 and 2026-11-06, with Copilot CLI 1.0.105 and tmux 3.7c on Linux (WSL2), the signed-in live guard and the whole portable suite were run from this branch.

- `FM_COPILOT_SIGNALS_LIVE=1 bash bin/fm-test-run.sh tests/fm-copilot-signals-live-e2e.test.sh` passed without a gate skip (comm `MainThread`, argv[0] `copilot`, real prompt to `busy copilot-hook`, turn end, clean `/exit`).
- `tests/fm-copilot-harness.test.sh` passed.
- The portable lanes (`portable-parallel-1`, `portable-parallel-2`, and `portable-serial-1of11` through `-11of11`, with `tmux` on `PATH`) ran 316 scripts. 19 failed on the busy host, and a rerun of each failing script alone reproduced 18; `tests/fm-claude-stop-autoarm.test.sh` passed on rerun.
- None of the failing scripts touches a Copilot file. The causes seen are missing host tools (`actionlint`, `ruby`, a `tasks-axi` build the captain-hold gate accepts), WSL process reparenting (listeners and pty hosts stay under the init subreaper), and a tmux smoke test whose shell never became ready. They were not compared against a clean upstream checkout.

The failing scripts are `fm-backend-t3code`, `fm-captain-hold-lifecycle`, `fm-lint`, `fm-pr-merge`, `fm-test-run`, `fm-backlog-atomicity`, `fm-control-relaunch`, `fm-procevent`, `fm-record-export`, `fm-watcher-lock`, `fm-jev-mem-guard`, `fm-spawn-orca-worktree`, `fm-lint-workflows`, `fm-backend-tmux-smoke`, `fm-public-followup`, `fm-nm-test-contract`, `fm-ci-workflow`, and `fm-session-lock-ancestry`, plus `fm-claude-stop-autoarm`, which passed on rerun.

## Folder trust options

On 2026-11-06 each route below was run in a real tmux 3.7c pane against a scratch git project that carried a project hook (`.github/hooks`), a project skill, and a project MCP server (`.mcp.json`), with a prompt of `reply with the word ok` and the plugin hook from this adapter.
Each cell is what the pane and the hook logs showed.

| Route | Starts unattended | Plugin hooks deliver | Project hooks and MCP load | Real `~/.copilot` untouched |
|---|---|---|---|---|
| `COPILOT_ALLOW_ALL=true` (previous launch) | yes | yes | yes | no (login state, sessions, logs) |
| `COPILOT_ALLOW_ALL=1` plus answering `1. Yes` | no (dialog until answered) | yes | yes | no |
| `COPILOT_ALLOW_ALL=1` plus declining (`Esc`) | no | the agent exits with a blank pane | not applicable | not applicable |
| per-task `COPILOT_HOME` with `trustedFolders` seeded (shipped) | yes | yes | yes | yes |
| per-task `COPILOT_HOME` plus `{"disableAllHooks":true}` in its `settings.json` | yes | yes | yes | yes |

- `COPILOT_ALLOW_ALL` accepts several truthy spellings, but only exactly `true` trusts the directory (`copilot help environment`); `1` with `--allow-all` showed the dialog `Do you trust the files in this folder?` with `1. Yes`, `2. Yes, and remember this folder for future sessions`, and `3. No (Esc)`.
- `1. Yes` is session-only and did not write the real `config.json`, but trusting the folder is what loads project hooks and MCP servers, so it gives no isolation over the previous launch.
- Declining closed the agent, so the dialog cannot be used to keep project configuration out.
- `--trust-folder` is documented for one new prompt-mode session only and was not tried with `-i`.
- The setting `disableAllHooks` read back as `true` from the task home, yet the project hook and the plugin hook both still fired in a `-p` run and an interactive run, so it does not suppress them in 1.0.105.
- A relocated `COPILOT_HOME` is a fresh directory (`config.json` only, then logs, sessions and `installed-plugins` as the run creates them), so the captain's user-level hooks, plugins, and skills (a real pane showed `4 plugins, 6 hooks, 64 skills`) stay out of the worker.
- Login worked in a relocated, empty home for `-p` and for the interactive pane: the credential is a `keyring:<host>:<account>@copilot-cli` entry in the OS keyring, not a file under `~/.copilot`.
- A host without an OS keyring may keep the token in `config.json` instead; that case was not exercised, and its worker would stop at a login prompt in the task home.
- The model default of a fresh home differs from the captain's (`GPT-6.1 Sol` against `GPT-6 Luna`), so a task that cares passes `--model`.
- A failing project MCP server holds the first prompt for about a minute (`Loading … still waiting`), which the previous launch also did.
- No route avoids loading the worktree's own hooks, skills, and MCP servers once the worktree is trusted; the per-task home narrows trust to that worktree and keeps the user home out, which is the only improvement found.

## Native slash skills

On 2026-11-06, in a real tmux pane with a per-task `COPILOT_HOME`, the slash popup listed a project skill from `.github/skills` as `/projskill` and a skill from a `--plugin-dir` plugin as `/<plugin>:<skill>`.
Submitting either rendered `skill(<name>)` and the skill's reply.
`bin/fm-send.sh <task> '/labskill'` against a spawned scout whose worktree carried `.agents/skills/labskill` took the typed plane, submitted without a stuck popup, and produced `skill(labskill)` and the expected reply.
Project skills are discovered from `.agents/skills`, `.github/skills`, and `.claude/skills` (`copilot skill --help`).
The captain's real `~/.copilot` listed 64 skills in one project, including installed-plugin skills and a personal skill reached through `skillDirectories`, while a relocated home listed only the project skill and two builtin skills.
Firstmate's own skills are read by path from the brief, so a worker does not depend on the inherited list.

## Hook decision facts

On 2026-11-06, with a plugin hook file and a relocated `COPILOT_HOME` in a real tmux pane, these hook results were observed.
They bear on a Copilot primary, which remains unsupported.

- `preToolUse` printing `{"permissionDecision":"deny","permissionDecisionReason":"..."}` stopped a shell command from running under `--allow-all`, and the pane showed `Denied by preToolUse hook: <reason>`.
- `preToolUse` exiting 2 also denied, with the generic reason `hook exited with code 2`; its stderr was not shown.
- `agentStop` printing `{"decision":"block","reason":"..."}` queued the reason as a follow-up message and ran another turn, whose own stop carried `stop_hook_active: true`; exiting 2 with stderr only printed a warning line.
- An always-blocking `agentStop` produced 8 continuations and then let the turn end.
- Copilot waited synchronously for an `agentStop` hook: a 75 s sleep with `timeoutSec: 200` held the stop and its block decision was honoured, and a `.claude/settings.json` Stop hook marked `asyncRewake` was awaited the same way.
- `sessionStart` printing `{"additionalContext":"..."}` put that text in front of the model before its first reply.
- Copilot also loads a trusted project's `.claude/settings.json` hooks and delivers Claude-shaped payloads (`tool_name` `Bash`, `tool_input.command`, `hook_event_name`) with `CLAUDE_PROJECT_DIR`, `COPILOT_CLI`, and `COPILOT_PROJECT_DIR` set for the hook.

## Claude-shaped payloads

On 2026-11-08, Copilot 1.0.105 in a `-p` run with a relocated `COPILOT_HOME` that trusted only a scratch project ran a recording hook from that project's `.claude/settings.json` for `SessionStart`, `PreToolUse`, `UserPromptSubmit`, and `Stop`.
Claude Code 2.x in a `claude -p` run with the same recording hooks gave the Claude side of the comparison.
Copilot payload keys, per event (all four carry `hook_event_name`, `session_id`, `timestamp`, and `cwd`):

```text
SessionStart      source, initial_prompt
PreToolUse        tool_name, tool_input
UserPromptSubmit  prompt
Stop              transcript_path, stop_reason, stop_hook_active
```

Claude payload keys on the same events:

```text
SessionStart      session_id, transcript_path, cwd, hook_event_name, source
PreToolUse        session_id, transcript_path, cwd, prompt_id, permission_mode, effort, hook_event_name, tool_name, tool_input, tool_use_id
UserPromptSubmit  session_id, transcript_path, cwd, prompt_id, permission_mode, hook_event_name, prompt
Stop              session_id, transcript_path, cwd, prompt_id, permission_mode, effort, hook_event_name, stop_hook_active, last_assistant_message, background_tasks, session_crons
```

- `timestamp` (ISO-8601 with a `Z` suffix, such as `2026-01-01T00:00:00.000Z`) is present on every Copilot payload and absent from every Claude payload above, so it separates the two for all four events.
- `stop_reason` is not a usable signal alone because it is present only on `Stop`.
- `bin/fm-hook-host-lib.sh` requires the `timestamp` string and the absence of `permission_mode`, `prompt_id`, and `tool_use_id`, none of which Copilot sends, so a Claude release that adds `timestamp` does not stand Claude down.
- A payload that is not an object, has no `timestamp`, or cannot be parsed runs the entry.
- `bash tests/fm-copilot-claude-standdown.test.sh` pins the sanitized shapes against each affected entrypoint.

## Teardown of a live worker

On 2026-11-06, in a scratch Firstmate home on a private tmux socket with a local-origin project, a Copilot scout was spawned with the per-task home, replied through a steer, and was torn down with `fm-teardown.sh` while its agent was still running.
Teardown first refused until the scout's captain-call inventory was recorded, which is the ordinary scout gate.
It then reaped the two worktree processes (the agent and its launcher), returned the worktree to the pool, and closed the window.
A listing of the lab home before and after showed that only these records changed: the task's `busy-gen`, `busy-state`, `copilot-home` (with its sessions, logs, and `config.json`), `copilot-plugin`, `git-hooks`, `meta`, and `turn-ended` were removed, and the home's `terminal-outcomes` record was added.
The task's `data/` directory, the project clone, and the other tmux window were untouched, no worker process survived, and no file under the captain's real `~/.copilot` was modified.
A second scout was exited, relaunched with `fm-control relaunch --note`, and found with its per-task home preserved (a marker file inside it survived), the worktree still listed under `trustedFolders`, and no trust dialog; it was then torn down the same way.

## Herdr relaunch and teardown

On 2026-11-07, in a named isolated Herdr lab session (guarded helper for every lifecycle action, default session untouched and still running afterwards) and a scratch Firstmate home with a local-origin project, a Copilot scout was spawned with `fm-spawn.sh --scout --harness copilot --backend herdr`.
- **Launch:** no trust dialog appeared, the worker answered, wrote its report, and appended `done`; the busy record went from `busy fm-spawn` to `busy copilot-hook` and closed at `agentStop` with the turn-end notification raised once.
- **Exit and relaunch:** `fm-control exit` returned `stopped` and the pane fell back to its shell with `Resume copilot --resume=<session-id>`.
  `fm-control relaunch --note` started a replacement agent in the same pane and worktree under a new busy generation, which picked up the note, answered, appended `done`, and closed its record at `agentStop`.
- **Per-task home:** a marker file placed in the task's Copilot home before the exit survived the relaunch, `trustedFolders` still listed exactly the worktree, and the pane showed no trust dialog.
- **Teardown:** `fm-teardown.sh` on the live agent returned the worktree, closed the pane, and left no `copilot` process.
  A before and after listing of the lab home to two levels showed only the task's own records removed (`busy-gen`, `busy-state`, `control-relaunch` with its `brief-prior`, `meta-prior` and `note` records, `copilot-home`, `copilot-plugin`, `git-hooks`, `meta`, `status`, `turn-ended`) and `terminal-outcomes` plus the watcher-stale banner marker added; the project clone, `data/`, and the rest of the home were unchanged, and no file under the captain's real `~/.copilot` changed.
- The lab helper's teardown stopped and deleted the lab session, and the default session was still running.

## Still not exercised

Secondmate use and a host that keeps the Copilot token in `config.json` rather than the OS keyring were not exercised.

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
The shipped launch uses a per-task `COPILOT_HOME` instead; see Folder trust options.
An earlier observation of "no dialog" came from a directory already in Copilot's trusted-folder list and is withdrawn.
`--model bogus-model` exited at launch with `Error: Model "bogus-model" from --model flag is not available.`
`--reasoning-effort xhigh` on `gpt-6-luna` and `--reasoning-effort max` on `claude-sonnet-5.5` were accepted.
No catalog listing command was found, so the spawn does not pre-validate the model.
