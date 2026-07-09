#!/usr/bin/env python3
import errno
import fcntl
import os
import select
import sys
import time


PROC_PATH = "/proc/axvisor_guest_console"
FILL_CHUNK = b"x" * 512


def main() -> int:
    fd = os.open(PROC_PATH, os.O_WRONLY | os.O_NONBLOCK)
    total = 0
    eagain = False

    try:
        while True:
            try:
                n = os.write(fd, FILL_CHUNK)
            except BlockingIOError:
                eagain = True
                break
            if n <= 0:
                print(f"unexpected short write n={n}", flush=True)
                return 2
            total += n

        print(f"nonblock_fill_bytes={total}", flush=True)
        print(f"nonblock_eagain={int(eagain)}", flush=True)

        poller = select.poll()
        poller.register(fd, select.POLLOUT)
        events = poller.poll(0)
        writable = 0
        if events and (events[0][1] & select.POLLOUT):
            writable = 1
        print(f"pollout_after_fill={writable}", flush=True)

    finally:
        os.close(fd)

    fd = os.open(PROC_PATH, os.O_WRONLY)
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    try:
        try:
            os.write(fd, b"z")
            print("blocking_fd_write_after_fill=unexpected_success", flush=True)
            return 3
        except BlockingIOError:
            print("blocking_fd_write_after_fill=eagain_with_nonblock_toggle", flush=True)
    finally:
        fcntl.fcntl(fd, fcntl.F_SETFL, flags)

    pid = os.fork()
    if pid == 0:
        try:
            start = time.monotonic()
            os.write(fd, b"y")
            elapsed_ms = int((time.monotonic() - start) * 1000)
            print(f"blocking_write_elapsed_ms={elapsed_ms}", flush=True)
            os._exit(0)
        except OSError as exc:
            print(f"blocking_write_errno={exc.errno}", flush=True)
            os._exit(4)

    time.sleep(2)
    done_pid, status = os.waitpid(pid, os.WNOHANG)
    blocked_after_2s = int(done_pid == 0)
    print(f"blocking_write_still_blocked_after_2s={blocked_after_2s}", flush=True)
    if done_pid == 0:
        os.kill(pid, 9)
        os.waitpid(pid, 0)

    os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
