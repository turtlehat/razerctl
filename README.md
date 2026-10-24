# razerctl

Control your Razer laptop from the Linux command line without Synapse, a daemon,
or a custom kernel module. Adjust performance, fans, charging and lighting,
play lighting animations, and save settings to restore later.

```sh
razerctl get
razerctl set --mode turbo --fan auto
razerctl set --charge-limit 80
razerctl set --effect static orange
```

## ✨ Features

- 🚀 **Performance:** select performance modes, adjust CPU/GPU power levels in Custom mode, and control fans.
- 🌡️ **Monitoring:** read fan speeds, temperatures, battery status and charger wattage.
- 🔋 **Charging:** set a charge limit or override it to charge to 100%.
- 💡 **Lighting:** adjust brightness, keyboard effects and the lid logo.
- 🎬 **Animations:** play Polychromatic sequences and ChromaEffects profiles, including keyboard-triggered Reactive and Ripple layers.
- 💾 **Saved settings:** capture your configuration and restore it after a restart, sleep or power-source change.
- 🧩 **Scripting:** JSON output, bare values for individual readings, and silent successful writes.

Available settings depend on your device. Command help shows only the settings
declared for the selected model.

## 💻 Supported hardware

Tested on:

| Device | USB product ID |
|---|---|
| Razer Blade 14 (2024), RZ09-0508 | `0x02b6` |

This release includes 41 Razer laptop models. Accessories are not supported.
**Most models have not been tested on hardware** and are labelled unverified.
Support for a listed model is not a guarantee that every declared feature works.

```sh
razerctl list
razerctl probe
```

`list` shows attached devices and their IDs. `probe` surveys device capabilities;
its output is useful when reporting support for a model. Normal probing does
not change settings. `probe --effects` also tests lighting effects and restores
the original effect afterward.

## 🔧 Build and install

