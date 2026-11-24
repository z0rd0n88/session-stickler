---
name: session-relay
description: See and steer Claude child sessions started by session-switcher, big-next-job's run-job or blast-off, without tmux attach. Use to check on a handed-off session, send it a follow-up prompt and get the reply, read its screen, or close it — including from Claude Desktop, where tmux attach does not work.
---

# Session Relay

Talks to the Claude children that `session-switcher` (tmux session `handoff`), `run-job` (its own server `-L run-job-<name>`, session `job-<name>`) and blast-off (a private tmux server per job, `-L blast-off-<job>`) start. It finds them in every session on every tmux server you own, so one `list` shows them all, with a RUNNER column. Everything works without a TTY.

## Commands

```bash
session-relay list                                  # every child: target, runner, state, memory, last reply
session-relay send sw-ab12cd --wait "Now run the tests and summarise failures"
session-relay send sw-ab12cd --wait=900 -f followup.md     # prompt from a file; - reads stdin
session-relay last sw-ab12cd                        # the latest full reply
session-relay read sw-ab12cd 60                     # last 60 lines of its screen
session-relay kill sw-ab12cd                        # close it (resumes it first if held)
```

A target is the TARGET column of `list`: `session:index` on the default tmux server (for example `job-api:2`), `socket/session:index` on another (a blast-off child: `blast-off-api/job-api:3`). The window name `session-switcher` printed (`sw-ab12cd`) also works.

## blast-off children

blast-off's runner drives its children from the job's brief and closes each window when its turn ends, so they are normally listed only while working.

- `list`, `read`, `last`: as for any child.
- `send` refuses (exit 4) without `--force`: a typed prompt can derail the job. Send only when the user asks you to steer that child.
- `kill` refuses (exit 4): the runner would treat the closed window as a dead child and start another. Stop the job with the `blast-off stop <job-dir>` command it prints.

## run-job children

Every command works as usual. `kill` warns: run-job treats a killed child as a crash and starts the next one, so close one only when that is what you want.

## Steps for a follow-up

1. `session-relay list`. Pick the child; check its STATE. `idle` is ready. With `--wait`, a `working` or `starting` child is waited out first and the prompt is sent when its turn ends, so the reply is to your prompt (exit 2 with "NOT sent" if the turn outlasts `--wait`); without `--wait` the prompt is queued. `held` must be released first (`session-airspace release <target>`).
2. `session-relay send <target> --wait "<prompt>"`. Write the prompt so it stands alone. Multi-line prompts are fine. Give the Bash tool a timeout longer than `--wait` (default 600 s).
3. Relay the printed reply to the user. On exit 2 (timeout), the child is still working (any reply so far is printed): check later with `session-relay last <target>`.
4. Exit 5 means the child is showing a dialog (a permission prompt, the trust dialog, a question, or a panel such as `/model` or `/config`). Nothing was sent: pressing Enter there would pick the highlighted option, and on a permission prompt that approves the command. Show the user the dialog (`session-relay read <target>`) and let them answer it in a terminal; do not answer it for them.

## States

- `starting`: launched, no turn yet. `working`: a turn is in progress. `idle`: last turn finished. `background`: the last turn ended, but a shell it started in the background still runs; Claude Code starts a new turn by itself when that shell finishes. `failed`: an API error ended the last turn (blast-off's `StopFailure` hook wrote `failed.json`; `last` prints the error). `held`: paused by `session-airspace`.

## Limits

- `--wait` returns at the end of the child's next turn. If that turn leaves a shell running in the background ("waiting for the tests to finish"), it prints a note with the reply so far and waits for the turn Claude starts when the shell finishes, then prints that reply. This also covers a shell that ends just before the turn does: once a background shell was seen, the reply is taken only after `RELAY_BG_SETTLE` quiet seconds (10). Shells left running by earlier prompts (a dev server) don't count. A new shell that never finishes is capped by the `--wait` deadline: exit 2, with the reply so far. Exit 3 if the child is held while waiting, 5 if it opens a dialog.
- `send` writes into the child's input as if typed, so slash commands (`/compact`) work too. Only send what you would type yourself.
