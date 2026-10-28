# Session Board

Handoff for the next session. Written 2026-10-27 from an idea-refine pass on session-switcher.

## Problem Statement

How might one person see and steer several live Claude Code sessions from inside any one of them, using only `claude`, tmux and a shell, in both a terminal and Claude Desktop (Windows app, WSL backend), so handing work off becomes a reflex?

## Who / Success / Constraints

- User: one person, this WSL box. No packaging for others.
- Pains: juggling many live sessions; deciding which session a task should go to.
- Success in 2 weeks: used daily without thinking.
- Constraints: `claude` + tmux + shell only. No daemon, no MCP server, no UI.
- New constraint: must work when the parent session runs under Claude Desktop. Verified facts about that host, captured from a live Desktop session:
  - `CLAUDE_CODE_DESKTOP_APP_VERSION` is set; the parent process is `~/.claude/remote/srv/<hash>/server --serve --socket ...`; `tty` says `not a tty`.
  - So `tmux attach -t handoff` is not something the user can type from Desktop. The "continue the child by hand" path in SKILL.md does not exist there.
  - `CLAUDE_CODE_MESSAGING_SOCKET` / `CLAUDE_CODE_MESSAGING_TOKEN` exist in env (values are secrets, never print them). Unknown whether a child can use them.

## What changed since the tool was built

`claude --help` now shows native background sessions. Read before building anything:

```
--bg, --background   Start the session in the background and return immediately.
                     Prints the id that `claude attach`, `logs`, `stop` and `rm` take;
                     `claude agents` lists them. With --resume <session-id>, continues
                     that session in the background under the same ID.
--session-id <uuid>  Use a specific session ID for the conversation.
--settings <file>    (already used by bin/session-switcher for the Stop hook)
```

`claude agents` is a session registry. `claude attach` replaces `tmux attach`. If these work from Desktop, most of the tmux layer in `bin/session-switcher` is dead weight.

## Recommended Direction

Order: spike 0, then build 1 and 2 together as the MVP, then 3. Fan-out (one brief, N worktrees) waits until the board shows memory per session; WSL OOM'd last week under the `.max` wslconfig preset.

### 0. Spike: `--bg` instead of tmux (20 to 40 min, do first)

Questions, each answered yes/no with evidence:

1. Does `claude --bg --settings <dir>/settings.json '<brief>'` fire the Stop hook and write `done.json` the way the tmux launch does? Test with `examples/brief.md` (expects `PONG`).
2. Does the child inherit `CLAUDECODE` and think it is nested? The tmux path scrubs `CLAUDE*` from the server env; with `--bg` there is no server to scrub. Try `env -u CLAUDECODE ... claude --bg`.
3. From a Desktop-hosted parent: does `claude agents` list the child, and does `claude attach <id>` do anything useful when stdin is not a tty? If attach is unusable there, the return channel must carry the whole conversation, not just the first reply.
4. Does the trust dialog still block a `--bg` child in a fresh folder? Headless, there is no pane to scrape.

If 1 and 2 pass: rewrite `bin/session-switcher` on `--bg`, drop the tmux server, keep `done.json`. If 3 fails: keep tmux as the engine but never tell the user to `tmux attach`; route everything through files.

### 1. `session-switcher ls` (the board)

One command, plain text, one line per live session:

```
ID        WHERE                        STATE    AGE   LAST
a1b2c3d4  ~/BotHaus  (window 2)        idle     3m    "PR #12 opened, tests green"
e5f6g7h8  ~/TradingBots (bg)           working  40s   -
```

Sources, all already on disk or one command away: `claude agents` (if the spike passes), `tmux list-windows -t handoff -F ...`, each child's `$SWITCH_DIR/done.json` (`last_assistant_message`), transcript mtime under `~/.claude/projects/<slug>/`. STATE = `done.json` newer than transcript → idle, else working. Add `MEM` (RSS from `ps`) before fan-out exists.

### 2. Child pings home (inversion of today's poll)

Today the parent blocks up to `SWITCH_TIMEOUT`. Instead the child's Stop hook appends one JSON line to `~/.switch/inbox.jsonl` (`id`, `cwd`, `last_assistant_message`, `ts`) and the launch returns immediately. The parent reads the inbox with `session-switcher ls` or a `UserPromptSubmit` hook that injects "child X finished: ..." into its next turn. No daemon; the inbox is a file. This is what makes the board live and works identically under Desktop.

### 3. Route instead of spawn

`session-switcher send <id|lane> brief.md` delivers a brief to an existing child (`claude --resume <id> --bg '<brief>'` if the spike passes; `tmux send-keys` otherwise). Named lanes (`review`, `build`, `research`) map to a persistent child each, kept in `~/.switch/lanes`. `session-switcher new` stays as today. This is the routing painkiller.

## Key Assumptions to Validate

- [ ] `--bg` children fire `--settings` Stop hooks. Test: spike 0.1.
- [ ] A Desktop-hosted parent can run `claude agents` / `claude attach`. Test: spike 0.3 from a Desktop session (this one qualified; check `CLAUDE_CODE_DESKTOP_APP_VERSION`).
- [ ] An inbox file read by a `UserPromptSubmit` hook is enough to feel "live". Test: build 2, use it for one day, note every time you ran `ls` anyway.
- [ ] Transcript mtime is a good enough "working/idle" signal. Test: compare against `done.json` timing on 5 real children.

## MVP Scope

In: spike 0; `ls`; inbox Stop hook; `new` rewritten on whatever engine the spike picks. Keep `done.json` so `examples/brief.md` still passes.
Out: `send`, lanes, fan-out, memory column (add when fan-out is on the table).

## Not Doing (and Why)

- Web dashboard / MCP server / Slack bridge: breaks the claude+tmux+shell constraint, and the board is one `ls` away.
- Fan-out to N worktrees now: the last WSL crash was memory; no visibility yet.
- Brief generator from the precompact handoff note: real, but a separate skill; it does not touch the engine question.
- Cross-platform (native Windows tmux-less): the WSL backend is the only host; Desktop runs the CLI inside WSL.

## Open Questions

- Does `--resume <id> --bg '<prompt>'` accept a prompt, or only continue? Unknown from `--help`.
- Is `CLAUDE_CODE_MESSAGING_SOCKET` a supported way for a child to message the parent? If yes, it beats the inbox file. Do not print the token while checking.
- Where does `claude agents` persist its registry? If it is a file, `ls` can read it directly.

## Pointers

- Script: `bin/session-switcher` (tmux engine, Stop hook via `--settings`, trust-dialog scrape, `-` guard).
- Skill: `skills/session-switcher/SKILL.md`; linked into `~/.claude/skills/session-switcher`.
- Probe brief: `examples/brief.md` (reply `PONG`).
- Orca's original mechanism and the live capture: `~/ReverseEngineerAnything/reports/orca-cli-session-handoff.md`.
- Hard Rule: every tracked change via worktree + feature branch + PR, merge from the primary checkout, tear down after.