Linux requires [Zig](https://ziglang.org/) 0.17 and the hidapi development files:

```sh
# Arch Linux
sudo pacman -S hidapi

# Debian / Ubuntu
sudo apt install libhidapi-dev
```

From the project directory:

```sh
zig build -Doptimize=ReleaseSafe
```

The binary is written to `zig-out/bin/razerctl`. Install it on your `PATH`:

```sh
sudo install -Dm755 zig-out/bin/razerctl /usr/local/bin/razerctl
```

### Device permissions

Create `/etc/udev/rules.d/70-razerctl.rules` with:

```udev
KERNEL=="hidraw*", ATTRS{idVendor}=="1532", MODE="0660", TAG+="uaccess"
```

Then reload the rules and reconnect the device, or run:

```sh
sudo udevadm control --reload
sudo udevadm trigger
```

This allows the active local user to access Razer devices without running
razerctl as root.

### zsh completion

Copy the completion file to a directory on your zsh `$fpath`, for example:

```sh
sudo install -Dm644 completions/_razerctl /usr/local/share/zsh/site-functions/_razerctl
```

Enable completion with `autoload -Uz compinit; compinit` in `.zshrc` if needed.
Completion suggests commands, device IDs, settings and accepted values.

## ⌨️ Everyday use

Commands automatically select your Razer laptop. To select a model explicitly,
put its ID immediately after the command:

```sh
razerctl get
razerctl get 0x02b6
razerctl set 0x02b6 --brightness 30
```

Use `--help` to see the available settings and accepted values for that device:

```sh
razerctl help
razerctl get --help
razerctl set --help
razerctl set 0x02b6 --help
```

### Reading settings

```sh
razerctl get                        # all readings and settings
razerctl get --brightness           # one bare value, such as 29
razerctl get --cpu-temp --gpu-temp  # selected readings with labels
razerctl get --json                 # JSON for scripts
```

Multi-fan laptops expose `fan-speed-1`, `fan-speed-2`, and so on.
Single-fan devices use `fan-speed`. Unsupported battery measurements show
`unavailable`, not zero.

### Performance and charging

```sh
razerctl set --mode balanced
razerctl set --fan 3800
razerctl set --fan auto
razerctl set --mode custom --custom-cpu boost --custom-gpu high
razerctl set --charge-limit 80
razerctl set --charge-override on
razerctl set --charge-override off
```

Modes, power levels and fan ranges vary by model. Custom CPU/GPU levels and
`custom-max-fan` take effect only in Custom mode. Firmware may restrict
performance on battery or USB-C power, regardless of the selected mode.

**Charge override stays enabled until you turn it off**, even after the battery
reaches 100%. A charge limit of 100 disables the limit.

### Lighting

```sh
razerctl set --brightness 30
razerctl set --effect static orange
razerctl set --effect breathing red blue
razerctl set --effect starlight red blue long
razerctl set --logo static
```

Colours can be names, `'#rrggbb'`, or `r,g,b`. Quote hex colours in the shell.
Numeric colours accept an optional gamma value from 1 to 4, such as
`'#ff00ff,2.4'`; omit it to use the device default.

## 💾 Saving and restoring settings

Hardware can reset settings after sleep, a restart or a power-source change.
Saving is explicit; ordinary `set` commands do not save anything.

```sh
razerctl set --mode balanced --charge-limit 80 --save  # apply and save
razerctl save                                          # save current settings
razerctl save --brightness                             # save just brightness
razerctl restore                                       # restore saved settings
razerctl restore --brightness                          # restore just brightness
```

`save` without selectors captures all readable, writable settings. Selected
saves update only those settings, preserving the rest. Readings such as
temperatures and battery percentage are not saved.

Settings are stored under `$XDG_STATE_HOME/razerctl`, or
`~/.local/state/razerctl` when it is unset. Run `restore` as the same user who
saved them. Restoration is not automatic; you can call it from your own login,
resume or power-management hooks.

## 🌈 Playing animations

```sh
razerctl play animation.json
razerctl play profile.ChromaEffects
```

Play a Polychromatic or ChromaEffects file made for your device.

**Ctrl-C stops playback and restores the original lighting effect.**
Stop other lighting controllers first so they do not overwrite the animation.

Ambient Awareness and Audio Meter effects are not supported.

### Included examples

The [`examples/`](examples/) collection includes six original lighting designs
and four live Python animations.

#### ChromaEffects and Polychromatic

| Design | Mood |
|---|---|
| [**After Hours**](examples/chroma/after-hours.ChromaEffects) | Bright cyan sweeps across dark blue keys with breathing magenta edges |
| [**Undertow**](examples/chroma/undertow.ChromaEffects) | Contrasting teal currents over deep blue and violet |
| [**Prismatic Drift**](examples/chroma/prismatic-drift.ChromaEffects) | Drifting rainbow ribbons with pale reactive keystrokes |
| [**Emberfall**](examples/chroma/emberfall.ChromaEffects) | Hot golden sparks over orange surges and breathing charcoal red |
| [**Ghost Signal**](examples/chroma/ghost-signal.ChromaEffects) | Cyan keystrokes and violet ripples over a rotating cyan/violet glow |
| [**Supernova**](examples/chroma/supernova.ChromaEffects) | Sweeping gold light and soft white sparks |

Start with a ChromaEffects file; each includes all supported laptop models:

```sh
razerctl play examples/chroma/undertow.ChromaEffects
```

The 2018 Blade 15 (`0x023b`) and 2019 Blade 15 (`0x0246`) have both single-zone
and per-key variants. If yours reports six rows with `razerctl stream --info`,
use the same design from `examples/chroma/per-key/` instead.

Prerecorded interpretations of five designs are under
[`examples/polychromatic/`](examples/polychromatic/). Their animation differs
from the layered ChromaEffects versions. Choose the rows-by-columns size reported by
`razerctl stream --info`, for example:

```sh
razerctl play examples/polychromatic/undertow-6x16.json
```

Ghost Signal is ChromaEffects-only. Typing responses in Ghost Signal and
Prismatic Drift use model- and layout-specific key maps for all supported
laptops. Only the ANSI Blade 14 (2024) has been hardware-verified; reports
from other models are welcome. Polychromatic Prismatic Drift has no typing
response.

Reactive and Ripple need permission to read keyboard events. On many
distributions, add yourself to the `input` group with
`sudo usermod -aG input "$USER"`, then log out and back in.
**This grants access to all keyboard events, not just Razer's.**
Without access, other effects still play.

#### Stream Effects

Python programs create lighting that evolves as it runs:

| Effect | Description |
|---|---|
| [**Solstice**](examples/stream/solstice.py) | Sunrise, drifting clouds, sunset and a starry moonlit night, following local time |
| [**Ghost in the Machine**](examples/stream/ghost-in-the-machine.py) | Calm neon blue at idle, crimson surges and electric pulses as CPU load rises and falls—even a single busy core wakes it up |
| [**Fireworks**](examples/stream/fireworks.py) | Golden trails rise to the top row, bloom into colourful spheres, then slowly fall and fade, one firework at a time |
| [**Digital Rain**](examples/stream/digital-rain.py) | Emerald code trails with pale leading glyphs and occasional signal glitches |

```sh
python3 examples/stream/solstice.py
python3 examples/stream/ghost-in-the-machine.py
python3 examples/stream/fireworks.py
python3 examples/stream/digital-rain.py
```

All four adapt to single-row layouts. Ghost in the Machine shows CPU activity,
not temperature. Solstice accepts `--day-seconds 180` for an accelerated
three-minute day instead of local time.

The programs need only Python 3 and launch `./zig-out/bin/razerctl` to discover
your laptop's layout and play the animation. Use `--razerctl /path/to/razerctl`
to choose another executable, or pass a device ID such as
`python3 examples/stream/solstice.py 0x02b6`.
Run any program with `--help` to see its options.

To write your own, pipe raw RGB frames to `razerctl stream`: 3 bytes per key,
in row-by-column order, one frame after another. `razerctl stream --info`
shows the layout and frame size. The original effect is restored on exit.

## 🐛 Reporting a model

Tried razerctl on a laptop that isn't marked as tested? Please
[open an issue](https://github.com/turtlehat/razerctl/issues) with your model
name and the output of `razerctl probe`, plus anything that didn't work.
Reports that everything works are just as helpful.

## 📄 License

MIT.
