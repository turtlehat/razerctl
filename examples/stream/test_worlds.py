"""Offline simulation and subprocess playback checks."""

import importlib.util
import math
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from fireworks import Fireworks


spec = importlib.util.spec_from_file_location(
    "digital_rain", Path(__file__).with_name("digital-rain.py"))
digital_rain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(digital_rain)
DigitalRain = digital_rain.DigitalRain

LAYOUTS = ((1, 16), (6, 16), (6, 17), (7, 19), (1, 102), (1, 114))
WORLDS = (Fireworks, DigitalRain)


class WorldTests(unittest.TestCase):
    def test_all_layouts_evolve_with_finite_bounded_colors(self):
        for world in WORLDS:
            for rows, columns in LAYOUTS:
                with self.subTest(world=world.__name__, layout=(rows, columns)):
                    scene = world(rows, columns)
                    frames = []
                    peak = 0
                    for tick in range(201):
                        frame = scene.render(tick / 25, 1 / 25)
                        self.assertEqual(len(frame), rows * columns)
                        self.assertTrue(all(len(c) == 3 and all(
                            math.isfinite(v) and 0 <= v <= 1 for v in c) for c in frame))
                        peak = max(peak, max(max(c) for c in frame))
                        if tick % 25 == 0:
                            frames.append(tuple(frame))
                    self.assertGreater(len(set(frames)), 6)
                    self.assertGreater(peak, 0.65)

    def test_seeded_reproducibility_and_frozen_zero_dt(self):
        for world in WORLDS:
            first, second = world(6, 16), world(6, 16)
            other = world(6, 16, seed=42)
            for tick in range(101):
                frame = first.render(tick / 25, 1 / 25)
                self.assertEqual(frame, second.render(tick / 25, 1 / 25))
                different = other.render(tick / 25, 1 / 25)
            self.assertNotEqual(frame, different)
            self.assertEqual(first.render(1000, 0), first.render(2000, 0))

    def test_bounded_state_after_long_run_and_stall(self):
        for world in WORLDS:
            for rows, columns in LAYOUTS:
                scene = world(rows, columns)
                for _ in range(4000):
                    scene._advance(0.25)
                before = scene.time
                scene.render(100000, 100000)
                self.assertLessEqual(scene.time - before, 0.25)
                if world is Fireworks:
                    self.assertLessEqual(len(scene.shells), 1)
                    self.assertLessEqual(len(scene._lights()), 49)
                else:
                    self.assertLessEqual(len(scene.drops), max(3, columns // 3))
                    self.assertEqual(len(scene.glyphs), rows * columns)

    def test_fireworks_launch_then_expand_in_both_dimensions(self):
        scene = Fireworks(6, 16)
        scene._advance(0)
        shell = scene.shells[0]
        scene.time = shell["rise"] * 0.5
        rocket = scene._lights()
        self.assertTrue(all(tint == (1.0, 0.60, 0.15) for _, _, tint, _ in rocket))
        scene.time = shell["rise"] + 0.5
        burst = scene._lights()
        self.assertGreater(max(x for x, _, _, _ in burst)
                           - min(x for x, _, _, _ in burst), 0.3)
        self.assertGreater(max(y for _, y, _, _ in burst)
                           - min(y for _, y, _, _ in burst), 0.5)
        self.assertGreater(len(burst), 40)

    def test_fireworks_reach_top_then_fall_and_fade_without_overlap(self):
        scene = Fireworks(6, 16)
        scene._advance(0)
        shell = scene.shells[0]
        scene.time = shell["rise"] - 0.001
        rocket = scene._lights()
        self.assertLess(rocket[0][1], 0.001)
        self.assertGreater(max(y for _, y, _, _ in rocket), 0.4)
        positions, strengths = [], []
        for age in (0.8, 2.0, 3.8):
            scene.time = shell["rise"] + age
            lights = scene._lights()[:-1]
            positions.append(sum(y for _, y, _, _ in lights) / len(lights))
            strengths.append(sum(strength for _, _, _, strength in lights))
        self.assertLess(positions[0], positions[1])
        self.assertLess(positions[1], positions[2])
        self.assertGreater(strengths[0], strengths[1])
        self.assertGreater(strengths[1], strengths[2])
        for _ in range(1000):
            scene._advance(0.04)
            self.assertLessEqual(len(scene.shells), 1)

    def test_rain_moves_down_with_green_trails_and_pale_heads(self):
        scene = DigitalRain(6, 16)
        scene.drops = [{"column": 4, "position": 2.0, "speed": 4.0,
                        "tail": 4.0, "strength": 1.0}]
        frame = scene.render(0, 0)
        head, tail, ahead = frame[2 * 16 + 4], frame[16 + 4], frame[4 * 16 + 4]
        self.assertGreater(head[0], tail[0])
        self.assertGreater(tail[1], tail[0] * 3)
        self.assertGreater(tail[1], ahead[1])
        scene._advance(0.25)
        self.assertEqual(scene.drops[0]["position"], 3.0)


class CaptureTests(unittest.TestCase):
    def test_child_playback_all_layouts_without_hardware(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake, capture, ready, queries = [root / name for name in
                                             ("razerctl", "frames", "ready", "queries")]
            for rows, columns in LAYOUTS:
                size = rows * columns * 3
                fake.write_text(
                    f"#!{sys.executable}\n"
                    "import pathlib, sys\n"
                    f"with pathlib.Path({str(queries)!r}).open('a') as log:\n"
                    "    log.write(' '.join(sys.argv[1:]) + '\\n')\n"
                    "if sys.argv[1:] == ['stream', 'fake-device', '--info']:\n"
                    f"    print('rows {rows}\\ncolumns {columns}\\nframe-bytes {size}')\n"
                    "    raise SystemExit(0)\n"
                    "if sys.argv[1:] != ['stream', 'fake-device']:\n"
                    "    raise SystemExit(9)\n"
                    f"with pathlib.Path({str(capture)!r}).open('wb', buffering=0) as out:\n"
                    f"    while frame := sys.stdin.buffer.read({size}):\n"
                    "        out.write(frame)\n"
                    f"        if out.tell() >= {size * 3}:\n"
                    f"            pathlib.Path({str(ready)!r}).touch()\n")
                fake.chmod(0o700)
                for name in ("fireworks.py", "digital-rain.py"):
                    with self.subTest(program=name, layout=(rows, columns)):
                        ready.unlink(missing_ok=True)
                        queries.write_text("")
                        child = subprocess.Popen(
                            [sys.executable, str(Path(__file__).with_name(name)),
                             "fake-device", "--razerctl", str(fake)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        try:
                            deadline = time.monotonic() + 5
                            while not ready.exists() and time.monotonic() < deadline:
                                if child.poll() is not None:
                                    self.fail(f"producer exited early: {child.communicate()}")
                                time.sleep(0.01)
                            self.assertTrue(ready.exists())
                            child.send_signal(signal.SIGINT)
                            output, errors = child.communicate(timeout=8)
                            self.assertEqual(child.returncode, 130, errors)
                            self.assertEqual((output, errors), (b"", b""))
                            data = capture.read_bytes()
                            self.assertGreaterEqual(len(data), size * 3)
                            self.assertEqual(len(data) % size, 0)
                            self.assertTrue(any(data))
                            self.assertEqual(queries.read_text(),
                                             "stream fake-device --info\nstream fake-device\n")
                        finally:
                            if child.poll() is None:
                                child.kill()
                                child.communicate()


if __name__ == "__main__":
    unittest.main()
