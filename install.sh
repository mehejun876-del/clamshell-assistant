#!/bin/zsh
# 合盖助手 2.1 一键安装 / 覆盖升级：检查工具 → 构建 → 全部模拟测试（失败即停止，不安装）→ 打包
# → 备份（旧版 App、pmset 状态、Agent Hook 配置、偏好）→ 正常退出旧版并确认睡眠设置
# → 原位替换并自动重新启动 → 输出 SHA-256 与回滚命令。
#
# 脚本本身不会：用 sudo 改 sudoers、改你的偏好（AI 智能模式开关保持原样）、写任何 Agent 配置、
# 改电源设置（唯一例外见第 7 步：旧版合盖助手自己留下的 SleepDisabled=1，用已存在的免密规则
# `sudo -n` 恢复，不弹密码；规则不存在就只提示）。AI 智能模式开着时，是 App 自己在启动后
# 为已安装的 Agent 追加 Hook（先备份、不覆盖），脚本不碰。
set -eu
setopt pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
APP_NAME="合盖助手.app"
BUNDLE_ID="local.reminal.clamshellassistant"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$ROOT/backups/$STAMP"
BUILT="$ROOT/build/$APP_NAME"
say() { print -r -- "[合盖助手安装] $*"; }
die() { print -r -- "[合盖助手安装] 已停止：$*"; exit 1; }
sleep_disabled() { pmset -g live 2>/dev/null | awk '$1=="SleepDisabled"{print $2}'; }

say "1/9 检查 Xcode 命令行工具"
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  die "未安装命令行工具。请先运行：xcode-select --install ，装好后重新执行本脚本。"
fi
say "    $(xcrun swiftc --version 2>&1 | head -1)"

say "2/9 检查 Go（Reminal 精简服务）"
if command -v go >/dev/null 2>&1; then say "    $(go version)，将从源码构建"
else say "    未安装 Go：复用 prebuilt/ 中取自 1.4.1 官方安装包、经 SHA-256 校验的同源 reminal（V2 未改动其源码）"; fi

say "3/9 构建"
zsh ./build.sh || die "构建失败，未安装。"

say "4/9 运行全部模拟测试（失败则不安装）"
zsh ./test.sh || die "测试未通过，未安装。旧版与系统设置均未改动。"

say "5/9 打包并核查安装包"
zsh ./package.sh || die "安装包核查失败，未安装。"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist")"
ZIP="$ROOT/dist/ClamshellAssistant-$VER-macOS.zip"

say "6/9 备份到 $BACKUP"
mkdir -p "$BACKUP/agent-config"
pmset -g > "$BACKUP/pmset-g.txt" 2>&1 || true
pmset -g live > "$BACKUP/pmset-g-live.txt" 2>&1 || true
pmset -g assertions > "$BACKUP/pmset-g-assertions.txt" 2>&1 || true
defaults export "$BUNDLE_ID" "$BACKUP/preferences.plist" >/dev/null 2>&1 || print "（无偏好设置）" > "$BACKUP/preferences.none"
for f in .codex/hooks.json .codex/config.toml .gemini/settings.json .gemini/config/hooks.json .grok/hooks .reminal/settings.json; do
  if [[ -e "$HOME/$f" ]]; then mkdir -p "$BACKUP/agent-config/$(dirname "$f")"; cp -Rp "$HOME/$f" "$BACKUP/agent-config/$f"; fi
done
[[ -e "/private/etc/sudoers.d/reminal-clamshell-$(id -u)" ]] && print "存在（未读取、未修改）" > "$BACKUP/sudoers-rule.txt" || print "不存在" > "$BACKUP/sudoers-rule.txt"
OLD=""
FOUND=("/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME" ${(f)"$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | grep -v "^$ROOT/" || true)"})
for c in $FOUND; do
  if [[ -d "$c" && -z "$OLD" ]]; then OLD="$c"; fi
done
if [[ -n "$OLD" ]]; then
  OLDVER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OLD/Contents/Info.plist" 2>/dev/null || print unknown)"
  ditto "$OLD" "$BACKUP/合盖助手-$OLDVER.app"
  print -r -- "$OLD" > "$BACKUP/previous-app-path"
  say "    已备份旧版 $OLDVER：$OLD"
else
  say "    未找到已安装的合盖助手：跳过 App 备份（仍已备份 pmset 与 Agent 配置）"
fi
print -r -- "SleepDisabled before install: $(sleep_disabled || true)" > "$BACKUP/manifest.txt"

say "7/9 正常退出旧版并确认睡眠设置"
if pgrep -f "/$APP_NAME/Contents/MacOS/ClamshellAssistant" >/dev/null 2>&1; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..40}; do pgrep -f "/$APP_NAME/Contents/MacOS/ClamshellAssistant" >/dev/null 2>&1 || break; sleep 0.25; done
  pgrep -f "/$APP_NAME/Contents/MacOS/ClamshellAssistant" >/dev/null 2>&1 && die "旧版未能正常退出，请手动退出后重试（未安装）。"
  say "    旧版已退出"
