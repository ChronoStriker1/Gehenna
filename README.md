# Gehenna

Native macOS app and daemon for the Razer Tartarus Pro.

Version: `v0.7.5`

## Current Milestone Scope
- Native SwiftUI app with system tray support.
- HID daemon with optional seize mode, reload support, and status/control sockets.
- Keymap editor with 3 layers, per-app profiles, D-pad mode (`4-way` or `8-way`), and wheel bindings (`scroll`, `up`, `down`, `click`).
- Macro recorder and editor with delay steps, grouped macro library, and grouped/ungrouped views.
- Lighting tab with live style control, brightness, and effect speed (where supported by style).
- Layer hold behavior and keymap popup overlay support.

## App Tabs
- `Keymap`: profile/layer bindings, per-app links, D-pad mode, wheel bindings.
- `Macros`: record, edit, delete, group, ungroup, reorder steps.
- `Lighting`: spectrum, wave left/right, static, breathing, reactive, starlight, off.
- `Status`: start/stop/restart daemon, reload configs, clear/copy log, runtime status.

## Requirements
- macOS 13+
- Swift 6 toolchain (Xcode 16+)
- Razer Tartarus Pro (`0x1532:0x0244`)

## Build And Run (Repo)
```bash
swift build
swift run GehennaApp
```

CLI and daemon:
```bash
swift run GehennaCLI --help
swift run GehennaDaemon --enable-output
```

## Install As `.app`
If you build/package the app bundle, install:
- `/Applications/Gehenna.app`

For GUI start/stop/reload to work without password prompts, add sudoers rules:
```sudoers
Defaults:chronostriker1 !requiretty
chronostriker1 ALL=(root) NOPASSWD: /Applications/Gehenna.app/Contents/scripts/gehenna-seize.sh, /Applications/Gehenna.app/Contents/scripts/gehenna-stop.sh, /Applications/Gehenna.app/Contents/scripts/gehenna-reload.sh
```

## Configuration Files
User-writable runtime configs:
- `~/Library/Application Support/Gehenna/profiles.json`
- `~/Library/Application Support/Gehenna/macros.json`

Bundled/default fallbacks:
- `configs/tartarus-pro.windows-default.json`
- `configs/profiles.json`
- `configs/macros.json`

## Useful Commands
List devices:
```bash
swift run GehennaCLI list --vendor 0x1532 --product 0x0244
```

Lighting probe (when daemon is not seizing the device):
```bash
swift run GehennaCLI lighting-probe --product 0x0244 --index 1 --out /tmp/gehenna-lighting.txt
```

Lighting through daemon control:
```bash
swift run GehennaCLI lighting --product 0x0244 --index 0 --effect spectrum
swift run GehennaCLI lighting --product 0x0244 --index 0 --brightness 180
swift run GehennaCLI lighting --product 0x0244 --index 0 --static 00AAFF --readback
```

## LaunchAgent Helpers
```bash
./scripts/launchd-install.sh
./scripts/launchd-uninstall.sh
```

## Troubleshooting
- `Failed to open IOHIDManager (exclusive access)`:
  another process has seized the device. Stop the daemon before direct HID probing.
- `Failed to open HID device (IOReturn: -536870207)` in strict seize:
  run the daemon through the privileged seize script/sudoers path.

## Docs
- `docs/requirements.md`
- `docs/architecture.md`
- `docs/security.md`
- `docs/roadmap.md`
- `docs/data-model.md`
- `docs/permissions.md`
- `docs/poc.md`
- `docs/input-map.md`
- `docs/launchd.md`
- `docs/third-party-openrazer.md`
