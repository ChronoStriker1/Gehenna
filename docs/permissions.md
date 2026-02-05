# Permissions

## User-Granted Permissions
- Accessibility
- Input Monitoring

## Output Injection
When output injection is enabled (`GehennaDaemon --enable-output`), Accessibility permission is required.

## Event Tap
To suppress the original hardware keystrokes while remapping, the daemon installs a key event tap. This also requires Accessibility permission.

## HID Seize
When running with `--seize`, macOS may block opening the device without elevated privileges. If you see
`IOReturn: -536870207`, try:

```
sudo swift run GehennaDaemon --enable-output --seize
```

`--seize` is strict by default. Use `--seize-fallback` to continue without seizing if strict open fails.

## Potential Entitlements
- If app is sandboxed, evaluate USB/HID entitlements as needed.
- If not sandboxed, rely on user-granted permissions and code signing.

## UX Requirements
- Provide clear in-app guidance for enabling permissions.
- Detect permission status and show actionable steps.
