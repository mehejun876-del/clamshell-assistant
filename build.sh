#!/bin/zsh
# 仅构建应用；不修改自启、电源、Agent Hook 或 Reminal 配置。
# 内置的是 ThirdParty/reminal-lid：Reminal 3.19.4 的合盖精简版（去掉全部远程功能），V2 未改动其源码。
# 需要 Xcode 命令行工具；Reminal 精简服务需要 Go 1.26，或用 REMINAL_LID_BIN 指向从同一源码编译的 darwin/arm64 二进制
# （没有 Go 时会自动使用 prebuilt/ 里取自 1.4.1 官方发布包的同源二进制，并校验 SHA-256）。
set -e
cd "$(dirname "$0")"
APP="${APP_OUTPUT:-$PWD/build/合盖助手.app}"
SRC=ThirdParty/reminal-lid
APP_SOURCES=(main.swift State.swift Policy.swift Lease.swift Agents.swift)
HELPER_SOURCES=(Helper/main.swift State.swift Policy.swift Lease.swift)
mkdir -p build
if [[ -n "$REMINAL_LID_BIN" ]]; then cp "$REMINAL_LID_BIN" build/reminal
elif command -v go >/dev/null 2>&1; then
  (cd $SRC && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o ../../build/reminal ./cmd/reminal)
else
  echo "未找到 Go：使用 prebuilt/reminal-1.4.1-darwin-arm64（同一份未改动的 Reminal 精简版源码）"
  (cd prebuilt && shasum -a 256 -c SHA256SUMS)
  cp prebuilt/reminal-1.4.1-darwin-arm64 build/reminal
fi
chmod 755 build/reminal
swiftc -O -target arm64-apple-macosx14.0 $SRC/native/reminal-capture/main.swift -o build/reminal-capture
swiftc -Osize -wmo -target arm64-apple-macosx14.0 $APP_SOURCES -o build/ClamshellAssistant -Xlinker -dead_strip
swiftc -Osize -wmo -target arm64-apple-macosx14.0 $HELPER_SOURCES -o build/clamshell-helper -Xlinker -dead_strip
strip -x build/ClamshellAssistant build/clamshell-helper
if [[ ! -f AppIcon.icns ]]; then
  swiftc tools/make-app-icon.swift -o build/make-app-icon
  build/make-app-icon "$PWD/AppIcon.icns"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/reminal" "$APP/Contents/Resources/ThirdParty"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mv -f build/ClamshellAssistant "$APP/Contents/MacOS/ClamshellAssistant"
mv -f build/clamshell-helper "$APP/Contents/MacOS/clamshell-helper"
mv -f build/reminal build/reminal-capture "$APP/Contents/Resources/reminal/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp ThirdParty/Reminal-LICENSE ThirdParty/NOTICE "$APP/Contents/Resources/ThirdParty/"
codesign --force --sign - "$APP/Contents/Resources/reminal/reminal" "$APP/Contents/Resources/reminal/reminal-capture" "$APP/Contents/MacOS/clamshell-helper"
codesign --force --sign - "$APP"
echo "已构建：$APP"
