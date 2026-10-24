#!/usr/bin/env python3
"""A living sky: sunrise, drifting clouds, sunset and a moonlit night."""

import datetime
import math
import random

from _stream import clamp, mix, parser, positive, run


SKY = (
    (0.00, (0.015, 0.025, 0.13), (0.045, 0.035, 0.16)),
    (0.17, (0.055, 0.025, 0.18), (0.19, 0.045, 0.20)),
    (0.25, (0.20, 0.07, 0.32), (0.95, 0.25, 0.065)),
    (0.34, (0.025, 0.24, 0.48), (0.28, 0.48, 0.48)),
    (0.53, (0.025, 0.23, 0.50), (0.18, 0.42, 0.52)),
    (0.66, (0.12, 0.14, 0.34), (0.85, 0.30, 0.07)),
    (0.75, (0.16, 0.035, 0.28), (0.75, 0.075, 0.14)),
    (0.84, (0.025, 0.025, 0.15), (0.08, 0.035, 0.20)),
    (1.00, (0.015, 0.025, 0.13), (0.045, 0.035, 0.16)),
)


def sky_at(phase, height):
    for (begin, top, bottom), (end, next_top, next_bottom) in zip(SKY, SKY[1:]):
        if phase <= end:
            weight = clamp((phase - begin) / (end - begin))
            weight = weight * weight * (3 - 2 * weight)
            return mix(mix(top, next_top, weight),
                       mix(bottom, next_bottom, weight), height)
    return mix(SKY[-1][1], SKY[-1][2], height)


class Solstice:
    def __init__(self, rows, columns, day_seconds=None, seed=73):
        self.rows, self.columns = rows, columns
        self.day_seconds = day_seconds
        rng = random.Random(seed)
        self.cells = [
            (column / max(1, columns - 1), row / max(1, rows - 1),
             rng.random(), rng.random() * math.tau)
            for row in range(rows) for column in range(columns)
        ]

    def render(self, elapsed, dt):
        if self.day_seconds is None:
            now = datetime.datetime.now()
            phase = (now.hour * 3600 + now.minute * 60 + now.second
                     + now.microsecond / 1e6) / 86400
        else:
            phase = (0.22 + elapsed / self.day_seconds) % 1
        sun_progress = (phase - 0.23) / 0.54
        moon_progress = ((phase + 0.5) % 1 - 0.23) / 0.54
        daylight = clamp(math.sin((phase - 0.23) * math.tau) * 2.5)
        night = 1 - daylight
        result = []
        for x, y, star, offset in self.cells:
            color = sky_at(phase, 0.65 if self.rows == 1 else y)
            cloud = (math.sin(x * 9 + y * 3 - elapsed * 0.027)
                     + 0.55 * math.sin(x * 17 - y * 5 - elapsed * 0.041))
            cloud = clamp((cloud - 0.25) * 0.65)
            veil = (0.16 + 0.12 * math.sin(y * 13 + elapsed * 0.009)) * cloud
            color = mix(color, (0.18, 0.22, 0.34), veil * (0.3 + daylight * 0.7))
            for progress, tint, strength in (
                (sun_progress, (1.0, 0.58, 0.13), 1.0),
                (moon_progress, (0.30, 0.50, 0.85), night * 0.65),
            ):
                if 0 <= progress <= 1:
                    cx = -0.08 + progress * 1.16
                    cy = 0.95 - 0.82 * math.sin(progress * math.pi)
                    distance = ((x - cx) / 0.14) ** 2
                    if self.rows > 1:
                        distance += ((y - cy) / 0.24) ** 2
                    glow = math.exp(-distance * 0.6) * 0.38
                    disk = math.exp(-distance * 4) * 0.8
                    visibility = math.sin(progress * math.pi) ** 0.4
                    amount = clamp((disk + glow) * strength * visibility * (1 - cloud * 0.65))
                    color = mix(color, tint, amount)
            if star > 0.80 and (self.rows == 1 or y < 0.7):
                shimmer = (0.5 + 0.5 * math.sin(elapsed * 0.65 + offset)) ** 5
                color = mix(color, (0.42, 0.58, 0.92), night * shimmer * 0.65)
            result.append(color)
        return result


if __name__ == "__main__":
    cli = parser(__doc__)
    cli.add_argument("--day-seconds", type=positive,
                     help="Use an accelerated day/night cycle instead of local time.")
    raise SystemExit(run(cli, lambda rows, columns, args:
                         Solstice(rows, columns, args.day_seconds)))
