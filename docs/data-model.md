# Data Model

## Storage Location
- `~/Library/Application Support/Gehenna/`

## Entities (Draft)
- **Profile**
  - id (UUID)
  - name
  - perAppBundleId (optional)
  - deviceMappings (array)
- **DeviceMapping**
  - physicalButtonId
  - action (KeyAction | MacroAction | Disabled)
- **Macro**
  - id (UUID)
  - name
  - steps (array)
- **MacroStep**
  - type (KeyDown | KeyUp | Delay)
  - keyCode (optional)
  - delayMs (optional)

## File Layout (Draft)
- `profiles.json`
- `macros.json`
- `settings.json`
- `device-mapping.json` (per-device HID input map)
