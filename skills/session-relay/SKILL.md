---
name: session-relay
description: See and steer Claude child sessions started by session-switcher or big-next-job's run-job, without tmux attach. Use to check on a handed-off session, send it a follow-up prompt and get the reply, read its screen, or close it — including from Claude Desktop, where tmux attach does not work.
---

# Session Relay

Talks to the Claude children that `session-switcher` (tmux session `handoff`) and `run-job` (sessions `job-*`) start. It finds them in every tmux session, so one `list` shows them all. Everything works without a TTY.

## Commands

```bash
session-relay list                                  # every child: target, state, memory, last reply
session-relay send sw-ab12cd --wait "Now run the tests and summarise failures"
session-relay send sw-ab12cd --wait=900 -f followup.md     # prompt from a file; - reads stdin
session-relay last sw-ab12cd                        # the latest full reply
session-relay read sw-ab12cd 60                     # last 60 lines of its screen
session-relay kill sw-ab12cd                        # close it (resumes it first if held)
```

A target is the window name `session-switcher` printed (`sw-ab12cd`), or `session:index` from `list` (for example `job-api:2`).

## Steps for a follow-up

1. `session-relay list`. Pick the child; check its STATE. `idle` is ready; `working` will queue your prompt; `held` must be released first (`session-airspace release <target>`).
2. `session-relay send <target> --wait "<prompt>"`. Write the prompt so it stands alone. Multi-line prompts are fine. Give the Bash tool a timeout longer than `--wait` (default 600 s).
3. Relay the printed reply to the user. On exit 2 (timeout), the child is still working: check later with `session-relay last <target>`.
4. Exit 5 means the child is showing a dialog (a permission prompt, the trust dialog, a question). Nothing was sent: pressing Enter there would pick the highlighted option, and on a permission prompt that approves the command. Show the user the dialog (`session-relay read <target>`) and let them answer it in a terminal; do not answer it for them.

## States

- `starting`: launched, no turn yet. `working`: a turn is in progress. `idle`: last turn finished. `held`: paused by `session-airspace`.

## Limits

- `--wait` returns at the end of the child's next turn. A child can end a turn while a command it started keeps running in the background; its later reply shows up in `last`.
- `send` writes into the child's input as if typed, so slash commands (`/compact`) work too. Only send what you would type yourself.
