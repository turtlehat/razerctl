#!/usr/bin/env python3
"""Emerald code rain with pale leading glyphs, flickering trails and signal glitches."""

import math
import random

from _stream import parser, run


class DigitalRain:
    def __init__(self, rows, columns, seed=941):
        self.rows, self.columns = rows, columns
        self.rng = random.Random(seed)
        self.time = 0.0
        self.drops = [self._drop(True) for _ in range(
            max(3, columns // 3) if rows > 1 else max(3, columns // 12))]
        self.glyphs = [self.rng.random() * math.tau for _ in range(rows * columns)]
        self.next_glitch = 3.0
        self.glitch = None

    def _drop(self, initial=False):
        length = self.rows if self.rows > 1 else self.columns
        tail = self.rng.uniform(0.45, 0.9) * length
        return {"column": self.rng.randrange(self.columns),
                "position": self.rng.uniform(-length, length) if initial else -1.5,
                "speed": self.rng.uniform(0.65, 1.25) * length,
                "tail": tail, "strength": self.rng.uniform(0.65, 1.0)}

    def _advance(self, dt):
        dt = min(0.25, max(0, dt))
        self.time += dt
        length = self.rows if self.rows > 1 else self.columns
        for index, drop in enumerate(self.drops):
            drop["position"] += drop["speed"] * dt
            if drop["position"] - drop["tail"] > length:
                self.drops[index] = self._drop()
        if self.time >= self.next_glitch:
            self.glitch = (self.time, self.rng.randrange(self.columns))
            self.next_glitch = self.time + self.rng.uniform(4, 8)
        if self.glitch and self.time - self.glitch[0] > 0.65:
            self.glitch = None

    def render(self, elapsed, dt):
        self._advance(dt)
        result = []
        for row in range(self.rows):
            for column in range(self.columns):
                phase = self.glyphs[row * self.columns + column]
                flicker = 0.55 + 0.45 * math.sin(self.time * 13 + phase) ** 2
                green, head = 0.012 * flicker, 0.0
                for drop in self.drops:
                    if self.rows > 1 and column != drop["column"]:
                        continue
                    distance = drop["position"] - (row if self.rows > 1 else column)
                    lead = math.exp(-(distance / 0.6) ** 2) * drop["strength"]
                    trail = (math.exp(-distance * 3 / drop["tail"])
                             * min(1, (drop["tail"] - distance) * 2)
                             if 0 <= distance < drop["tail"] else 0)
                    green += drop["strength"] * trail * flicker * 0.75 + lead * 0.85
                    head += lead
                glitch = 0
                if self.glitch:
                    born, center = self.glitch
                    envelope = math.sin(math.pi * (self.time - born) / 0.65) ** 2
                    band = math.exp(-((column - center) / max(1, self.columns * 0.06)) ** 2)
                    glitch = envelope * band * (0.25 + 0.25 * flicker)
                result.append((1 - math.exp(-head * 0.62),
                               1 - math.exp(-green - glitch),
                               1 - math.exp(-head * 0.40 - glitch * 0.65)))
        return result


if __name__ == "__main__":
    raise SystemExit(run(parser(__doc__), lambda rows, columns, args:
                         DigitalRain(rows, columns)))
