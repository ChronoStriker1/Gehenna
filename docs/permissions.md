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

### Passwordless Wrapper (Optional)
You can install a sudoers rule and use the wrapper script to avoid typing a password each run:

```
sudo sh -c 'printf "%s\n" "# Gehenna Tartarus helper" "# Allow running the seize wrapper without a password" "chronostriker1 ALL=(root) NOPASSWD: /Users/chronostriker1/git/Gehenna/scripts/gehenna-seize.sh" > /etc/sudoers.d/gehenna'
sudo chmod 0440 /etc/sudoers.d/gehenna
/Users/chronostriker1/git/Gehenna/scripts/gehenna-seize.sh
```

If you plan to use the launchd plist, install the sudoers rule first so the wrapper can self-sudo.

If you want the GUI stop button to work without a password, add the stop script:

```
sudo sh -c 'printf "%s\n" "chronostriker1 ALL=(root) NOPASSWD: /Users/chronostriker1/git/Gehenna/scripts/gehenna-stop.sh" >> /etc/sudoers.d/gehenna'
sudo chmod 0440 /etc/sudoers.d/gehenna
```

If the GUI still reports sudo is required, add this line to the same sudoers file to allow
non-TTY sudo from the app:

```
sudo sh -c 'printf "%s\n" "Defaults:chronostriker1 !requiretty" >> /etc/sudoers.d/gehenna'
sudo chmod 0440 /etc/sudoers.d/gehenna
```

For the Reload Configs button, allow the reload script too:

```
sudo sh -c 'printf "%s\n" "chronostriker1 ALL=(root) NOPASSWD: /Users/chronostriker1/git/Gehenna/scripts/gehenna-reload.sh" >> /etc/sudoers.d/gehenna'
sudo chmod 0440 /etc/sudoers.d/gehenna
```

## Potential Entitlements
- If app is sandboxed, evaluate USB/HID entitlements as needed.
- If not sandboxed, rely on user-granted permissions and code signing.

## UX Requirements
- Provide clear in-app guidance for enabling permissions.
- Detect permission status and show actionable steps.
