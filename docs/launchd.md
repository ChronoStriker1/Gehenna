# LaunchAgent

This app ships a launchd plist for auto-starting the daemon at login.

## Install
Run the install script:

```
./scripts/launchd-install.sh
```

The installer writes `~/Library/LaunchAgents/com.gehenna.daemon.plist` using the
current Gehenna path and log path automatically.

## Uninstall
```
./scripts/launchd-uninstall.sh
```

## Notes
- The plist uses the `scripts/gehenna-seize.sh` wrapper.
- If the wrapper relies on the sudoers rule, install it first (see `docs/permissions.md`).
