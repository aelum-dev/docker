#!/usr/bin/env python3
"""Screenshot the installed system's rEFInd menu, and its snapshot submenu.

Driven through QEMU's monitor (see qemu-mon.py), so it needs no display on the
host: `sendkey` moves rEFInd's selection and `screendump` writes the guest's
screen. Frames land in logs/menu/ as .ppm, and as .png too when Pillow is
installed.

    ./scripts/menu-shots.py                 # main menu, snapshot entry, submenu
    ./scripts/menu-shots.py --entry 0       # screenshot the menu as rEFInd opens it
    ./scripts/menu-shots.py --then-boot     # then boot the install, so it rewrites its menu
    ./scripts/menu-shots.py --boot-snapshot # then boot the snapshot the menu points at

rEFInd counts down to its default boot. A keypress restarts that countdown, so
every screendump is preceded by `caps_lock`: a key rEFInd does not treat as a
selection, which keeps the menu on screen while it is being read.

How the menu is noticed: the frames before rEFInd runs are the firmware's own
text mode. rEFInd switches the console to its graphics mode, so a frame whose
size differs from the first one means the menu is up. If a theme kept the
resolution, the fallback is colour: a drawn menu has hundreds of distinct
colours, a black or text screen has almost none.
"""

import argparse
import os
import socket
import sys
import time

PROFILE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SOCKET = os.path.join(PROFILE_DIR, "logs", "menu", "monitor.sock")
DEFAULT_OUT = os.path.join(PROFILE_DIR, "logs", "menu")


class Monitor:
    def __init__(self, path: str) -> None:
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.s.setblocking(False)
        time.sleep(0.3)
        self.drain()

    def drain(self) -> str:
        out = b""
        while True:
            try:
                chunk = self.s.recv(65536)
            except (BlockingIOError, OSError):
                return out.decode(errors="replace")
            if not chunk:
                return out.decode(errors="replace")
            out += chunk

    def send(self, cmd: str, gap: float = 0.3) -> str:
        self.s.sendall((cmd + "\n").encode())
        time.sleep(gap)
        return self.drain()


def read_ppm(path: str):
    """Return (width, height, pixels) for a QEMU screendump, or None."""
    with open(path, "rb") as fh:
        raw = fh.read()
    if not raw.startswith(b"P6"):
        return None
    i, tokens = 3, []
    while len(tokens) < 4:
        while i < len(raw) and raw[i:i + 1].isspace():
            i += 1
        j = i
        while j < len(raw) and not raw[j:j + 1].isspace():
            j += 1
        tokens.append(raw[i:j])
        i = j
    w, h = int(tokens[1]), int(tokens[2])
    return w, h, raw[i:i + w * h * 3]


def colour_count(pixels) -> int:
    """How many distinct colours a frame uses, sampled every 8th pixel."""
    return len({pixels[i:i + 3] for i in range(0, len(pixels), 24)})


def save(frame: str, out_dir: str) -> str:
    """Also write a .png next to the .ppm when Pillow is available."""
    try:
        from PIL import Image
    except ImportError:
        return frame + ".ppm"
    png = frame + ".png"
    Image.open(frame + ".ppm").save(png)
    return os.path.basename(png)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--socket", default=DEFAULT_SOCKET, help="QEMU monitor unix socket")
    ap.add_argument("--out-dir", default=DEFAULT_OUT, help="where the frames are written")
    ap.add_argument("--entry", type=int, default=1,
                    help="arrow-right presses that move the selection (1 = the snapshot entry)")
    ap.add_argument("--no-submenu", action="store_true",
                    help="screenshot the main menu only")
    ap.add_argument("--boot-snapshot", action="store_true",
                    help="inside the submenu, go down to the first snapshot and boot it")
    ap.add_argument("--then-boot", action="store_true",
                    help="after the screenshots, boot this install the normal way")
    ap.add_argument("--settle", type=float, default=60.0,
                    help="seconds to let a --then-boot run spend in the installed system")
    ap.add_argument("--timeout", type=float, default=90.0,
                    help="seconds to wait for the menu to appear")
    args = ap.parse_args()

    if not os.path.exists(args.socket):
        print(f"no QEMU monitor at {args.socket}\n"
              f"  BOOT_DISK=1 HEADLESS=1 MONITOR={args.socket} ./scripts/run-iso.sh &",
              file=sys.stderr)
        return 2
    os.makedirs(args.out_dir, exist_ok=True)

    m = Monitor(args.socket)
    base = os.path.join(args.out_dir, "menu")

    def shot(name: str, hold: bool = True):
        path = base + f"-{name}"
        if hold:
            m.send("sendkey caps_lock")
        m.send(f"screendump {path}.ppm", 0.5)
        frame = read_ppm(path + ".ppm")
        if frame is None:
            print(f"  {name}: screendump failed", file=sys.stderr)
            return None
        written = save(path, args.out_dir)
        print(f"  {name}: {frame[0]}x{frame[1]} -> {written}")
        return frame

    # --- wait for rEFInd -------------------------------------------------
    print("waiting for the boot menu ...")
    first = None
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        frame = shot("wait", hold=False)
        if frame is None:
            return 2
        if first is None:
            first = frame
            time.sleep(0.4)
            continue
        if frame[:2] != first[:2] or colour_count(frame[2]) > 400:
            break
        time.sleep(0.4)
    else:
        print("the menu never appeared. The firmware probably has no Aelum entry:\n"
              "  make -C docker demo-snapshots   recreates it after a test-boot\n"
              "  make -C docker vm-clean         clears the NVRAM for a clean start",
              file=sys.stderr)
        return 1

    # --- main menu -------------------------------------------------------
    print("main menu:")
    shot("01-menu")

    # --- the snapshot entry ----------------------------------------------
    for _ in range(max(0, args.entry)):
        m.send("sendkey right")
    if args.entry:
        shot("02-snapshot-entry")

    # --- its submenu -----------------------------------------------------
    if not args.no_submenu:
        m.send("sendkey f2")
        time.sleep(0.5)
        print("snapshot submenu:")
        shot("03-submenu")
        if args.boot_snapshot:
            # The first line of a submenu is rEFInd's own "Boot using default
            # options" (the parent entry); one step down is a real snapshot.
            m.send("sendkey down")
            shot("04-submenu-first")
            m.send("sendkey ret", 1.0)
            print("booting that snapshot; the frames below are the boot, not the menu:")
            for i in range(5, 9):
                shot(f"{i:02d}-boot", hold=False)
                time.sleep(2.0)

    m.send("info status")

    # --- optional: boot the install itself --------------------------------
    # The menu on the ESP is written by the installed system, so a snapshot set
    # that was made from the live ISO is not in it yet. Booting the install once
    # (its own entry, not a snapshot: a snapshot boot leaves the menu alone) runs
    # aelum-refind-snapshots.service, and the next screenshot shows the truth.
    if args.then_boot:
        m.send("sendkey esc", 0.6)
        for _ in range(max(0, args.entry)):
            m.send("sendkey left")
        print("booting this install, so it can rebuild its own menu:")
        m.send("sendkey ret", 2.0)
        time.sleep(args.settle)
        shot("04-installed", hold=False)

    return 0


if __name__ == "__main__":
    sys.exit(main())
