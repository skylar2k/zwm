#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 zwm contributors
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License, version 3, as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details. You should have received a copy of it along with this
# program (the file LICENSE); if not, see <https://www.gnu.org/licenses/>.

# Start zwm automatically at login (a launchd "LaunchAgent").
#
#   scripts/login-item.sh install [path/to/zwm.app]   (default: zig-out/zwm.app)
#   scripts/login-item.sh uninstall
#   scripts/login-item.sh status
#   scripts/login-item.sh print [path/to/zwm.app]     show the plist, change nothing
#
# Build the app first:  zig build bundle
# Then enable "zwm" in System Settings > Privacy & Security > Accessibility.
#
# The agent restarts zwm if it CRASHES, but not when you quit it from the menu
# or with the quit key (that exits cleanly). After a crash, windows that were
# left off-screen are pulled back automatically when zwm starts.
set -eu

LABEL="local.zwm"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN="gui/$(id -u)"

app_path() {
    app="${1:-$HERE/zig-out/zwm.app}"
    [ -x "$app/Contents/MacOS/zwm" ] || { echo "no zwm.app at $app (run: zig build bundle)" >&2; exit 1; }
    (cd "$app" && pwd)
}

make_plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$1/Contents/MacOS/zwm</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/zwm.log</string>
</dict>
</plist>
PLIST
}

case "${1:-}" in
    print)
        make_plist "$(app_path "${2:-}")"
        ;;
    install)
        app="$(app_path "${2:-}")"
        mkdir -p "$HOME/Library/LaunchAgents"
        make_plist "$app" > "$PLIST"
        plutil -lint "$PLIST" >/dev/null
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        launchctl bootstrap "$DOMAIN" "$PLIST"
        echo "installed: zwm starts at login (log: ~/Library/Logs/zwm.log)"
        ;;
    uninstall)
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        rm -f "$PLIST"
        echo "removed the zwm login item"
        ;;
    status)
        if [ -f "$PLIST" ]; then echo "plist: $PLIST"; else echo "not installed"; fi
        launchctl print "$DOMAIN/$LABEL" 2>/dev/null | head -12 || true
        ;;
    *)
        # The usage text is the comment block that starts at "Start zwm".
        sed -n '/^# Start zwm automatically/,/^# left off-screen/p' "$0"
        exit 1
        ;;
esac
