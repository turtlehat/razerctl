#!/usr/bin/env python3
"""Golden trails rise to the top, bloom into spheres and drift slowly down."""

import math
import random

from _stream import parser, run


PALETTES = ((1.0, 0.08, 0.23), (0.12, 0.55, 1.0), (0.65, 0.14, 1.0),
            (1.0, 0.55, 0.06), (0.08, 1.0, 0.50), (1.0, 0.18, 0.65))


class Fireworks:
    def __init__(self, rows, columns, seed=419):
        self.rows, self.columns = rows, columns
        self.rng = random.Random(seed)
        self.time = 0.0
        self.next_launch = 0.0
        self.shells = []
        self.cells = [(column / max(1, columns - 1),
                       row / max(1, rows - 1))
                      for row in range(rows) for column in range(columns)]

    def _launch(self):
        self.shells.append({
            "born": self.time, "x": self.rng.uniform(0.22, 0.78),
            "rise": 1.8,
            "color": self.rng.choice(PALETTES),
            "phase": self.rng.uniform(0, math.tau),
            "stars": [self.rng.uniform(0.75, 1.0) for _ in range(16)],
        })

    def _advance(self, dt):
        self.time += min(0.25, max(0, dt))
        if self.time >= self.next_launch:
            self._launch()
            self.next_launch = self.time + 6.8
        self.shells = [shell for shell in self.shells
                       if self.time - shell["born"] < shell["rise"] + 4.5]

    def _lights(self):
        lights = []
        for shell in self.shells:
            age = self.time - shell["born"]
            burst = age - shell["rise"]
            if burst < 0:
                for tail in range(10):
                    progress = (age - tail * 0.09) / shell["rise"]
                    if progress < 0:
                        continue
                    x, y = shell["x"], 1 - progress
                    if self.rows == 1:
                        x, y = shell["x"] * progress, 0
                    lights.append((x, y, (1.0, 0.60, 0.15),
                                   math.exp(-tail * 0.28) * min(1, age * 8)))
                continue
            fade = (1 - burst / 4.5) ** 1.4 * min(1, burst * 10)
            for index, speed in enumerate(shell["stars"]):
                angle = shell["phase"] + index * math.tau / len(shell["stars"])
                for tail in range(3):
                    past = max(0, burst - tail * 0.07)
                    spread = 0.32 * (1 - math.exp(-past * 1.6)) * speed
                    x = shell["x"] + math.cos(angle) * spread
                    # A projected sphere expands at the top before gravity draws it down.
                    y = math.sin(angle) * spread * 2.2 + past * past * 0.065
                    if self.rows == 1:
                        x = shell["x"] + (-1 if index % 2 else 1) * spread
                        y = 0
                    tint = tuple(c + (1 - c) * math.exp(-burst * 8)
                                 for c in shell["color"])
                    lights.append((x, y, tint, fade * math.exp(-tail * 0.9)))
            lights.append((shell["x"], 0,
                           (1.0, 0.85, 0.60), burst * 12 * math.exp(-burst * 9)))
        return lights

    def render(self, elapsed, dt):
        self._advance(dt)
        lights = self._lights()
        width = max(0.012, 0.65 / self.columns)
        result = []
        for x, y in self.cells:
            color = [0.003, 0.002, 0.012]
            for px, py, tint, strength in lights:
                distance = ((x - px) / width) ** 2
                if self.rows > 1:
                    distance += ((y - py) / 0.13) ** 2
                if distance > 18:
                    continue
                light = math.exp(-distance * 0.5) * strength
                for channel in range(3):
                    color[channel] += tint[channel] * light
            result.append(tuple(1 - math.exp(-c) for c in color))
        return result


if __name__ == "__main__":
    raise SystemExit(run(parser(__doc__), lambda rows, columns, args:
                         Fireworks(rows, columns)))
