#!/usr/bin/env python3
"""Neon blue at rest, crimson under load, with scanning currents and electric pulses."""

import math
import os
import random
import sys
from collections import deque

from _stream import clamp, mix, parser, run


IDLE_FLOOR = 0.10
PULSE_CHANGE = 0.12
SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION = 8


def windows_counters():
    import ctypes

    class Performance(ctypes.Structure):
        _fields_ = [("idle", ctypes.c_int64), ("kernel", ctypes.c_int64),
                    ("user", ctypes.c_int64), ("dpc", ctypes.c_int64),
                    ("interrupt", ctypes.c_int64), ("interrupt_count", ctypes.c_ulong)]

    cores = (Performance * os.cpu_count())()
    status = ctypes.WinDLL("ntdll").NtQuerySystemInformation(
        SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION, cores, ctypes.sizeof(cores), None)
    if status:
        raise ValueError("cannot read CPU counters from Windows")
    # Kernel time already includes idle time.
    counters = {f"cpu{index}": (core.kernel + core.user, core.idle)
                for index, core in enumerate(cores)}
    counters["cpu"] = tuple(sum(values) for values in zip(*counters.values()))
    return counters


class CpuMeter:
    def __init__(self, path="/proc/stat"):
        self.path = path
        self.previous = self.counters()

    def counters(self):
        if sys.platform == "win32":
            return windows_counters()
        counters = {}
        with open(self.path, encoding="ascii") as source:
            for line in source:
                words = line.split()
                if not words or not (words[0] == "cpu" or
                                     (words[0].startswith("cpu") and words[0][3:].isdigit())):
                    continue
                if len(words) < 9:
                    raise ValueError("incomplete CPU counters")
                # Guest time is already included in user/nice.
                values = [int(word) for word in words[1:9]]
                if any(value < 0 for value in values):
                    raise ValueError("invalid CPU counters")
                counters[words[0]] = sum(values), values[3] + values[4]
        if "cpu" not in counters:
            raise ValueError("cannot read aggregate CPU counters from /proc/stat")
        return counters

    def read(self):
        current = self.counters()
        loads = {}
        for name, (total_now, idle_now) in current.items():
            if name not in self.previous:
                continue
            total = total_now - self.previous[name][0]
            idle = idle_now - self.previous[name][1]
            if total < 0 or idle < 0:
                raise ValueError("CPU counters moved backwards")
            if total:
                loads[name] = clamp(1 - idle / total)
        self.previous = current
        if "cpu" not in loads:
            return None
        overall = loads.pop("cpu")
        peak = max(loads.values(), default=overall)
        # Let one busy core wake the scene without making it look like full-system load.
        return max(overall, 0.6 * peak + 0.4 * overall)


class Ghost:
    def __init__(self, rows, columns, meter=None, seed=91):
        self.rows, self.columns = rows, columns
        self.meter = meter if meter is not None else CpuMeter()
        self.rng = random.Random(seed)
        self.load = self.target = self.baseline = self.scan = 0.0
        self.last_sample = -1.0
        self.last_pulse = -10.0
        self.pulses = deque(maxlen=24)
        self.cells = [(column / max(1, columns - 1), row / max(1, rows - 1))
                      for row in range(rows) for column in range(columns)]

    def render(self, elapsed, dt):
        if elapsed - self.last_sample >= 1:
            reading = self.meter.read()
            if reading is not None:
                # Background chatter stays below the floor so an idle machine rests.
                self.target = clamp((reading - IDLE_FLOOR) / (1 - IDLE_FLOOR))
            self.last_sample = elapsed
        response = 0.35 if self.target > self.load else 2.0
        self.load += (self.target - self.load) * (1 - math.exp(-dt / response))
        self.baseline += (self.load - self.baseline) * (1 - math.exp(-dt / 4))
        change = self.load - self.baseline
        if abs(change) > PULSE_CHANGE and elapsed - self.last_pulse > 2:
            self.pulses.append((elapsed, self.rng.uniform(0.15, 0.85),
                                self.rng.uniform(0.2, 0.8), change > 0,
                                min(1, 0.35 + abs(change) * 2)))
            self.last_pulse = elapsed
            self.baseline = self.load
        while self.pulses and elapsed - self.pulses[0][0] > 6:
            self.pulses.popleft()
        heat = math.sqrt(self.load)
        # Integrate speed so heat changes never jump the beam after long runs.
        self.scan = (self.scan + dt * (0.10 + heat * 0.18)) % 1
        result = []
        for x, y in self.cells:
            flow = (0.5 + 0.5 * math.sin(x * 9 - y * 4 - elapsed * 0.45)
                    * math.cos(x * 4 + y * 7 + elapsed * 0.21))
            cool = (0.008, 0.025 + flow * 0.045, 0.10 + flow * 0.25)
            hot = (0.22 + flow * 0.50, 0.005, 0.025 + flow * 0.04)
            color = mix(cool, hot, heat)
            scan = (x - self.scan + y * 0.18) % 1
            beam = math.exp(-((scan - 0.5) / 0.075) ** 2)
            wire = (0.5 + 0.5 * math.sin(x * 21 + y * 11 + elapsed * 1.3)) ** 8
            neon = mix((0.015, 0.65, 1.0), (1.0, 0.015, 0.32), heat)
            color = mix(color, neon, clamp(beam * (0.35 + heat * 0.45)
                                          + wire * (0.07 + heat * 0.20)))
            for born, cx, cy, warming, strength in self.pulses:
                age = elapsed - born
                distance = abs(x - cx) if self.rows == 1 else math.hypot(x - cx, (y - cy) * 0.55)
                front = math.exp(-((distance - age * 0.40) / 0.085) ** 2)
                trail = math.exp(-max(0, age * 0.40 - distance) * 7) if distance < age * 0.40 else 0
                fade_in = min(1, age / 0.15)
                amount = clamp((front + trail * 0.30) * math.exp(-age * 0.5) * strength * fade_in)
                tint = (1.0, 0.04, 0.22) if warming else (0.015, 0.85, 1.0)
                color = mix(color, tint, amount)
            result.append(color)
        return result


if __name__ == "__main__":
    cli = parser(__doc__)
    raise SystemExit(run(cli, lambda rows, columns, args: Ghost(rows, columns)))
