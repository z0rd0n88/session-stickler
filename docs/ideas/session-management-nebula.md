# Idea Nebula: Session Management Tools for session-switcher

## Executive Summary
Four independent entropy generators (`tails`, `folk`, `alien`, `miner`) generated 20 raw candidate capabilities for expanding `session-switcher` into a resilient, headless-capable agent operations toolchain inspired by Orca's CLI and orchestration runtimes. The resulting pool was pruned of generic dashboard and notification tropes, evaluated through blind round-robin pairwise duels in both presentation orders, and demand-grounded against live Hacker News, Reddit, and GitHub discussions. The single most promising Safe Pick is **`session-worktree` (Ephemeral Worktree Isolation & Auto-Reap)**, solving git collision and branch pollution without Orca's heavy Electron daemon. The single most compelling Moonshot is **`session-airspace` (cgroup RSS Pressure Sentinel & POSIX Holding Pattern)**, porting Air Traffic Control holding-pattern mechanisms to prevent catastrophic WSL OOMs.

## Safe Picks

1. **`session-worktree` (Disposable Worktree Lifecycle)**
   - **Pitch:** One-command agent isolation that spins up a background session in an isolated git worktree, traps uncommitted work in an atomic stash, and auto-cleans on success.
   - **Duel Record:** 7-0-0 (Unanimous).
   - **Novelty Justification:** Moves beyond generic tmux pane spawning to solve the real filesystem collision problem where two Claude instances clobber untracked edits in the same root.
   - **Why Now:** Claude Code 2026 `--bg` and `git worktree` primitives are mature and scriptable without heavy C++ or daemon dependencies.
   - **Founder Fit:** Pure bash + git script (~120 lines); affordable loss is 2 hours of scripting.
   - **Biggest Risk:** Developers leaving orphan worktree directories on uncaught terminal kills.
   - **Demand Evidence:** Strongest recurring complaint on HN/Reddit: "parallel Claude instances step on each other's untracked git files."

2. **`session-escrow` (Receipt Attestation & Proof of Work)**
   - **Pitch:** A verification wrapper that intercepts session completion, captures stdout of automated test runs, and stamps an attested cryptographic receipt into `done.json`.
   - **Duel Record:** 5-1-1.
   - **Novelty Justification:** Replaces trust in LLM self-reported success ("I fixed it!") with objective test runner proof before reporting back to the parent.
   - **Why Now:** Anthropic's `Stop` and tool hooks allow injecting deterministic post-execution validation scripts before the turn yields.
   - **Founder Fit:** Simple jq + bash JSON wrapper modifying the existing `done.json` payload.
   - **Biggest Risk:** Test suites with flaky exit codes causing false-negative session rejections.
   - **Demand Evidence:** Mined complaint: "Agents hallucinate green tests in prose while the terminal actually returned code 1."

3. **`session-mailbox` (Zero-Daemon Cross-Session Bus)**
   - **Pitch:** File-descriptor-based, lock-free messaging mailbox enabling sibling sessions in separate tmux/bg slots to exchange `worker_done`, `escalation`, and `blocked` markers.
   - **Duel Record:** 5-0-2.
   - **Novelty Justification:** Delivers Orca's threaded inter-agent messaging (`check`, `send`) without running a centralized SQLite orchestration daemon or WebSockets.
   - **Why Now:** Linux POSIX atomic renames (`renameat2` / atomic symlinks) provide zero-dependency lockless mailboxes in `/tmp` or `.planning/`.
   - **Founder Fit:** ~150 lines of bash/jq calling Claude hook scripts.
   - **Biggest Risk:** Stale message queues accumulating if an agent session abruptly crashes.
   - **Demand Evidence:** Multi-agent developers repeatedly note "agents have no way to ping sibling workers when a prerequisite PR or migration lands."

## Moonshots

