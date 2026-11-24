#!/usr/bin/env python3
"""Shared discovery for session-relay and session-airspace.

A *managed* child is a tmux pane running `claude --settings <dir>/settings.json ...`, where
<dir> is the return-channel folder that session-switcher, big-next-job's run-job and blast-off
create: the child's Stop hook writes <dir>/done.json (blast-off's StopFailure hook writes
failed.json). Every session on every tmux server the user owns is scanned: each socket in
${TMUX_TMPDIR:-/tmp}/tmux-<uid>/, so blast-off's private `-L blast-off-<name>` servers are
found next to the default one.

Usage:
  session_panes.py list                 one TSV row per managed child (fields below)
  session_panes.py tree <pid>           <pid> and its descendants, parents first
  session_panes.py ram                  "used_mb total_mb avail_mb pct"
  session_panes.py bg <pid> [socket pane_id]
                                        how many background shells run under <pid> (a claude pid
                                        or its pane's pid); with a pane, also reads its footer
  session_panes.py last <dir>           the child's last reply (done.json), or its failure
                                        (failed.json) when that is newer

list fields: target name pane_pid claude_pid wrapped state rss_mb age_s activity dir socket
             pane_id runner job last
  target    "session:window_index" on the default server, "socket/session:window_index" elsewhere
  wrapped   1 if claude is a child of the pane's shell (holdable), 0 if it is the pane process
  state     held | working | background | idle | failed | starting
            background: the turn ended, but a shell it started in the background still runs;
            Claude Code starts a new turn by itself when that shell finishes
  rss_mb    resident memory of claude and every process under it
  activity  seconds since the transcript, done.json or failed.json last changed
  socket    tmux socket name, for `tmux -L <socket>`
  pane_id   tmux pane id (%N), the exact tmux target on that server
  runner    switcher | run-job | blast-off | other
  job       blast-off's job dir ($JOB_DIR of the child), else "-"
"""
import json
import os
import re
import stat
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


def event(path):
    try:
        with open(path) as f:
            ev = json.load(f)
    except (OSError, ValueError):
        return {}
    return ev if isinstance(ev, dict) else {}


def last_message(done_path):
    ev = event(done_path)
    return ev.get("last_assistant_message"), ev.get("transcript_path")


def failure_text(failed_path):
    """One line for a StopFailure payload: the error name, then any message it carries."""
    ev = event(failed_path)
    if not ev:
        return None
    detail = ev.get("error_details") or ev.get("last_assistant_message") or ""
    if not isinstance(detail, str):
        detail = json.dumps(detail)
    return f"turn failed: {ev.get('error') or 'unknown'}" + (f" ({detail})" if detail else "")


def last_reply(sdir):
    """The newest turn end in <sdir>: (text, failed?). A later done.json beats an older failed.json."""
    done, failed = os.path.join(sdir, "done.json"), os.path.join(sdir, "failed.json")
    done_t, failed_t = mtime(done), mtime(failed)
    if failed_t is not None and (done_t is None or failed_t > done_t):
        return failure_text(failed), True
    return last_message(done)[0], False


def mtime(path):
    try:
        return os.stat(path).st_mtime
    except (OSError, TypeError):
        return None


def one_line(text, width=70):
    text = " ".join((text or "").split())
    return text if len(text) <= width else text[: width - 1] + "…"


def sockets():
    """Names of every socket in this user's tmux socket dir, "default" first."""
    base = os.path.join(os.environ.get("TMUX_TMPDIR") or "/tmp", f"tmux-{os.getuid()}")
    try:
        names = sorted(os.listdir(base), key=lambda n: (n != "default", n))
    except OSError:
        return []
    out = []
    for n in names:
        try:
            if stat.S_ISSOCK(os.stat(os.path.join(base, n)).st_mode):
                out.append(n)
        except OSError:
            pass
    return out


def env_var(pid, name):
    for kv in read(f"/proc/{pid}/environ").split("\0"):
        if kv.startswith(name + "="):
            return kv[len(name) + 1:]
    return None


def runner_of(socket, sess, sdir):
    base = os.path.basename(sdir)
    if socket.startswith("blast-off-") or (base.startswith("blast-off-") and "-child." in base):
        return "blast-off"
    if base.startswith("switch."):
        return "switcher"
    if socket.startswith("run-job-") or sess.startswith("job-"):
        return "run-job"
    return "other"


