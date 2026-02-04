# Security

## Principles
- Least privilege: the daemon does only what the UI cannot.
- Minimal attack surface: narrow XPC interfaces.
- No network access required for V1.

## macOS Permissions (TCC)
- **Accessibility**: required for synthetic key events.
- **Input Monitoring**: required to observe keyboard events when mapping.

## Code Signing
- All targets signed with the same team ID.
- XPC connection validation uses code signing checks.

## Data Protection
- Config stored in Application Support and validated on load.
- Sensitive data (if any later) stored in Keychain.
- Defensive parsing for all profile and macro data.

## Logging
- Local logs only; no telemetry.
- Log rotation and redaction for any sensitive fields.