fi
if [[ "$(sleep_disabled || true)" == "1" ]]; then
  if [[ -n "$OLD" ]]; then
    # 1.4.1 退出时会保留它设置的「系统禁止睡眠」。用它已有的免密规则恢复；没有规则就只提示，不弹密码、不改 sudoers。
    if sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null; then say "    已恢复系统睡眠（SleepDisabled=0）"
    else say "    注意：SleepDisabled 仍为 1，且没有免密规则可用；安装后在菜单里「关闭合盖运行」即可恢复。"; fi
  else
    say "    注意：SleepDisabled=1 不是由合盖助手设置的（未找到旧版），未改动。"
  fi
fi
print -r -- "SleepDisabled after quitting old version: $(sleep_disabled || true)" >> "$BACKUP/manifest.txt"

say "8/9 安装"
# 始终装进「应用程序」文件夹（2.1.1 曾因为旧版在临时目录里而被原位装到那里）
if [[ -w /Applications ]]; then DEST="/Applications/$APP_NAME"
else mkdir -p "$HOME/Applications"; DEST="$HOME/Applications/$APP_NAME"; fi
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
print -r -- "$DEST" > "$BACKUP/installed-path"
print -r -- "$BACKUP" > "$ROOT/backups/LATEST"
NEWSHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
print -r -- "installed $VER at $DEST; zip sha256 $NEWSHA" >> "$BACKUP/manifest.txt"

say "8b/9 Codex（ChatGPT）系统级 Hook：Codex 按策略直接信任，不用在「设置 › Hooks」里逐条确认"
if [[ -d "$HOME/.codex" ]]; then
  SYS_TMP="$(mktemp -t clamshell-codex-hooks)"
  rc=0
  "$DEST/Contents/MacOS/ClamshellAssistant" --codex-system-hooks "$DEST/Contents/MacOS/clamshell-helper" > "$SYS_TMP" 2>/dev/null || rc=$?
  case $rc in
    3) say "    已是最新，无需改动" ;;
    4) say "    /etc/codex/hooks.json 不是标准 JSON，未改动；Codex 继续用用户级 Hook（需在「设置 › Hooks」信任一次）" ;;
    0)
      chmod 644 "$SYS_TMP"
      CMD="mkdir -p /etc/codex && chmod 755 /etc/codex && if [ -f /etc/codex/hooks.json ]; then cp -p /etc/codex/hooks.json /etc/codex/hooks.json.clamshell-backup-$STAMP; fi && /usr/bin/install -m 0644 -o root -g wheel '$SYS_TMP' /etc/codex/hooks.json"
      if osascript -e "do shell script \"$CMD\" with administrator privileges with prompt \"合盖助手要为 Codex 安装系统级 Hook，以后不用在 Codex 里逐条信任。\"" >/dev/null 2>&1; then
        say "    已写入 /etc/codex/hooks.json（root 所有，权限 644）"
        print -r -- "codex system hooks installed: /etc/codex/hooks.json" >> "$BACKUP/manifest.txt"
      else
        say "    未授权或写入失败：Codex 继续用用户级 Hook（需在「设置 › Hooks」信任一次）"
      fi ;;
    *) say "    无法生成 Codex 系统级 Hook（退出码 $rc），已跳过" ;;
  esac
  rm -f "$SYS_TMP"
else
  say "    未安装 Codex，跳过"
fi

say "9/9 启动"
open "$DEST"
sleep 3
if pgrep -f "$DEST/Contents/MacOS/ClamshellAssistant" >/dev/null 2>&1; then say "    已启动（菜单栏图标）。你的设置已保留；AI 智能模式开着时会自动连接已安装的 Agent。"
else say "    未检测到进程：首次运行未公证的应用时，请在 Finder 中按住 Control 点按「$APP_NAME」选择「打开」。"; fi
# 只保留一份：别处的旧副本（当前这份已在备份里）删除，免得 Spotlight / 登录项指向旧版
for c in $FOUND; do
  if [[ -d "$c" && "$c" != "$DEST" && "$c" != "$ROOT"/* ]]; then rm -rf "$c" && say "    已删除旧位置的副本：$c"; fi
done

print ""
say "完成：合盖助手 $VER"
say "  安装位置：$DEST"
say "  安装包：  $ZIP"
say "  SHA-256： $NEWSHA"
say "  备份：    $BACKUP"
say "  回滚：    zsh \"$ROOT/rollback.sh\""
say "  资源占用实测：zsh \"$ROOT/measure.sh\""
