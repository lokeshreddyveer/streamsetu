#!/bin/bash
# Checks every 6 hours (while you are logged in and the Mac is awake) whether the iPhone install needs renewing, and renews it.
#   Scripts/install-auto-renew.sh            turn it on
#   Scripts/install-auto-renew.sh --remove   turn it off
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL="app.streamsetu.renew"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
if [ "${1:-}" = "--remove" ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"; echo "automatic renewal is off"; exit 0
fi
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/Library/Application Support/StreamSetuRenew"
# The scheduled job may not read ~/Documents, so it runs a copy of the script from Application Support.
RUNNER="$HOME/Library/Application Support/StreamSetuRenew/renew.sh"
cp Scripts/renew-install.sh "$RUNNER"; chmod +x "$RUNNER"
# Make sure a snapshot exists (this needs a terminal, which can read the project).
"$RUNNER" || true
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$RUNNER</string></array>
  <key>StartInterval</key><integer>21600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/StreamSetuRenew.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/StreamSetuRenew.log</string>
</dict></plist>
PL
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "automatic renewal is on (log: ~/Library/Logs/StreamSetuRenew.log)"
echo "The first signing may ask once for access to your signing key in Keychain: choose Always Allow."
