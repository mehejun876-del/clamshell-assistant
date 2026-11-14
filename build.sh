#!/bin/zsh
# 构建并安装「合盖助手」到 ~/Applications，并注册开机自启
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/合盖助手.app"
LABEL=local.reminal.clamshellassistant
swiftc -Osize -wmo main.swift -o ClamshellAssistant -Xlinker -dead_strip
strip -x ClamshellAssistant
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mv -f ClamshellAssistant "$APP/Contents/MacOS/ClamshellAssistant"
codesign --force --sign - "$APP"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$LABEL</string><key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ClamshellAssistant</string></array><key>RunAtLoad</key><true/></dict></plist>
PL
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "已安装：$APP"
