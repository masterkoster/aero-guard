#!/usr/bin/env python3
"""Launch the AERO-GUARD API server as a truly detached process.

`jac run --serve` takes ~110s on a cold graph (1,740 airports / 2,322 runways),
so it has to survive the shell that launched it.  Backgrounding with `&`,
`nohup`, or `screen` all die here because the parent process group gets
reaped.  `start_new_session=True` calls setsid(2), which puts the child in a
fresh session with no controlling terminal, so it outlives the shell.

    python3 scripts/serve.py [--port 8080] [--stop]

Logs to /tmp/aero<port>.log.  Poll the log, or wait for /openapi.json to
answer 200.
"""

import argparse
import os
import signal
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JAC = os.path.join(ROOT, ".venv", "bin", "jac")
ENTRY = "main.jac"
PIDFILE = "/tmp/aero-guard-server.pid"


def alive(pid: int) -> bool:
    """True only for a process that still exists and is not a zombie.

    Plain `os.kill(pid, 0)` succeeds for zombies, which made a crashed server
    look healthy for the whole startup window.
    """
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    try:
        with open(f"/proc/{pid}/stat") as fh:  # absent on macOS, see below
            return fh.read().split(") ", 1)[1].split()[0] != "Z"
    except OSError:
        pass
    # macOS has no /proc; ask ps for the state field.
    import subprocess

    try:
        out = subprocess.run(
            ["ps", "-o", "state=", "-p", str(pid)],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except Exception:
        return False
    return bool(out) and not out.startswith("Z")


def daemonize(argv: list[str], log_path: str) -> int:
    """Double fork so the server reparents to init and outlives its shell.

    A single fork (or `start_new_session=True`) still leaves the process in the
    launcher's process tree, and anything that walks that tree reaps it.  The
    intermediate child exits immediately, so the long-lived grandchild's PPID
    is 1 and the tree walk finds nothing.
    """
    first = os.fork()
    if first > 0:
        os.waitpid(first, 0)
        return 0

    os.setsid()
    second = os.fork()
    if second > 0:
        os._exit(0)

    # Grandchild: wire up stdio, then become the server.  execv keeps this pid,
    # so recording it now is recording the server's pid.
    with open(PIDFILE, "w") as fh:
        fh.write(str(os.getpid()))

    devnull = os.open(os.devnull, os.O_RDONLY)
    os.dup2(devnull, 0)
    log = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.dup2(log, 1)
    os.dup2(log, 2)
    for extra in range(3, 64):
        try:
            os.close(extra)
        except OSError:
            break
    os.chdir(ROOT)
    os.environ["PYTHONUNBUFFERED"] = "1"
    os.execv(argv[0], argv)
    os._exit(127)  # unreachable unless exec failed


def read_pid() -> int:
    try:
        with open(PIDFILE) as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return 0


def probe(port: int, timeout: float = 3.0) -> int:
    url = f"http://localhost:{port}/openapi.json"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except Exception:
        return 0


def stop() -> int:
    pid = read_pid()
    if not pid or not alive(pid):
        print("no tracked server running")
        return 0
    os.kill(pid, signal.SIGTERM)
    for _ in range(20):
        if not alive(pid):
            break
        time.sleep(0.5)
    if alive(pid):
        os.kill(pid, signal.SIGKILL)
    os.remove(PIDFILE)
    print(f"stopped pid {pid}")
    return 0


def start(port: int, wait: float) -> int:
    if not os.path.exists(JAC):
        print(f"missing {JAC}")
        return 1

    old = read_pid()
    if old and alive(old):
        print(f"already running as pid {old}")
        return 0

    log_path = f"/tmp/aero{port}.log"
    log = open(log_path, "wb")
    proc = subprocess.Popen(
        [JAC, "run", ENTRY, "--serve", "--port", str(port)],
        cwd=ROOT,
        stdout=log,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,  # setsid: survive the launching shell
    )
    with open(PIDFILE, "w") as fh:
        fh.write(str(proc.pid))
    print(f"launched pid {proc.pid} -> {log_path}")

    # The cold graph build is the whole wait.  Poll rather than sleep blindly so
    # a crash is reported as a crash instead of a timeout.
    deadline = time.time() + wait
    while time.time() < deadline:
        if not alive(proc.pid):
            print("server exited during startup; log follows:")
            with open(log_path) as fh:
                sys.stdout.write(fh.read()[-4000:])
            return 1
        code = probe(port)
        if code == 200:
            print(f"ready on http://localhost:{port} after "
                  f"{int(wait - (deadline - time.time()))}s")
            return 0
        time.sleep(3)

    print(f"not ready after {int(wait)}s (still building graph?); log: {log_path}")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--wait", type=float, default=300.0)
    ap.add_argument("--stop", action="store_true")
    args = ap.parse_args()
    if args.stop:
        return stop()
    return start(args.port, args.wait)


if __name__ == "__main__":
    sys.exit(main())
