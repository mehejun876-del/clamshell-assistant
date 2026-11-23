#!/bin/zsh
# 发布：推送 make-pr.sh 准备好的 release/v<版本> 分支、开 PR，并发布 GitHub Release（附安装包与 SHA-256）。
# 用法：zsh publish.sh [--merge] [--prerelease]
#   --merge       PR 开好后直接合并进 main（普通合并，不改写历史），Release 指向 main
#   --prerelease  Release 标记为预发布
# 需要已登录的 gh（gh auth status）。不强推，不删除任何分支或标签。
set -eu
setopt pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="$(dirname "$SRC")/clamshell-assistant-git"
REPO="mehejun876-del/clamshell-assistant"
GH="$(command -v gh || print -r -- "$HOME/.local/bin/gh")"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Info.plist")"
BRANCH="release/v$VER"; TAG="v$VER"
ZIP="$SRC/dist/ClamshellAssistant-$VER-macOS.zip"
MERGE=0; PRE=()
for a in "$@"; do case "$a" in --merge) MERGE=1 ;; --prerelease) PRE=(--prerelease) ;; esac; done
say() { print -r -- "[发布] $*"; }

[[ -f "$ZIP" ]] || { say "缺少安装包：$ZIP（先双击「安装合盖助手.command」构建）"; exit 1; }
[[ -f "$ZIP.sha256" ]] || (cd "$(dirname "$ZIP")" && shasum -a 256 "$(basename "$ZIP")" > "$ZIP.sha256")
cd "$WORK"
[[ "$(git branch --show-current)" == "$BRANCH" ]] || { say "当前不在 $BRANCH，请先运行 make-pr.sh"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { say "克隆目录有未提交的改动，已停止"; exit 1; }
"$GH" auth status >/dev/null 2>&1 || { say "gh 未登录，请先运行 gh auth login"; exit 1; }

git push -q -u origin "$BRANCH"
PR="$("$GH" pr list -R "$REPO" --head "$BRANCH" --state open --json url -q '.[0].url')"
[[ -n "$PR" ]] || PR="$("$GH" pr create -R "$REPO" --base main --head "$BRANCH" --title "合盖助手 $VER" --body-file CHANGELOG.md)"
say "PR：$PR"
TARGET="$BRANCH"
if (( MERGE )); then
  "$GH" pr merge "$PR" -R "$REPO" --merge
  TARGET="main"
  say "已合并进 main"
fi

NOTES="$(mktemp -t clamshell-notes)"
{
  print "## 安装"
  print "1. 下载下面的 \`ClamshellAssistant-$VER-macOS.zip\`，解压后把「合盖助手.app」拖进「应用程序」。"
  print "2. 本应用未经 Apple 公证：第一次打开时按住 Control 单击，选择「打开」。"
  print "3. 需要 Apple 芯片的 Mac、macOS 14 或更高版本。从源码安装：双击 \`安装合盖助手.command\`。"
  print ""
  print "SHA-256：\`$(awk '{print $1}' "$ZIP.sha256")\`"
  print ""
  print "自动化测试全部通过（模拟测试，不碰真实电源设置）。真实合盖、长时间运行建议自行观察；有问题可用 \`rollback.sh\` 回滚。"
  print ""
  sed -n '/^## 2/,$p' CHANGELOG.md | sed 's/^## /### /'
  print ""
  print "## 已知限制"
  awk '/^### 不能保证的部分/{f=1;next} /^一键安装/{f=0} f' README.md
} > "$NOTES"

if "$GH" release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  "$GH" release upload "$TAG" "$ZIP" "$ZIP.sha256" -R "$REPO" --clobber
  "$GH" release edit "$TAG" -R "$REPO" --notes-file "$NOTES" $PRE
else
  "$GH" release create "$TAG" "$ZIP" "$ZIP.sha256" -R "$REPO" --target "$TARGET" --title "合盖助手 $VER" --notes-file "$NOTES" $PRE
fi
rm -f "$NOTES"
say "Release：https://github.com/$REPO/releases/tag/$TAG"
