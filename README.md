# session-switcher

Open a new Claude Code session from inside a running one and hand it a brief. Only `claude`, `tmux`, and a shell.

```bash
bin/session-switcher examples/brief.md   # launches, waits, prints the child's first reply
tmux attach -t handoff                   # continue the child by hand
```

The mechanism is lifted from Orca's `worktree create --agent claude --prompt`: brief as one argv, identity in env, Claude `Stop` hook as the return channel.

Skill: `skills/session-switcher/SKILL.md`. Link skills with:

```bash
ln -s ~/session-switcher/skills/session-switcher ~/.claude/skills/session-switcher
ln -s ~/session-switcher/skills/session-airspace ~/.claude/skills/session-airspace
ln -s ~/session-switcher/skills/session-relay ~/.claude/skills/session-relay
```

and put `bin/` on your PATH.

## Tools

* **`bin/session-switcher`**: Launch fresh Claude sessions in tmux with a brief and receive first reply via `Stop` hook.
* **`bin/session-airspace`**: Monitor WSL RAM pressure and put background sessions into `SIGSTOP` holding patterns to prevent OOM kills.
* **`bin/session-relay`**: Inspect, steer, and read background sessions headless from Claude Desktop without `tmux attach`.
