# LaunchAgent

This app ships a launchd plist for auto-starting the daemon at login.

## Install
1. Edit the plist to use your local paths:
   - `launchd/com.gehenna.daemon.plist`
2. Run the install script:

```
./scripts/launchd-install.sh
```

## Uninstall
```
./scripts/launchd-uninstall.sh
```

## Notes
- The plist uses the `scripts/gehenna-seize.sh` wrapper.
- If the wrapper relies on the sudoers rule, install it first (see `docs/permissions.md`).
