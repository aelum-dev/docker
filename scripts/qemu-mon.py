#!/usr/bin/env python3
"""Send commands to a running QEMU's human monitor over its unix socket.

The monitor is what makes the boot menu testable from the host: `sendkey` drives
rEFInd and `screendump` writes the guest's screen to a PPM. Start a VM that has
one with:

    HEADLESS=1 MONITOR=logs/menu/monitor.sock ./scripts/run-iso.sh &     # the ISO
    BOOT_DISK=1 HEADLESS=1 MONITOR=logs/menu/monitor.sock ./scripts/run-iso.sh &

    ./scripts/qemu-mon.py "info status"
    ./scripts/qemu-mon.py "sendkey f2" "screendump /tmp/menu.ppm"

Each command is sent on its own line and its reply is printed, so this is also
a way to hold rEFInd's menu up: a keypress restarts its boot countdown.
"""

import argparse
import os
import socket
import sys
import time

DEFAULT_SOCKET = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                              "logs", "menu", "monitor.sock")


def connect(path: str, wait: float) -> socket.socket:
    """Open the monitor socket, waiting up to `wait` seconds for the VM to create it."""
    deadline = time.time() + wait
    while True:
        if os.path.exists(path):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(path)
                s.setblocking(False)
                return s
            except OSError:
                pass
        if time.time() >= deadline:
            raise SystemExit(f"no QEMU monitor at {path}; start one with MONITOR={path}")
        time.sleep(0.2)


def drain(s: socket.socket) -> str:
    out = b""
    while True:
        try:
            chunk = s.recv(65536)
        except (BlockingIOError, OSError):
            return out.decode(errors="replace")
        if not chunk:
            return out.decode(errors="replace")
        out += chunk


def clean(reply: str) -> str:
    """Drop what the monitor echoes back of the command itself.

    The human monitor redraws the line it is being typed into (CSI sequences and
    a growing copy of the command), which reads as noise when the answer to
    `info status` is what was asked for.
    """
    lines = []
    for line in reply.splitlines():
        if "\x1b" in line or "(qemu)" in line:
            continue
        if not line.strip():
            continue
        lines.append(line)
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--socket", default=DEFAULT_SOCKET, help="QEMU monitor unix socket")
    ap.add_argument("--wait", type=float, default=1.0, help="seconds to wait for the socket")
    ap.add_argument("--gap", type=float, default=1.0, help="seconds to wait for each reply")
    ap.add_argument("command", nargs="+", help="monitor commands, in order")
    args = ap.parse_args()

    s = connect(args.socket, args.wait)
    time.sleep(0.3)
    drain(s)  # the monitor's banner
    for cmd in args.command:
        s.sendall((cmd + "\n").encode())
        time.sleep(args.gap)
        reply = clean(drain(s))
        if reply:
            print(reply)
    s.close()


if __name__ == "__main__":
    sys.exit(main())
