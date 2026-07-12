#!/bin/bash
# usage-menubar installer — Claude + GPT(codex) usage % in the macOS menu bar.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/usage-bar"; U=$(id -u)
mkdir -p "$DIR"
cp "$SRC/fetch.py" "$DIR/fetch.py"
cp "$SRC/UsageBar.swift" "$DIR/UsageBar.swift"

echo "==> smoke test fetch.py"
python3 "$DIR/fetch.py" --gpt-force | python3 -m json.tool | head -30

echo "==> compile + bundle"
swiftc -O "$DIR/UsageBar.swift" -o "$DIR/usage-bar"
APP="$DIR/UsageBar.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$DIR/usage-bar" "$APP/Contents/MacOS/UsageBar"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>UsageBar</string>
  <key>CFBundleExecutable</key><string>UsageBar</string>
  <key>CFBundleIdentifier</key><string>com.bug.usagebar</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL

echo "==> install LaunchAgent (gui domain — required so the item actually renders)"
sed "s#__HOME__#$HOME#g" "$SRC/com.bug.usage-bar.plist" > "$HOME/Library/LaunchAgents/com.bug.usage-bar.plist"
launchctl bootout   gui/$U/com.bug.usage-bar 2>/dev/null || true
pkill -9 -f UsageBar 2>/dev/null || true; sleep 1
launchctl bootstrap gui/$U "$HOME/Library/LaunchAgents/com.bug.usage-bar.plist"
sleep 5

echo "==> verify"
launchctl print gui/$U/com.bug.usage-bar 2>/dev/null | grep -E "state =|pid =" || true
osascript -e 'tell application "System Events" to tell process "UsageBar" to return title of menu bar item 1 of menu bar 1' 2>/dev/null \
  && echo "OK — look at your menu bar (exit fullscreen if hidden)" \
  || echo "note: item title query failed; if in a fullscreen app the menu bar is auto-hidden (app is still running)"
