"""Shared razerctl playback for the stream examples."""

import argparse
import math
import os
import select
import shlex
import signal
import subprocess
import sys
import threading
import time

WINDOWS = sys.platform == "win32"
MAX_FRAME_BYTES = 4096 if WINDOWS else select.PIPE_BUF


def clamp(value):
    return max(0.0, min(1.0, value))


def mix(first, second, amount):
    return tuple(a + (b - a) * amount for a, b in zip(first, second))


def rgb_frame(colors, brightness):
    return bytes(round(255 * clamp(channel * brightness))
                 for color in colors for channel in color)


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return number


def parser(description):
    script = shlex.quote(sys.argv[0])
    result = argparse.ArgumentParser(
        description=description,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""Run an animation:
  python3 {script}

Select a device:
  python3 {script} 0x02b6""")
    result.add_argument("id", nargs="?", help="Device ID; defaults to your laptop.")
    result.add_argument("--razerctl", default="./zig-out/bin/razerctl",
                        help="razerctl executable (default: ./zig-out/bin/razerctl).")
    return result


def discover(command):
    result = subprocess.run(command + ["--info"], capture_output=True, text=True,
                            timeout=10)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "cannot read device layout")
    fields = {}
    for line in result.stdout.splitlines():
        words = line.split()
        if words and words[0] in ("rows", "columns", "frame-bytes"):
            if len(words) != 2 or words[0] in fields:
                raise ValueError("invalid layout from razerctl stream --info")
            fields[words[0]] = int(words[1])
    if set(fields) != {"rows", "columns", "frame-bytes"}:
        raise ValueError("missing layout from razerctl stream --info")
    rows, columns = fields["rows"], fields["columns"]
    if rows <= 0 or columns <= 0 or rows * columns * 3 > MAX_FRAME_BYTES:
        raise ValueError("unsupported frame dimensions")
    if fields["frame-bytes"] != rows * columns * 3:
        raise ValueError("inconsistent frame size")
    return rows, columns


def write_frame(output, frame, stopped):
    if WINDOWS:
        # A frame fits the pipe buffer, so this write returns without blocking.
        os.write(output, frame)
        return
    # Frames fit PIPE_BUF, so a cancelled nonblocking write cannot leave a partial frame.
    remaining = memoryview(frame)
    while remaining and not stopped.is_set():
        if not select.select([], [output], [], 0.1)[1]:
            continue
        try:
            count = os.write(output, remaining)
        except BlockingIOError:
            continue
        remaining = remaining[count:]


def play(args, factory):
    command = [args.razerctl, "stream"] + ([args.id] if args.id else [])
    rows, columns = discover(command)
    scene = factory(rows, columns, args)
    stopped = threading.Event()
    previous = {}
    child = None
    status = None
    try:
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous[sig] = signal.signal(sig, lambda *_: stopped.set())
        # A separate session or process group keeps Ctrl-C away from razerctl,
        # which stops when its input closes.
        isolate = ({"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if WINDOWS
                   else {"start_new_session": True})
        child = subprocess.Popen(command, stdin=subprocess.PIPE, **isolate)
        output = child.stdin.fileno()
        if not WINDOWS:
            os.set_blocking(output, False)
        start = last = time.monotonic()
        try:
            while not stopped.is_set() and child.poll() is None:
                now = time.monotonic()
                elapsed = now - start
                frame = rgb_frame(scene.render(elapsed, now - last), 0.65)
                if len(frame) != rows * columns * 3:
                    raise ValueError("renderer produced the wrong frame size")
                last = now
                write_frame(output, frame, stopped)
                delay = max(0, 1 / 25 - (time.monotonic() - now))
                stopped.wait(delay)
        except BrokenPipeError:
            pass
    finally:
        try:
            if child is not None:
                child.stdin.close()
                try:
                    status = child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
                    raise RuntimeError("razerctl did not stop after closing its input")
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    if status:
        raise RuntimeError(f"razerctl stream exited with status {status}")
    if not stopped.is_set():
        raise RuntimeError("razerctl stream stopped unexpectedly")
    return 130


def run(cli, factory):
    args = cli.parse_args()
    if not (WINDOWS or sys.platform.startswith("linux")):
        cli.error("these examples require Linux or Windows")
    try:
        return play(args, factory)
    except KeyboardInterrupt:
        return 130
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"{cli.prog}: {error}", file=sys.stderr)
        return 1
