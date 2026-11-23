#!/bin/zsh
# 合盖助手 V2（2.x）回滚 / 卸载：
#   1) 正常退出 V2（V2 退出时会释放它自己持有的「系统禁止睡眠」），并确认睡眠设置；
#   2) 从各 Agent 配置里只移除 V2 加入的 Hook 条目（AI 智能模式自动添加的），先备份，其余内容不动；
#   3) 删除 V2；若安装前有旧版，则把备份的旧版放回原位置并启动；否则到此结束。
# 用法：zsh rollback.sh [备份目录]（默认用最近一次安装的备份）
set -eu
setopt pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="合盖助手.app"
BUNDLE_ID="local.reminal.clamshellassistant"
say() { print -r -- "[合盖助手回滚] $*"; }
sleep_disabled() { pmset -g live 2>/dev/null | awk '$1=="SleepDisabled"{print $2}'; }
BACKUP="${1:-$(cat "$ROOT/backups/LATEST" 2>/dev/null || true)}"
[[ -n "$BACKUP" && -d "$BACKUP" ]] || { say "找不到备份目录（$ROOT/backups/LATEST）。"; exit 1; }
DEST="$(cat "$BACKUP/installed-path" 2>/dev/null || print "/Applications/$APP_NAME")"
PREV="$(cat "$BACKUP/previous-app-path" 2>/dev/null || true)"
say "使用备份：$BACKUP"

say "1/3 退出 V2 并确认睡眠设置"
if pgrep -f "/$APP_NAME/Contents/MacOS/ClamshellAssistant" >/dev/null 2>&1; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..40}; do pgrep -f "/$APP_NAME/Contents/MacOS/ClamshellAssistant" >/dev/null 2>&1 || break; sleep 0.25; done
fi
pkill -f "$DEST/Contents/MacOS/clamshell-helper guard" 2>/dev/null || true
LEASE="$HOME/Library/Application Support/ClamshellAssistant/keepawake-lease.json"
if [[ "$(sleep_disabled || true)" == "1" ]]; then
  if [[ -e "$LEASE" ]]; then
    # 只有 V2 的租约证明这是它设置的，才用已有免密规则恢复；不弹密码、不改 sudoers。
    if sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null; then rm -f "$LEASE"; say "    已恢复系统睡眠"
    else say "    注意：SleepDisabled 仍为 1 且没有免密规则；请运行 sudo pmset -a disablesleep 0"; fi
  else
    say "    SleepDisabled=1 不属于合盖助手 V2（无租约），未改动。"
  fi
else
  say "    系统睡眠正常（SleepDisabled 不为 1）"
fi

say "2/3 移除 V2 添加的 Agent Hook（只删含 clamshell-helper 的条目，先备份）"
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
import json, os, shutil, time
home = os.path.expanduser("~")
def ours(h): return isinstance(h, dict) and "clamshell-helper" in str(h.get("command", ""))
def strip(root):
    hooks = root.get("hooks")
    if isinstance(hooks, dict):
        for ev in list(hooks):
            groups = hooks[ev]
            if not isinstance(groups, list): continue
            kept = []
            for g in groups:
                if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                    others = [h for h in g["hooks"] if not ours(h)]
                    if len(others) == len(g["hooks"]): kept.append(g)
                    elif others: g["hooks"] = others; kept.append(g)
                else: kept.append(g)
            if kept: hooks[ev] = kept
            else: del hooks[ev]
        if not hooks: del root["hooks"]
    if "clamshell-assistant" in root and "clamshell-helper" in json.dumps(root["clamshell-assistant"]): del root["clamshell-assistant"]
    return root
for rel in [".codex/hooks.json", ".gemini/settings.json", ".gemini/config/hooks.json"]:
    p = os.path.join(home, rel)
    if not os.path.isfile(p): continue
    try: data = json.load(open(p))
    except Exception: print("    跳过（不是标准 JSON）：" + p); continue
    if "clamshell-helper" not in json.dumps(data): continue
    shutil.copy2(p, p + ".clamshell-backup-rollback-" + str(int(time.time())))
    mode = os.stat(p).st_mode & 0o777
    tmp = p + ".clamshell-tmp"
    with open(tmp, "w") as f: json.dump(strip(data), f, indent=2, ensure_ascii=False)
    os.chmod(tmp, mode); os.replace(tmp, p)
    print("    已移除：" + p)
for own in [".grok/hooks/clamshell-assistant.json", ".kiro/hooks/clamshell-assistant.json"]:
    g = os.path.join(home, own)
    if os.path.isfile(g): os.remove(g); print("    已移除：" + g)
PY
else
  say "    未找到 python3：请手动从 ~/.codex/hooks.json、~/.gemini/settings.json、~/.gemini/config/hooks.json 中删除含 clamshell-helper 的条目（已备份在 $BACKUP/agent-config）。"
fi

if [[ -f /etc/codex/hooks.json ]] && grep -q clamshell-helper /etc/codex/hooks.json 2>/dev/null; then
  say "    Codex 系统级 Hook：只移除合盖助手的条目（需要一次管理员密码）"
  SYS_TMP="$(mktemp -t clamshell-codex-hooks)"
  rc=0
  if [[ -x "$DEST/Contents/MacOS/ClamshellAssistant" ]]; then
    "$DEST/Contents/MacOS/ClamshellAssistant" --codex-system-hooks-remove - > "$SYS_TMP" 2>/dev/null || rc=$?
  else rc=9; fi
  STAMP="$(date +%Y%m%d-%H%M%S)"
  case $rc in
    5) CMD="cp -p /etc/codex/hooks.json /etc/codex/hooks.json.clamshell-backup-$STAMP && rm -f /etc/codex/hooks.json" ;;
    0) chmod 644 "$SYS_TMP"; CMD="cp -p /etc/codex/hooks.json /etc/codex/hooks.json.clamshell-backup-$STAMP && /usr/bin/install -m 0644 -o root -g wheel '$SYS_TMP' /etc/codex/hooks.json" ;;
    *) CMD="" ;;
  esac
  if [[ -n "$CMD" ]] && osascript -e "do shell script \"$CMD\" with administrator privileges with prompt \"移除合盖助手为 Codex 安装的系统级 Hook。\"" >/dev/null 2>&1; then
    say "    已移除（原文件备份为 /etc/codex/hooks.json.clamshell-backup-$STAMP）"
  else
    say "    未移除：请手动删除 /etc/codex/hooks.json 中含 clamshell-helper 的条目（需要管理员权限）"
  fi
  rm -f "$SYS_TMP"
fi

say "3/3 删除 V2 / 恢复旧版"
if [[ -d "$DEST" ]]; then
  V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || print "")"
  if [[ "$V" == 2.* ]]; then rm -rf "$DEST"; say "    已删除 V2：$DEST"; else say "    $DEST 不是 V2（$V），未删除"; fi
fi
OLDAPP=("$BACKUP"/合盖助手-*.app(N))
if [[ -n "$PREV" && ${#OLDAPP} -gt 0 ]]; then
  ditto "${OLDAPP[1]}" "$PREV"
  open "$PREV"
  say "    已恢复旧版到：$PREV 并启动"
else
  say "    安装前没有旧版：回滚到此完成（合盖助手已移除）"
fi
say "睡眠状态：SleepDisabled=$(sleep_disabled || print 无)；安装前记录见 $BACKUP/pmset-g.txt"
say "偏好设置未删除（与 1.4.1 兼容）。如需一并还原：defaults import $BUNDLE_ID \"$BACKUP/preferences.plist\"（若该文件存在）"
