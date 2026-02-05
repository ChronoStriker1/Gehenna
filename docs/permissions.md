# Permissions

## User-Granted Permissions
- Accessibility
- Input Monitoring

## Output Injection
When output injection is enabled (`GehennaDaemon --enable-output`), Accessibility permission is required.

## Event Tap
To suppress the original hardware keystrokes while remapping, the daemon installs a key event tap. This also requires Accessibility permission.

## Potential Entitlements
- If app is sandboxed, evaluate USB/HID entitlements as needed.
- If not sandboxed, rely on user-granted permissions and code signing.

## UX Requirements
- Provide clear in-app guidance for enabling permissions.
- Detect permission status and show actionable steps.
