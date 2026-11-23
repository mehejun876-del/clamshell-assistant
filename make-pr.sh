#!/bin/zsh
# 准备发布（不推送）：在独立目录克隆 GitHub 仓库，基于 origin/main 建分支 release/v<版本>，
# 只复制要公开的源码和文档（不含本机备份、构建产物、诊断记录、动画包原稿和开发用脚本），
# 在克隆里重新跑一遍全部测试，通过后提交到本地分支。推送、PR、Release 由 publish.sh 完成。
# 不动 ~/Developer/clamshell-assistant 或其他已有的检出。
set -eu
setopt pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(dirname "$SRC")/clamshell-assistant-git}"
REPO="mehejun876-del/clamshell-assistant"
GH="$(command -v gh || print -r -- "$HOME/.local/bin/gh")"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Info.plist")"
BRANCH="release/v$VER"
FILES=(.gitignore LICENSE README.md CHANGELOG.md THIRD_PARTY_NOTICES.md Info.plist AppIcon.icns
       main.swift State.swift Policy.swift Lease.swift Agents.swift Tests.swift PolicyTests.swift Helper
       build.sh test.sh package.sh install.sh rollback.sh measure.sh make-pr.sh publish.sh
       安装合盖助手.command 检查智能模式.command docs prebuilt ThirdParty tools/make-app-icon.swift)
say() { print -r -- "[准备发布] $*"; }

[[ -d "$WORK/.git" ]] || git clone -q "https://github.com/$REPO.git" "$WORK"
cd "$WORK"
git fetch -q origin --tags --prune
# 上一次准备到一半停下（例如测试失败）时，发布分支上的改动都是本脚本复制进来的，可以安全重来
if [[ -n "$(git status --porcelain)" && "$(git branch --show-current)" == "$BRANCH" ]]; then
  git reset -q --hard; git clean -fdq
fi
[[ -z "$(git status --porcelain)" ]] || { say "克隆目录有未提交的改动，已停止（不会清理）：$WORK"; exit 1; }
git checkout -q -B "$BRANCH" origin/main
for f in $FILES; do
  [[ -e "$SRC/$f" ]] || { say "缺少文件：$f"; exit 1; }
  rm -rf "./$f"; mkdir -p "$(dirname "./$f")"; ditto "$SRC/$f" "./$f"
done
find . -name .DS_Store -not -path './.git/*' -delete
for f in ${(f)"$(git -c core.quotepath=off ls-files)"}; do
  [[ -e "$SRC/$f" ]] || say "注意：仓库里原有、本次不包含的文件（保持原样）：$f"
done
chmod +x build.sh test.sh package.sh install.sh rollback.sh measure.sh make-pr.sh publish.sh 安装合盖助手.command 检查智能模式.command

say "在克隆里重新运行全部测试（只用提交的文件）……"
if ! zsh ./test.sh > /tmp/clamshell-release-test.log 2>&1; then
  tail -30 /tmp/clamshell-release-test.log; say "测试未通过，未提交"; exit 1
fi
grep -E '^PASS [0-9]+ assertions' /tmp/clamshell-release-test.log || true
rm -rf build

if [[ -z "$(git config user.email || true)" ]]; then      # 只写进这个克隆，不改全局设置
  GH_LOGIN="$("$GH" api user -q .login)"; GH_ID="$("$GH" api user -q .id)"
  git config user.name "$GH_LOGIN"; git config user.email "$GH_ID+$GH_LOGIN@users.noreply.github.com"
fi
git add -A
if git diff --cached --quiet; then
  say "与 origin/main 相比没有变化"
else
  git commit -q -m "合盖助手 $VER：全自动 AI 智能模式、保活租约与崩溃守护、新动画、固定宽度菜单" \
    -m "AI 智能模式识别 Codex（含 ChatGPT 本机 Work）、Gemini CLI、Antigravity、Kiro、Grok Build 和 AWS Quick；主菜单四项与 1.4.1 一致；Reminal 精简版 Go 源码未改动。详见 CHANGELOG.md 与 docs/DESIGN-V2.md。"
fi
say "本地分支 $BRANCH：$(git rev-parse --short HEAD)（目录 $WORK）"
git --no-pager diff --shortstat origin/main...HEAD
say "确认后运行：zsh \"$SRC/publish.sh\""
