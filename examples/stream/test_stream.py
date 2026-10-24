import importlib.util
import io
import math
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

from _stream import discover, parser, rgb_frame, run
from solstice import Solstice

spec = importlib.util.spec_from_file_location(
    "ghost", Path(__file__).with_name("ghost-in-the-machine.py"))
ghost = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ghost)

LAYOUTS = ((1, 16), (6, 16), (6, 17), (7, 19), (1, 102), (1, 114))


class Meter:
    def __init__(self, value=0):
        self.value = value

    def read(self):
        return self.value


class SceneTests(unittest.TestCase):
    def test_help_shows_options_and_direct_invocation(self):
        with patch.object(sys, "argv", ["examples/stream/fireworks.py"]), \
                patch.object(sys, "stdout", new_callable=io.StringIO) as output:
            parser("Colourful fireworks.").print_help()
            help_text = output.getvalue()
            for option in ("--razerctl",):
                self.assertIn(option, help_text)
            for option in ("--seconds", "--brightness", "--fps"):
                self.assertNotIn(option, help_text)
            self.assertIn("python3 examples/stream/fireworks.py 0x02b6", help_text)
            self.assertNotIn("|", help_text)
            self.assertNotIn("Ctrl-C", help_text)

    def test_terminal_invocation_starts_playback(self):
        with patch.object(sys, "argv", ["fireworks.py"]), \
                patch.object(sys.stdout, "isatty", return_value=True), \
                patch("_stream.play", return_value=130) as play:
            self.assertEqual(run(parser("Colourful fireworks."), None), 130)
            play.assert_called_once()

    def test_all_laptop_frame_sizes_and_channels(self):
        for rows, columns in LAYOUTS:
            scenes = (Solstice(rows, columns), ghost.Ghost(rows, columns, Meter(0.8)))
            for scene in scenes:
                for tick in range(0, 201, 5):
                    colors = scene.render(tick, 0.2)
                    self.assertEqual(len(colors), rows * columns)
                    self.assertTrue(all(math.isfinite(v) and 0 <= v <= 1
                                        for color in colors for v in color))
                    self.assertEqual(len(rgb_frame(colors, 0.65)), rows * columns * 3)

    def test_solstice_has_distinct_days_and_nights(self):
        for rows, columns in LAYOUTS:
            scene = Solstice(rows, columns, day_seconds=180)
            noon = scene.render((0.5 - 0.22) * 180, 0)
            night = scene.render((1 - 0.22) * 180, 0)
            self.assertGreater(sum(map(sum, noon)), sum(map(sum, night)) * 1.5)
            self.assertNotEqual(noon, night)
            self.assertGreater(len(set(noon)), 4)

    def test_solstice_cycle_wrap_is_smooth(self):
        scene = Solstice(6, 16, day_seconds=180)
        wrap = (1 - 0.22) * scene.day_seconds
        before, after = scene.render(wrap - 0.001, 0), scene.render(wrap + 0.001, 0)
        self.assertLess(max(abs(a - b) for c, d in zip(before, after)
                            for a, b in zip(c, d)), 0.002)

    def test_clouds_and_stars_change_between_days(self):
        scene = Solstice(6, 16, day_seconds=180)
        self.assertNotEqual(scene.render(0, 0), scene.render(180, 0))

    def test_solstice_realtime_uses_local_time(self):
        import datetime
        noon_time = datetime.datetime(2026, 1, 1, 12, 0)
        midnight_time = datetime.datetime(2026, 1, 1, 0, 0)
        with patch("solstice.datetime.datetime") as clock:
            clock.now.return_value = noon_time
            realtime = Solstice(6, 16)
            noon = realtime.render(0, 0)
            clock.now.return_value = midnight_time
            night = realtime.render(0, 0)
            self.assertGreater(sum(map(sum, noon)), sum(map(sum, night)) * 1.5)

    def test_ghost_load_heats_then_cools_and_produces_pulses(self):
        for rows, columns in LAYOUTS:
            meter = Meter()
            scene = ghost.Ghost(rows, columns, meter)
            idle = scene.render(0, 0)
            self.assertGreater(sum(c[2] for c in idle), sum(c[0] for c in idle))
            meter.value = 1
            for tick in range(1, 126):
                hot = scene.render(tick / 25, 1 / 25)
            self.assertGreater(scene.load, 0.99)
            self.assertGreater(sum(c[0] for c in hot), sum(c[2] for c in hot))
            self.assertTrue(any(pulse[3] for pulse in scene.pulses))
            meter.value = 0
            for tick in range(126, 301):
                scene.render(tick / 25, 1 / 25)
            self.assertLess(scene.load, 0.10)
            self.assertTrue(any(not pulse[3] for pulse in scene.pulses))
            for tick in range(301, 751):
                cool = scene.render(tick / 25, 1 / 25)
            self.assertGreater(sum(c[2] for c in cool), sum(c[0] for c in cool))
            self.assertEqual(len(scene.pulses), 0)

    def test_ghost_settles_under_noisy_idle_load(self):
        class Noise:
            def __init__(self):
                self.rng = __import__("random").Random(4)

            def read(self):
                return self.rng.choice((0, 0, 0.02, 0.05, 0.09, 0.24))

        scene = ghost.Ghost(6, 16, Noise())
        for tick in range(25 * 300):
            scene.render(tick / 25, 1 / 25)
        self.assertEqual(len(scene.pulses), 0)
        self.assertLess(scene.load, 0.08)

    def test_ghost_long_run_has_no_sudden_flashes(self):
        class Bursty:
            def __init__(self):
                self.rng = __import__("random").Random(7)

            def read(self):
                return self.rng.choice((0.03, 0.1, 0.3, 0.7, 1.0))

        scene = ghost.Ghost(6, 16, Bursty())
        previous = scene.render(0, 0)
        pulses = set()
        for tick in range(1, 25 * 600):
            colors = scene.render(tick / 25, 1 / 25)
            jump = max(abs(a - b) for c, d in zip(colors, previous) for a, b in zip(c, d))
            self.assertLess(jump, 0.5)
            pulses.update(pulse[0] for pulse in scene.pulses)
            previous = colors
        self.assertGreater(len(pulses), 0)
        self.assertLessEqual(len(pulses), 600 / 2)

    def test_ghost_smoothing_is_frame_rate_independent(self):
        loads = []
        for fps in (10, 25, 60):
            scene = ghost.Ghost(6, 16, Meter(1))
            for tick in range(1, fps * 3 + 1):
                scene.render(tick / fps, 1 / fps)
            loads.append(scene.load)
        self.assertLess(max(loads) - min(loads), 1e-10)

    def test_cpu_meter_excludes_guest_and_includes_iowait_as_idle(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stat"
            path.write_text("cpu 100 10 20 200 50 5 5 10 80 8\n")
            meter = ghost.CpuMeter(path)
            self.assertEqual(meter.previous, {"cpu": (400, 250)})
            self.assertIsNone(meter.read())
            path.write_text("cpu 150 10 20 240 60 5 5 10 90 8\n")
            self.assertAlmostEqual(meter.read(), 0.5)
            path.write_text("invalid\n")
            with self.assertRaises(ValueError):
                meter.read()

    def test_one_busy_core_is_visible_without_looking_fully_loaded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stat"
            path.write_text("cpu 0 0 0 1600 0 0 0 0\n" +
                            "".join(f"cpu{i} 0 0 0 100 0 0 0 0\n" for i in range(16)))
            meter = ghost.CpuMeter(path)
            path.write_text("cpu 100 0 0 3100 0 0 0 0\n" +
                            "cpu0 100 0 0 100 0 0 0 0\n" +
                            "".join(f"cpu{i} 0 0 0 200 0 0 0 0\n" for i in range(1, 16)))
            activity = meter.read()
            self.assertAlmostEqual(activity, 0.625)
            self.assertGreater(activity, 0.6)
            self.assertLess(activity, 1)

    def test_rgb_output_clamps_and_scales(self):
        self.assertEqual(rgb_frame([(-1, 0.5, 3)], 0.5), bytes((0, 64, 255)))


class StreamTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.fake = self.root / "razerctl"
        self.capture = self.root / "frames"
        self.receipt = self.root / "closed"
        self.ready = self.root / "ready"
        self.queries = self.root / "queries"
        self.make_fake()

    def make_fake(self, rows=6, columns=16, mode="normal", info=None):
        output = info if info is not None else (
            f"protocol legacy_rows\nrows {rows}\ncolumns {columns}\n"
            f"frame-bytes {rows * columns * 3}\nzone backlight id 5\n")
        self.fake.write_text(f"#!{sys.executable}\n" + textwrap.dedent(f"""\
            import pathlib, sys, time
            with pathlib.Path({str(self.queries)!r}).open('a') as log:
                log.write(' '.join(sys.argv[1:]) + '\\n')
            if '--info' in sys.argv:
                print({output!r}, end='')
                raise SystemExit(0)
            mode = {mode!r}
            if mode == 'fail':
                print('device unavailable', file=sys.stderr)
                raise SystemExit(1)
            if mode == 'stall':
                pathlib.Path({str(self.ready)!r}).touch()
                time.sleep(60)
            with pathlib.Path({str(self.capture)!r}).open('wb', buffering=0) as capture:
                while frame := sys.stdin.buffer.read({rows * columns * 3}):
                    capture.write(frame)
                    pathlib.Path({str(self.ready)!r}).touch()
                    if len(frame) != {rows * columns * 3}:
                        print('truncated frame', file=sys.stderr)
                        raise SystemExit(1)
            pathlib.Path({str(self.receipt)!r}).touch()
            if mode == 'restore-fail':
                print('restoration failed', file=sys.stderr)
                raise SystemExit(1)
            """))
        self.fake.chmod(0o700)

    def command(self, name, *options):
        return [sys.executable, str(Path(__file__).with_name(name)),
                "--razerctl", str(self.fake), *options]

    def wait_ready(self, child, size=0):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.ready.exists() and (not size or
                    self.capture.exists() and self.capture.stat().st_size >= size):
                return
            if child.poll() is not None:
                self.fail(f"producer exited early: {child.communicate()}")
            time.sleep(0.01)
        self.fail("consumer did not become ready")

    def test_both_programs_stream_all_six_layouts_and_close(self):
        for rows, columns in LAYOUTS:
            self.make_fake(rows, columns)
            for name in ("solstice.py", "ghost-in-the-machine.py"):
                self.ready.unlink(missing_ok=True)
                self.receipt.unlink(missing_ok=True)
                child = subprocess.Popen(self.command(name),
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    self.wait_ready(child, rows * columns * 3 * 3)
                    child.send_signal(signal.SIGINT)
                    output, errors = child.communicate(timeout=8)
                    data = self.capture.read_bytes()
                    self.assertEqual(child.returncode, 130, errors)
                    self.assertEqual(output, b"")
                    self.assertEqual(errors, b"")
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate()
                self.assertGreaterEqual(len(data), rows * columns * 3)
                self.assertEqual(len(data) % (rows * columns * 3), 0)
                self.assertTrue(self.receipt.exists())

    def test_bad_layout_and_invalid_options_fail_before_playback(self):
        self.make_fake(info="rows 6\ncolumns 16\nframe-bytes 12\n")
        with self.assertRaises(ValueError):
            discover([str(self.fake), "stream"])
        for option, value in (("--seconds", "nan"), ("--brightness", "1.1"),
                              ("--fps", "0"), ("--day-seconds", "-1")):
            result = subprocess.run(self.command("solstice.py", option, value),
                                    capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.receipt.exists())
        self.make_fake(info="rows 6\ncolumns 16\n")
        with self.assertRaises(ValueError):
            discover([str(self.fake), "stream"])
        self.make_fake(rows=100, columns=100)
        with self.assertRaises(ValueError):
            discover([str(self.fake), "stream"])

    def test_interrupt_ends_output_quietly_on_frame_boundary(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            self.ready.unlink(missing_ok=True)
            child = subprocess.Popen(self.command("solstice.py"),
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.wait_ready(child, 288)
                child.send_signal(sig)
                output, errors = child.communicate(timeout=8)
                data = self.capture.read_bytes()
                self.assertEqual(child.returncode, 130, errors)
                self.assertEqual(output, b"")
                self.assertEqual(errors, b"")
                self.assertTrue(self.receipt.exists())
                self.assertEqual(len(data) % 288, 0)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.communicate()

    def test_interrupt_during_backpressure_remains_responsive(self):
        self.make_fake(mode="stall")
        child = subprocess.Popen(self.command("solstice.py"),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.wait_ready(child)
            time.sleep(1)
            child.send_signal(signal.SIGINT)
            _, errors = child.communicate(timeout=12)
            self.assertEqual(child.returncode, 1)
            self.assertIn(b"did not stop", errors)
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()

    def test_failed_consumer_stops_producer_without_traceback(self):
        self.make_fake(mode="fail")
        result = subprocess.run(self.command("solstice.py"),
                                capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"device unavailable", result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)

    def test_same_device_is_used_for_query_and_playback(self):
        child = subprocess.Popen(self.command("solstice.py", "0x02b6"),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.wait_ready(child, 288)
            child.send_signal(signal.SIGINT)
            output, errors = child.communicate(timeout=8)
            self.assertEqual(child.returncode, 130, errors)
            self.assertEqual(output, b"")
            self.assertEqual(self.queries.read_text(),
                             "stream 0x02b6 --info\nstream 0x02b6\n")
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()

    def test_restoration_failure_is_reported_after_interrupt(self):
        self.make_fake(mode="restore-fail")
        child = subprocess.Popen(self.command("solstice.py"),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.wait_ready(child, 288)
            child.send_signal(signal.SIGINT)
            _, errors = child.communicate(timeout=8)
            self.assertEqual(child.returncode, 1)
            self.assertIn(b"restoration failed", errors)
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()


if __name__ == "__main__":
    unittest.main()
