# LaunchAgent

This app ships a launchd plist for auto-starting the daemon at login.

## Install
1. Edit the plist to use your local paths:
   - `launchd/com.gehenna.daemon.plist`
2. Copy it to your LaunchAgents directory:

```
mkdir -p ~/Library/LaunchAgents
cp /Users/chronostriker1/git/Gehenna/launchd/com.gehenna.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.gehenna.daemon.plist
```

## Uninstall
```
launchctl unload ~/Library/LaunchAgents/com.gehenna.daemon.plist
rm ~/Library/LaunchAgents/com.gehenna.daemon.plist
```

## Notes
- The plist uses the `scripts/gehenna-seize.sh` wrapper.
- If the wrapper relies on the sudoers rule, install it first (see `docs/permissions.md`).
