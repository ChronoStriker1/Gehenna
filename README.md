# Gehenna

Native macOS app for configuring the Razer Tartarus Pro with robust macro support and Windows-like capabilities.

## Goals
- Native macOS app with a full GUI and a background daemon.
- Key remap, macro recording, macro editor, and delays in V1.
- Secure by default with least-privilege design.
- Strict formatting and linting (SwiftFormat + SwiftLint).

## Proposed Stack
- Swift + SwiftUI for UI.
- AppKit where needed for deeper macOS integration.
- Background daemon via LaunchAgent.
- XPC service for privileged or long-running tasks.
- IOKit/HID for device communication.

## Data Location
User configuration and macros stored in:
`~/Library/Application Support/Gehenna/`

## Docs
- `docs/requirements.md`
- `docs/architecture.md`
- `docs/security.md`
- `docs/roadmap.md`
- `docs/data-model.md`
- `docs/permissions.md`

## Status
Planning and scaffolding.
