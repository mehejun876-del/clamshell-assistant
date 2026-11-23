#!/bin/zsh
# 资源占用实测（只读）：空闲 RSS / 物理占用、CPU、空闲唤醒次数，以及电源断言。
# 用法：zsh measure.sh [采样秒数，默认 60]。可先装 1.4.1 测一次，再装 V2 测一次对比。
set -u
SECS="${1:-60}"
P=$(pgrep -f "/合盖助手.app/Contents/MacOS/ClamshellAssistant" | head -1)
[[ -n "$P" ]] || { print "合盖助手未运行"; exit 1; }
print "== 进程（pid $P）及其子进程"
ps -o pid,ppid,rss,%cpu,etime,command -p "$P" $(pgrep -P "$P" | tr '\n' ' ') $(pgrep -f clamshell-helper | tr '\n' ' ') 2>/dev/null
print "\n== 物理内存占用（footprint）"
command -v footprint >/dev/null && footprint "$P" 2>/dev/null | head -20 || print "footprint 不可用"
print "\n== ${SECS}s 采样：CPU 与空闲唤醒（idlew），越接近 0 越好"
top -l 2 -s "$SECS" -pid "$P" -stats pid,command,cpu,idlew,mem,power | tail -2
print "\n== 本程序相关的电源断言"
pmset -g assertions | grep -iE 'caffeinate|reminal|Clamshell|合盖' || print "（无）"
print "\n提示：空闲时 V2 不应有常驻定时器；Reminal 精简服务沿用 1.4.1 的 2 s 设置检查与 12 s 显示器检查（未改动）。"
