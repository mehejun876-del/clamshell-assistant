#!/bin/zsh
# 仅构建应用；不修改自启、电源或 Reminal 配置。
# 内置的是 ThirdParty/reminal-lid：Reminal 3.19.4 的合盖精简版（去掉全部远程功能）。
# 需要 Go 1.26（或用 REMINAL_LID_BIN 指向已从同一源码交叉编译的 darwin/arm64 二进制）。
set -e
cd "$(dirname "$0")"
APP="${APP_OUTPUT:-$PWD/build/合盖助手.app}"
SRC=ThirdParty/reminal-lid
mkdir -p build
if [[ -n "$REMINAL_LID_BIN" ]]; then cp "$REMINAL_LID_BIN" build/reminal
else (cd $SRC && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o ../../build/reminal ./cmd/reminal); fi
swiftc -O -target arm64-apple-macosx14.0 $SRC/native/reminal-capture/main.swift -o build/reminal-capture
swiftc -Osize -wmo main.swift State.swift -o build/ClamshellAssistant -Xlinker -dead_strip
strip -x build/ClamshellAssistant
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/reminal" "$APP/Contents/Resources/ThirdParty"
cp Info.plist "$APP/Contents/Info.plist"
mv -f build/ClamshellAssistant "$APP/Contents/MacOS/ClamshellAssistant"
mv -f build/reminal build/reminal-capture "$APP/Contents/Resources/reminal/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp ThirdParty/Reminal-LICENSE ThirdParty/NOTICE "$APP/Contents/Resources/ThirdParty/"
codesign --force --sign - "$APP/Contents/Resources/reminal/reminal" "$APP/Contents/Resources/reminal/reminal-capture"
codesign --force --sign - "$APP"
echo "已构建：$APP"
