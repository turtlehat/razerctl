# razerctl

razerctl is a command-line tool for controlling Razer laptops on Linux and
Windows. Manage performance, fans, charging and lighting directly, without
Synapse, a background service or a custom kernel module.

## ✨ Features

- 💡 **Lighting:** adjust brightness, colours and built-in effects.
- 🎬 **Playback:** play custom lighting animations from ChromaEffects and Polychromatic files.
- 🌈 **Stream:** feed live RGB frames from your own programs.
- 🌡️ **Monitor:** read current settings and sensor data, with JSON output for scripts.
- 🔧 **Configure:** adjust device settings from the command line.
- 💾 **Save:** capture all settings or just the ones you choose.
- ♻️ **Restore:** reapply saved settings whenever needed.

## 💻 Supported Hardware

| Model | USB product ID | Verified |
|---|---|---|
| Razer Blade 14 (2025) | `0x02c5` | — |
| Razer Blade 16 (2025) | `0x02c6` | — |
| Razer Blade 18 (2025) | `0x02c7` | — |
| Razer Blade 14 (2024) | `0x02b6` | ✅ |
| Razer Blade 16 (2024) | `0x02b7` | — |
| Razer Blade 18 (2024) | `0x02b8` | — |
| Razer Blade 14 (2023) | `0x029d` | — |
| Razer Blade 15 (2023) | `0x029e` | — |
| Razer Blade 16 (2023) | `0x029f` | — |
| Razer Blade 18 (2023) | `0x02a0` | — |
| Razer Blade 14 (2022) | `0x028c` | — |
| Razer Blade 15 (2022) | `0x027a` | — |
| Razer Blade 15 (2022) | `0x028a` | — |
| Razer Blade 17 (2022) | `0x028b` | — |
| Razer Blade 14 (2021) | `0x0270` | — |
| Razer Blade 15 (2021) | `0x026d` | — |
| Razer Blade 15 (2021) | `0x026f` | — |
| Razer Blade 15 (2021) | `0x0276` | — |
| Razer Blade 17 (2021) | `0x0279` | — |
| Razer Blade Pro 17 (2021) | `0x026e` | — |
| Razer Blade 15 (2020) | `0x0253` | — |
| Razer Blade 15 (2020) | `0x0255` | — |
| Razer Blade 15 (2020) | `0x0268` | — |
| Razer Blade Pro 17 (2020) | `0x0256` | — |
| Razer Blade Stealth 13 (2020) | `0x0252` | — |
| Razer Blade Stealth 13 (2020) | `0x0259` | — |
| Razer Book 13 (2020) | `0x026a` | — |
| Razer Blade 15 (2019) | `0x023a` | — |
| Razer Blade 15 (2019) | `0x0246` | — |
| Razer Blade 15 (2019) | `0x024b` | — |
| Razer Blade 15 Mercury White (2019) | `0x0245` | — |
| Razer Blade 15 Studio Edition (2019) | `0x024d` | — |
| Razer Blade Pro 17 (2019) | `0x0234` | — |
| Razer Blade Pro 17 (2019) | `0x024c` | — |
| Razer Blade Stealth 13 (2019) | `0x0239` | — |
| Razer Blade Stealth 13 (2019) | `0x024a` | — |
| Razer Blade 15 (2018) | `0x0233` | — |
| Razer Blade 15 (2018) | `0x023b` | — |
| Razer Blade 15 Mercury White (2018) | `0x0240` | — |
| Razer Blade 16 | `0x02e0` | — |
| Razer Blade 18 | `0x02e1` | — |

## 🔧 Building From Source

Clone the repository:

```sh
git clone https://github.com/turtlehat/razerctl.git
cd razerctl
```

### Linux

Install Zig and the hidapi development files:

Arch Linux:

```sh
sudo pacman -S zig hidapi
```

Debian / Ubuntu:

```sh
sudo apt install zig libhidapi-dev
```

