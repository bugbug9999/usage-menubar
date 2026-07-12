#!/bin/bash
launchctl bootout gui/$(id -u)/com.bug.usage-bar 2>/dev/null || true
rm -f  "$HOME/Library/LaunchAgents/com.bug.usage-bar.plist"
rm -rf "$HOME/usage-bar"
echo "usage-menubar removed."
