# Architecture

## High-Level Components
- **Gehenna.app** (SwiftUI UI)
  - UI for device status, profiles, and macro editing.
  - Communicates with background daemon via XPC.
- **GehennaDaemon** (LaunchAgent)
  - Runs continuously, manages device connection and macro execution.
  - Minimal privileges and surface area.
- **XPC Service**
  - Strictly defined interfaces for UI <-> daemon communication.
- **HID Layer**
  - IOKit/HID access to the Tartarus Pro device.
- **Macro Engine**
  - Deterministic interpreter for macro sequences and delays.

## Data Flow
1. UI sends configuration updates to daemon over XPC.
2. Daemon applies configuration to the active device mapping.
3. HID layer receives device input events.
4. Macro engine translates inputs into remapped outputs.
5. Output events are emitted through macOS input APIs.

## Error Handling
- Device disconnects trigger graceful fallback and user notification.
- XPC failures fall back to read-only UI until daemon recovers.
- All errors logged to a local log file with rotation.
