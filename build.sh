#!/bin/zsh
# 仅构建应用；不修改自启、电源或 Reminal 配置
# 会把 Reminal.app 一并打进应用包；可用 REMINAL_APP 指定 Reminal 路径
set -e
cd "$(dirname "$0")"
APP="${APP_OUTPUT:-$PWD/build/合盖助手.app}"
LABEL=local.reminal.clamshellassistant
REMINAL_APP="${REMINAL_APP:-$HOME/Applications/reminal.app}"
if [[ ! -d "$REMINAL_APP" ]]; then
  echo "找不到 Reminal：$REMINAL_APP" >&2
  echo "请先安装 Reminal，或设置环境变量 REMINAL_APP 指向 reminal.app" >&2
  exit 1
fi
swiftc -Osize -wmo main.swift State.swift -o ClamshellAssistant -Xlinker -dead_strip
strip -x ClamshellAssistant
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ThirdParty"
cp Info.plist "$APP/Contents/Info.plist"
mv -f ClamshellAssistant "$APP/Contents/MacOS/ClamshellAssistant"
ditto "$REMINAL_APP" "$APP/Contents/Resources/reminal.app"
cp ThirdParty/Reminal-LICENSE "$APP/Contents/Resources/ThirdParty/Reminal-LICENSE"
cp ThirdParty/NOTICE "$APP/Contents/Resources/ThirdParty/NOTICE"
codesign --force --sign - "$APP"
echo "已构建：$APP"
echo "未修改 LaunchAgent，也未切换系统或 Reminal 设置。"
