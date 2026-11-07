#!/usr/bin/env python3
"""Drives a QEMU boot over its serial + monitor sockets.

    sb_drive.py SERIAL_SOCK MONITOR_SOCK LOG SHOTDIR PASSPHRASE TIMEOUT

Takes a screenshot every second for the first 25 s (that's where GRUB's menu is),
answers the LUKS prompt, and exits 0 once a login prompt shows up on the serial line.
Exit 2 on timeout. Never sends anything but the passphrase.
"""
import socket
import sys
import time

serial_path, mon_path, log_path, shot_dir, passphrase, timeout = sys.argv[1:7]
timeout = float(timeout)
SHOT_EVERY = float(sys.argv[7]) if len(sys.argv) > 7 else 1.0
SHOT_UNTIL = float(sys.argv[8]) if len(sys.argv) > 8 else 25.0


def connect(path):
    for _ in range(100):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            s.setblocking(False)
            return s
        except OSError:
            time.sleep(0.1)
    raise SystemExit(f"can't connect to {path}")


ser = connect(serial_path)
mon = connect(mon_path)
buf = b""
t0 = time.time()
next_shot, shot = 1.0, 0
unlocked = False
with open(log_path, "wb") as log:
    while time.time() - t0 < timeout:
        try:
            chunk = ser.recv(65536)
            if chunk:
                buf += chunk
                log.write(chunk)
                log.flush()
        except BlockingIOError:
            pass
        try:
            mon.recv(65536)  # drain the monitor chatter
        except BlockingIOError:
            pass
        el = time.time() - t0
        text = buf.decode("utf-8", "replace")
        # GRUB is on screen before the kernel starts talking on serial
        if el >= next_shot and el < SHOT_UNTIL and "Linux version" not in text:
            mon.sendall(f"screendump {shot_dir}/shot-{shot:03d}.ppm\n".encode())
            shot += 1
            next_shot += SHOT_EVERY
        if not unlocked and "Please unlock disk" in text:
            time.sleep(0.5)
            ser.sendall(passphrase.encode() + b"\r")
            unlocked = True
        if "login:" in text:
            mon.sendall(b"quit\n")
            sys.exit(0)
        time.sleep(0.05)
mon.sendall(b"quit\n")
sys.exit(2)
