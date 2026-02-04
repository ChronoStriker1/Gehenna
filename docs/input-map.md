# Input Map

## Findings (Razer Tartarus Pro)
- **Interface 2**: main keypad keys (keyboard report, reportId=1, len=24).
- **Interface 0**: d-pad arrows (keyboard report, reportId=0, len=8).
- **Interface 1**: scroll wheel (value events on GenericDesktop Wheel).

The device emits keypad keys as **Ctrl + key** chords. We treat the chord as the physical button identity.

## Default Layout
We mirror the Windows-style Razer layout using a 4x5 grid of key labels. This is a best-effort mapping based on observed HID codes and standard left-hand layout:

Row 1: 1 2 3 4 5
Row 2: Tab Q W E R
Row 3: CapsLock A S D F
Row 4: L-Shift Z X C Space

If any key is physically different, we will adjust after a short calibration pass.

## Mapping File
See `configs/tartarus-pro.windows-default.json` for the initial mapping. This file will be used by the daemon to translate raw HID input into internal button IDs.

## Layer Button
The layer switch emits **Left Alt** on interface 0 with no key usage. We map it as `layer.toggle`. The daemon treats:\n- Tap: cycle layer 1 → 2 → 3 → 1\n- Hold + press another key: act as a modifier for that key (no layer cycle)