**Zig 0.17 is required.** If your repositories do not provide it, install it
from the [official downloads](https://ziglang.org/download/) instead.

Build from the project directory:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/razerctl
```

#### Device Permissions

Install the device permissions rules to use razerctl without root:

```sh
sudo install -Dm644 udev/70-razerctl.rules /etc/udev/rules.d/70-razerctl.rules
sudo udevadm control --reload
sudo udevadm trigger
```

These also grant programs running as your user access to Razer input events
for Reactive and Ripple effects.

#### zsh Completion

Copy the completion file to a directory on your zsh `$fpath`:

```sh
sudo install -Dm644 completions/_razerctl /usr/local/share/zsh/site-functions/_razerctl
```

If needed, enable completion with `autoload -Uz compinit; compinit` in `.zshrc`.

### Windows

Install Zig 0.17 with WinGet:

```powershell
winget install --id zig.zig --exact --version 0.17.0
```

The current terminal won't pick up Zig's `PATH` change. Close and reopen your
terminal, then return to the `razerctl` directory and build:

```powershell
zig build -Doptimize=ReleaseSafe
.\zig-out\bin\razerctl.exe
```

Turn off "Use Dynamic lighting on my devices" in Settings → Personalization →
Dynamic Lighting to prevent Windows from overriding razerctl's lighting.

## 💾 Saving And Restoring Settings

Change and save brightness, then restore it later:

```sh
razerctl set --brightness 30 --save
razerctl restore --brightness
```

Save or restore all settings:

```sh
razerctl save
razerctl restore
```

Restoration isn't automatic. Run `restore` yourself or from a login or resume hook.

## 🌈 Playing Animations

The [`examples/`](examples/) collection includes ChromaEffects profiles,
Polychromatic animations and live Python effects.

### ChromaEffects And Polychromatic

| Animation | Description |
|---|---|
| [**After Hours**](examples/chroma/after-hours.ChromaEffects) | Bright cyan sweeps across dark blue keys with breathing magenta edges |
| [**Undertow**](examples/chroma/undertow.ChromaEffects) | Contrasting teal currents over deep blue and violet |
| [**Prismatic Drift**](examples/chroma/prismatic-drift.ChromaEffects) | Drifting rainbow ribbons with pale reactive keystrokes |
| [**Emberfall**](examples/chroma/emberfall.ChromaEffects) | Hot golden sparks over orange surges and breathing charcoal red |
| [**Ghost Signal**](examples/chroma/ghost-signal.ChromaEffects) | Cyan keystrokes and violet ripples over a rotating cyan/violet glow |
| [**Supernova**](examples/chroma/supernova.ChromaEffects) | Sweeping gold light and soft white sparks |

Play an animation:

```sh
razerctl play examples/chroma/undertow.ChromaEffects
```

Polychromatic versions are in [`examples/polychromatic/`](examples/polychromatic/).
Choose the size shown by `razerctl stream --info`.
Per-key variants for Blade 15 models `0x023b` and `0x0246` are in
[`examples/chroma/per-key/`](examples/chroma/per-key/).

Reactive and Ripple layers need [keyboard input access](#device-permissions) on
Linux.

### Stream Effects

Live animations powered by Python:

| Effect | Description |
|---|---|
| [**Solstice**](examples/stream/solstice.py) | Sunrise, drifting clouds, sunset and a starry moonlit night, following local time |
| [**Ghost in the Machine**](examples/stream/ghost-in-the-machine.py) | Calm neon blue at idle, crimson surges and electric pulses as CPU load rises and falls—even a single busy core wakes it up |
| [**Fireworks**](examples/stream/fireworks.py) | Golden trails rise to the top row, bloom into colourful spheres, then slowly fall and fade, one firework at a time |
| [**Digital Rain**](examples/stream/digital-rain.py) | Emerald code trails with pale leading glyphs and occasional signal glitches |

Run from the project directory with Python 3 (`python` on Windows), after
building razerctl:

```sh
python3 examples/stream/solstice.py
```

## 🐛 Reporting A Model

[Open an issue](https://github.com/turtlehat/razerctl/issues) with your model,
the output of `razerctl probe`, and what worked or didn't. Reports confirming
support are welcome too.

## 📄 License

MIT.