def cmd_list():
    # A window name may hold tabs and newlines (tmux escapes every other control character, and
    # session names in full), so it goes last and each row starts with a token no name can hold.
    # -u keeps the tabs: under a non-UTF-8 locale tmux prints every tab as "_".
    tok = os.urandom(8).hex()
    fmt = tok + "\t#{session_name}\t#{window_index}\t#{pane_pid}\t#{pane_id}\t#{window_name}"
    kids = proc_children()
    now = time.time()
    for sock in sockets():
        try:
            out = subprocess.run(["tmux", "-u", "-L", sock, "list-panes", "-a", "-F", fmt],
                                 capture_output=True, text=True, check=False, timeout=5).stdout
        except FileNotFoundError:
            return
        except subprocess.TimeoutExpired:
            continue
        # A stale socket (no server behind it) just yields no rows: its error went to the pipe.
        for row in out.split(tok + "\t")[1:]:
            parts = row.rstrip("\n").split("\t", 4)
            if len(parts) != 5 or not parts[2].isdigit():
                continue
            sess, idx, pane_pid, pane_id, name = parts
            name = name.replace("\t", " ").replace("\n", " ")   # one row per child, every field in place
            found = find_claude(int(pane_pid), kids)
            if not found:
                continue
            cpid, wrapped, sdir = found
            done, failed = os.path.join(sdir, "done.json"), os.path.join(sdir, "failed.json")
            transcript = last_message(done)[1] or event(failed).get("transcript_path")
            done_t, failed_t, trans_t = mtime(done), mtime(failed), mtime(transcript)
            ended = max((t for t in (done_t, failed_t) if t is not None), default=None)
            msg, is_failed = last_reply(sdir)
            if proc_state(cpid) == "T":
                state = "held"
            elif ended is None:
                state = "starting" if trans_t is None else "working"
            elif footer_busy(sock, pane_id):
                # Claude Code's "esc to interrupt" footer shows exactly while a turn runs, including
                # one that starts within a second of the last one ending, or after a failed one.
                state = "working"
            elif trans_t is not None and trans_t > ended + 1 and now - trans_t < TURN_START_GRACE:
                # A transcript written after the last Stop event is a turn starting before its
                # footer is drawn. An older write without the footer is not a turn: a slash command
                # (/model, /config) writes to the transcript and never fires Stop. (The 1 s slack:
                # the transcript gets a last write just after the Stop hook.)
                state = "working"
            elif bg_shells(cpid, kids, sock, pane_id):
                state = "background"
            else:
                state = "failed" if is_failed else "idle"
            rss = sum(rss_kb(p) for p in tree(cpid, kids)) // 1024
            started = start_time(cpid) or now
            last_change = max(t for t in (done_t, failed_t, trans_t, started) if t is not None)
            runner = runner_of(sock, sess, sdir)
            job = (env_var(cpid, "JOB_DIR") if runner == "blast-off" else None) or "-"
            target = f"{sess}:{idx}" if sock == "default" else f"{sock}/{sess}:{idx}"
            print("\t".join(str(v) for v in (
                target, name, pane_pid, cpid, wrapped, state, rss,
                int(now - started), int(now - last_change), sdir, sock, pane_id, runner, job,
                one_line(msg) or "-")))


TURN_START_GRACE = 5   # seconds a fresh transcript write counts as "working" without the footer


# The Bash tool runs each command as `bash -c 'source <home>/.claude/shell-snapshots/snapshot-...'`
# under claude. Once a turn has ended, any such shell still alive was started in the background
# (run_in_background, or a long command Claude Code moved there), and Claude Code starts a new turn
# when it finishes. A shell's own subshells carry the same argv, so only the outermost counts.
SNAPSHOT = "/shell-snapshots/snapshot-"
# The footer says the same: "· 1 shell ·", "· 2 shells · ↓ to manage", "· 1 shell still running".
SHELLS_RE = re.compile(r"(?:^|·)\s*\d+ shells?(?: still running)?\s*(?:·|$)", re.M)


def bg_shells(pid, kids=None, socket=None, pane_id=None):
    """Count the background shells under <pid>; with a pane, a footer that shows one counts too."""
    kids = kids if kids is not None else proc_children()
    found, todo = 0, [(c, False) for c in kids.get(pid, [])]
    while todo:
        p, parent_is_shell = todo.pop()
        is_shell = SNAPSHOT in " ".join(argv(p))
        found += is_shell and not parent_is_shell
        todo.extend((c, is_shell) for c in kids.get(p, []))
    if not found and pane_id and SHELLS_RE.search(screen_tail(socket, pane_id)):
        found = 1
    return found


def screen_tail(socket, pane_id, lines=30):
    """The last <lines> lines of a pane's screen, from its own server (-L socket)."""
    try:
        screen = subprocess.run(["tmux", "-L", socket, "capture-pane", "-p", "-t", pane_id],
                                capture_output=True, text=True, timeout=5, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    return "\n".join(screen.splitlines()[-lines:])


def footer_busy(socket, pane_id):
    """True while Claude Code's footer reads "esc to interrupt", which it shows exactly while a turn
    runs."""
    return "esc to interrupt" in screen_tail(socket, pane_id)


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
    elif cmd == "bg" and len(argv) in (3, 5):
        print(bg_shells(int(argv[2]), None, *argv[3:5]))
    elif cmd == "ram":
        cmd_ram()
    elif cmd == "last" and len(argv) == 3:
        # argv[2] is a child dir (or, as before, its done.json)
        sdir = argv[2][:-len("/done.json")] if argv[2].endswith("/done.json") else argv[2]
        msg, _ = last_reply(sdir)
        if msg is None:
            return 1
        print(msg)
    else:
        print(__doc__, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
