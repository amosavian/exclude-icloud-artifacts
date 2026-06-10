#!/bin/bash
# Build exclude-icloud-artifacts and install it as a login LaunchAgent.
#
# Usage:
#   ./install.sh               build, install binary + config, (re)load agent
#   ./install.sh --uninstall   unload agent, remove binary and plist
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
BINARY="$BIN_DIR/exclude-icloud-artifacts"
LABEL="com.mousavian.exclude-icloud-artifacts"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/exclude-icloud-artifacts"
LOG="/tmp/exclude-icloud-artifacts.log"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$BINARY"
    echo "Uninstalled (config kept at $CONFIG_DIR)."
    echo "Already-excluded folders keep their xattr; remove with:"
    echo "  xattr -d 'com.apple.fileprovider.ignore#P' <folder>"
    exit 0
fi

echo "==> Building (release)"
swift build -c release --package-path "$PROJECT_DIR"

echo "==> Stopping agent (if running)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

echo "==> Installing binary to $BINARY"
mkdir -p "$BIN_DIR"
install -m 755 "$PROJECT_DIR/.build/release/exclude-icloud-artifacts" "$BINARY"

if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
    echo "==> Installing default config to $CONFIG_DIR/config.yaml"
    mkdir -p "$CONFIG_DIR"
    cp "$PROJECT_DIR/config.example.yaml" "$CONFIG_DIR/config.yaml"
fi

echo "==> Writing LaunchAgent $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>300</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

echo "==> Loading agent"
launchctl bootstrap "$DOMAIN" "$PLIST"

sleep 1
if launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; then
    echo "==> $LABEL is running. Log: $LOG"
else
    echo "==> Agent loaded; check with: launchctl print $DOMAIN/$LABEL"
fi
