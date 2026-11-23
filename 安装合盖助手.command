#!/bin/zsh
# 双击安装 / 升级合盖助手：构建 → 测试（失败不安装）→ 备份 → 替换 → 自动重新启动。
cd "$(dirname "$0")"
zsh ./install.sh
print
print "完成后可以关闭此窗口。"
