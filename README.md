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

## Features

- **Performance:** select performance modes, adjust CPU/GPU power levels in Custom mode, and control fans.
- **Monitoring:** read fan speeds, temperatures, battery status and charger wattage.
- **Charging:** set a charge limit or override it to charge to 100%.
- **Lighting:** adjust brightness, keyboard effects and the lid logo.
- **Animations:** play Polychromatic sequences and ChromaEffects profiles, including keyboard-triggered Reactive and Ripple layers.
- **Saved settings:** capture your configuration and restore it after a restart, sleep or power-source change.
- **Scripting:** JSON output, bare values for individual readings, and silent successful writes.

Available settings depend on your device. Command help shows only the settings
declared for the selected model.

## Supported hardware

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

## Build and install

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

The binary is written to `zig-out/bin/razerctl`.

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

## Everyday use

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
razerctl get                         # all readings and settings
razerctl get --brightness            # one bare value, such as 29
razerctl get --cpu-temp --gpu-temp    # selected readings with labels
razerctl get --json                  # JSON for scripts
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

## Saving and restoring settings

Hardware can reset settings after sleep, a restart or a power-source change.
Saving is explicit; ordinary `set` commands do not save anything.

```sh
razerctl set --mode balanced --charge-limit 80 --save  # apply and save
razerctl save                                       # save current settings
razerctl save --brightness                           # save just brightness
razerctl restore                                    # restore saved settings
razerctl restore --brightness                        # restore just brightness
```

`save` without selectors captures all readable, writable settings. Selected
saves update only those settings, preserving the rest. Readings such as
temperatures and battery percentage are not saved.

Settings are stored under `$XDG_STATE_HOME/razerctl`, or
`~/.local/state/razerctl` when it is unset. Run `restore` as the same user who
saved them. Restoration is not automatic; you can call it from your own login,
resume or power-management hooks.

## Playing animations

```sh
razerctl play animation.json
razerctl play profile.ChromaEffects
```

Play a Polychromatic or ChromaEffects file made for your device.

**Ctrl-C stops playback and restores the original lighting effect.**
Stop other lighting controllers first so they do not overwrite the animation.

Ambient Awareness and Audio Meter effects are not supported.

Reactive and Ripple need permission to read keyboard events. On many
distributions, add yourself to the `input` group with
`sudo usermod -aG input "$USER"`, then log out and back in.
**This grants access to all keyboard events, not just Razer's.**
Without access, other effects still play.

## License

MIT.
