#!/usr/bin/env python3
"""Shared discovery for session-relay and session-airspace.

A *managed* child is a tmux pane running `claude --settings <dir>/settings.json ...`, where
<dir> is the return-channel folder that session-switcher (and big-next-job's run-job) create:
the child's Stop hook writes <dir>/done.json. Every tmux session is scanned, so children of
`handoff`, `job-*` or any other session are all found.

Usage:
  session_panes.py list                 one TSV row per managed child (fields below)
  session_panes.py tree <pid>           <pid> and its descendants, parents first
  session_panes.py ram                  "used_mb total_mb avail_mb pct"
  session_panes.py last <done.json>     the last assistant message in a Stop event

list fields: target name pane_pid claude_pid wrapped state rss_mb age_s activity dir last
  target    tmux target "session:window_index"
  wrapped   1 if claude is a child of the pane's shell (holdable), 0 if it is the pane process
  state     held | working | idle | starting
  rss_mb    resident memory of claude and every process under it
  activity  seconds since the transcript or done.json last changed
"""
import json
import os
import subprocess
import sys
import time



def proc_children():
    kids = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat") as f:
                stat = f.read()
        except OSError:
            continue
        ppid = int(stat[stat.rindex(")") + 2:].split()[1])
        kids.setdefault(ppid, []).append(int(entry))
    return kids


def tree(pid, kids=None):
    kids = kids if kids is not None else proc_children()
    out, todo = [], [pid]
    while todo:
        p = todo.pop(0)
        out.append(p)
        todo.extend(sorted(kids.get(p, [])))
    return out


def read(path, default=""):
    try:
        with open(path, "rb") as f:
            return f.read().decode(errors="replace")
    except OSError:
        return default


def proc_state(pid):
    for line in read(f"/proc/{pid}/status").splitlines():
        if line.startswith("State:"):
            return line.split()[1]
    return "?"


def rss_kb(pid):
    for line in read(f"/proc/{pid}/status").splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return 0


def start_time(pid):
    """Process start as a Unix timestamp (field 22 of /proc/<pid>/stat, in clock ticks since boot)."""
    stat = read(f"/proc/{pid}/stat")
    if not stat:
        return None
    ticks = int(stat[stat.rindex(")") + 2:].split()[19])
    btime = next((int(line.split()[1]) for line in read("/proc/stat").splitlines()
                  if line.startswith("btime ")), None)
    return btime + ticks / os.sysconf("SC_CLK_TCK") if btime else None


def argv(pid):
    return [a for a in read(f"/proc/{pid}/cmdline").split("\0") if a]


def is_claude(args):
    """argv[0] is claude (native binary), or argv[1] is (an interpreter running it, e.g. node).
    A wrapper shell (`bash -c "claude ...; :"`) carries claude only inside one string, so it never matches."""
    names = [os.path.basename(a) for a in args[:2]]
    return bool(names) and (names[0] == "claude" or (len(names) > 1 and names[1] == "claude"))


def settings_dir(args):
    for i, a in enumerate(args[:-1]):
        if a == "--settings" and args[i + 1].endswith("/settings.json"):
            return os.path.dirname(args[i + 1])
    return None


def find_claude(pane_pid, kids):
    """Return (claude_pid, wrapped, settings_dir) for a pane, or None if it is not a managed child."""
    for pid in tree(pane_pid, kids):
        args = argv(pid)
        if not is_claude(args):
            continue
        sdir = settings_dir(args)
        if not sdir:
            return None
        return pid, int(pid != pane_pid), sdir
    return None


def last_message(done_path):
    try:
        with open(done_path) as f:
            ev = json.load(f)
    except (OSError, ValueError):
        return None, None
    return ev.get("last_assistant_message"), ev.get("transcript_path")


def mtime(path):
    try:
        return os.stat(path).st_mtime
    except (OSError, TypeError):
        return None


def one_line(text, width=70):
    text = " ".join((text or "").split())
    return text if len(text) <= width else text[: width - 1] + "…"


def cmd_list():
    fmt = "#{session_name}\t#{window_index}\t#{window_name}\t#{pane_pid}"
    try:
        out = subprocess.run(["tmux", "list-panes", "-a", "-F", fmt],
                             capture_output=True, text=True, check=False).stdout
    except FileNotFoundError:
        return
    kids = proc_children()
    now = time.time()
    for row in out.splitlines():
        sess, idx, name, pane_pid = row.split("\t")
        found = find_claude(int(pane_pid), kids)
        if not found:
            continue
        cpid, wrapped, sdir = found
        done = os.path.join(sdir, "done.json")
        msg, transcript = last_message(done)
        done_t, trans_t = mtime(done), mtime(transcript)
        if proc_state(cpid) == "T":
            state = "held"
        elif done_t is None:
            state = "starting" if trans_t is None else "working"
        elif trans_t is not None and trans_t > done_t + 1:
            state = "working"
        else:
            state = "idle"
        rss = sum(rss_kb(p) for p in tree(cpid, kids)) // 1024
        started = start_time(cpid) or now
        last_change = max(t for t in (done_t, trans_t, started) if t is not None)
        print("\t".join(str(v) for v in (
            f"{sess}:{idx}", name, pane_pid, cpid, wrapped, state, rss,
            int(now - started), int(now - last_change), sdir, one_line(msg) or "-")))


def cmd_ram():
    m = {}
    for line in read("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        m[k] = int(v.split()[0])
    total, avail = m["MemTotal"], m["MemAvailable"]
    used = total - avail
    print(used // 1024, total // 1024, avail // 1024, f"{used * 100 / total:.1f}")


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 1
    cmd = argv[1]
    if cmd == "list":
        cmd_list()
    elif cmd == "tree" and len(argv) == 3:
        print(" ".join(str(p) for p in tree(int(argv[2]))))
    elif cmd == "ram":
        cmd_ram()
    elif cmd == "last" and len(argv) == 3:
        msg, _ = last_message(argv[2])
        if msg is None:
            return 1
        print(msg)
    else:
        print(__doc__, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
