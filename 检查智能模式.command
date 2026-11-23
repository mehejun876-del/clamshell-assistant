#!/bin/zsh
# 合盖助手：查看 AI 智能模式此刻在做什么（只读，不改任何设置）。双击即可运行。
SUP="$HOME/Library/Application Support/ClamshellAssistant"
print "== 合盖助手 AI 智能模式检查 =="
print
print "[1] 系统睡眠（SleepDisabled 1 = 正在阻止睡眠）"
v=$(pmset -g live 2>/dev/null | awk '$1=="SleepDisabled"{print $2}')
if [[ "$v" == "1" ]]; then print "  正在阻止睡眠（SleepDisabled 1）"; else print "  允许睡眠"; fi
print
print "[2] 已自动连接的 Agent（AI 智能模式开启时由合盖助手自己添加）"
has() { [[ -f "$1" ]] && grep -q "clamshell-helper" "$1" 2>/dev/null; }
if has /etc/codex/hooks.json; then print "  Codex（ChatGPT）：已连接（系统级，无需在 Codex 里信任）"
elif has "$HOME/.codex/hooks.json"; then print "  Codex（ChatGPT）：已连接（用户级，首次需在「设置 › Hooks」中信任一次）"
else print "  Codex（ChatGPT）：未连接"; fi
has "$HOME/.gemini/settings.json"      && print "  Gemini：已连接" || print "  Gemini：未连接"
has "$HOME/.gemini/config/hooks.json"  && print "  Antigravity：已连接" || print "  Antigravity：未连接"
has "$HOME/.kiro/hooks/clamshell-assistant.json" && print "  Kiro：已连接" || print "  Kiro：未连接（未安装 Kiro，或 AI 智能模式未开启）"
has "$HOME/.grok/hooks/clamshell-assistant.json" && print "  Grok Build：已连接" || print "  Grok Build：未安装（Grok Bot 桌面版的任务在云端电脑上运行，不受本机睡眠影响）"
print
print "[3] AI 智能模式"
if [[ "$(defaults read local.reminal.clamshellassistant SmartMode 2>/dev/null)" == "1" ]]; then print "  已开启"; else print "  未开启（菜单栏 › 高级选项 › AI 智能模式）"; fi
[[ -S "$SUP/agent.sock" ]] && print "  本地通道：正常" || print "  本地通道：未开启"
print
print "[4] 最近的事件（只记录合盖助手自己的动作，不含任何对话内容）"
tail -n 15 "$SUP/events.log" 2>/dev/null || print "  暂无"
print
print "检查完成，可以关闭此窗口。"
