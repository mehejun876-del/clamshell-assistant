#!/bin/zsh
# 核查已构建的 合盖助手.app 并打成安装包 ZIP（含 .app，不是源码包），输出 SHA-256。
set -e
cd "$(dirname "$0")"
APP="${APP_OUTPUT:-$PWD/build/合盖助手.app}"
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
need=(Contents/Info.plist Contents/MacOS/ClamshellAssistant Contents/MacOS/clamshell-helper
      Contents/Resources/reminal/reminal Contents/Resources/reminal/reminal-capture Contents/Resources/AppIcon.icns
      Contents/Resources/LICENSE Contents/Resources/THIRD_PARTY_NOTICES.md
      Contents/Resources/ThirdParty/Reminal-LICENSE Contents/Resources/ThirdParty/NOTICE)
for f in $need; do [[ -e "$APP/$f" ]] || { echo "缺少：$f"; exit 1; }; done
for b in Contents/MacOS/ClamshellAssistant Contents/MacOS/clamshell-helper Contents/Resources/reminal/reminal Contents/Resources/reminal/reminal-capture; do
  archs=$(lipo -archs "$APP/$b"); [[ "$archs" == *arm64* ]] || { echo "$b 不是 arm64：$archs"; exit 1; }
done
"$APP/Contents/Resources/reminal/reminal" version
"$APP/Contents/MacOS/clamshell-helper" version
codesign --verify --strict --verbose=1 "$APP"
mkdir -p dist
ZIP="dist/ClamshellAssistant-$VER-macOS.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" | tee "$(basename "$ZIP").sha256")
echo "安装包：$PWD/$ZIP"