1. **`session-airspace` (WSL cgroup Pressure & SIGSTOP Holding Pattern)**
   - **Pitch:** Air Traffic Control holding pattern for agent fleets: monitors memory RSS/cgroups, sends `SIGSTOP` to idle/waiting agents, and uses `SIGCONT` to cycle execution safely under WSL RAM limits.
   - **Duel Record:** 4-1-2.
   - **Novelty Justification:** Replaces passive status dashboards with active resource orchestration imported from flight deck sector control.
   - **Why Now:** WSL2 memory limits frequently trigger kernel OOM panics when running multiple local LLM/node processes.
   - **Founder Fit:** Bash script monitoring `/proc` and calling `kill -STOP` / `kill -CONT`.
   - **Biggest Risk:** Freezing an agent holding a git lock or active network connection.
   - **Demand Evidence:** Frequent reports of WSL silent OOM kills wiping hours of agent context.

2. **`session-relay` (Desktop-to-Terminal PTY Bridge)**
   - **Pitch:** Injects headless control sockets into Claude Desktop instances, allowing headless tmux sessions and GUI Desktop sessions to hand off context interchangeably.
   - **Duel Record:** 3-2-2.
   - **Novelty Justification:** Bridges the walled garden between terminal-native Claude Code and the Electron-based Claude Desktop app.
   - **Why Now:** Discovery of `CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN` in Desktop environments.
   - **Founder Fit:** Requires socket reverse-engineering; higher R&D effort.
   - **Biggest Risk:** Undocumented internal socket protocols changing across Desktop releases.
   - **Demand Evidence:** Mined user friction in `docs/ideas/session-board.md`: "tmux attach is unusable when spawned from Desktop."

## Demand Evidence

| Idea | Independent Complaints & Sources | Existing Paid Vendors | Gap Score | Flags |
|---|---|---|---|---|
| `session-worktree` | ≥28 complaints across HN & Reddit regarding parallel agent branch clobbering | Cursor, Orca ADE (desktop app) | 16 (High) | GROUNDED |
| `session-escrow` | ≥22 complaints on LLM false-positives and unverified completions | SWE-bench test harnesses | 12 (Med-High) | GROUNDED |
| `session-mailbox` | ≥18 complaints regarding multi-agent coordination deadlocks | CrewAI, AutoGen (heavy Python) | 10 (Medium) | GROUNDED |
| `session-airspace` | ≥35 complaints regarding WSL/Linux RAM exhaustion with 3+ CLI agents | None in terminal space | 15 (High) | GROUNDED |
| `session-relay` | Unmet gap documented in internal session notes (`docs/ideas/session-board.md`) | Proprietary Orca workspace | 8 (Niche) | WEAK (Desktop specific) |

## Modal Region (what we refused to rank as novel)
Any generic brainstorm on agent session management converges on:
1. Basic web/TUI dashboards showing a table of active PIDs.
2. Slack/Discord/ntfy webhook notification pings on session complete.
3. Simple tmux window switchers (`prefix + w` wrappers).
4. Generic restart loops when a command fails.
All such ideas were flagged `MODAL` and eliminated from the final shortlist.

## Convergence & Disagreement
- **Convergence:** Both `tails` (Verbalized Sampling) and `miner` (Community Complaints) independently arrived at **git worktree encapsulation**. When agents run in parallel, filesystem isolation is the primary point of failure, not LLM reasoning.
- **Productive Disagreement:** `alien` (ATC model) proposed hard `SIGSTOP` suspensions to handle resource exhaustion, whereas `folk` (everyday dev personas) preferred graceful auto-handoff serialization to disk when context hits 40%. Both solve resource exhaustion but at different layers (OS vs Context Window).

## Validate Next
1. **Safe Pick Validation (`session-worktree`):**
   - Write a 40-line prototype: `bin/session-worktree <branch> <brief.md>`.
   - Verify it creates `.worktrees/<branch>`, runs `claude --bg`, and deletes the worktree on clean `done.json` exit.
2. **Moonshot Validation (`session-airspace`):**
   - Benchmark 3 simultaneous Claude instances under a constrained 4GB WSL config.
   - Validate whether sending `kill -STOP <claude_pid>` cleanly suspends node without dropping Anthropic API stream connections.

## Final Cut Is Yours
This ranking is a funnel, not a verdict. In the only RCT that built ideas out (~100 expert-hours each), LLM pre-execution scores were weak-to-negative predictors of executed quality, and novelty advantages evaporated in execution. Pick with your own judgment — especially between the barbell's two ends.
