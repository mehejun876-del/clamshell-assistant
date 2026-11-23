#!/bin/zsh
# 静态检查 + 非侵入式自动化测试。所有写操作都是替身模拟：不改电源设置、不改 sudoers、
# 不写用户的 Agent 配置（Hook 测试只在临时目录里进行）。失败即以非零状态退出。
set -e
cd "$(dirname "$0")"
mkdir -p build
APP_SOURCES=(main.swift State.swift Policy.swift Lease.swift Agents.swift)
HELPER_SOURCES=(Helper/main.swift State.swift Policy.swift Lease.swift)
T=arm64-apple-macosx14.0

echo "== 1/5 Swift 类型检查（应用 / helper / 测试构建）"
swiftc -typecheck -target $T $APP_SOURCES
swiftc -typecheck -target $T $HELPER_SOURCES
swiftc -typecheck -target $T -D SELFTEST $APP_SOURCES Tests.swift PolicyTests.swift

echo "== 2/5 构建并运行自检（1.4.1 原有回归 + 2.1 全自动 AI 模式/租约/Hook/菜单，写操作全部模拟）"
swiftc -D SELFTEST -Osize -wmo -target $T $APP_SOURCES Tests.swift PolicyTests.swift -o build/clamshell-tests
build/clamshell-tests

echo "== 3/5 Go：Reminal 精简服务（V2 未改动）"
if command -v go >/dev/null 2>&1; then
  (cd ThirdParty/reminal-lid && go vet ./... && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o /dev/null ./cmd/reminal)
  echo "go vet / go build 通过"
else
  echo "跳过：未安装 Go（将复用 prebuilt/ 中已校验的 1.4.1 同源二进制）"
fi

echo "== 4/5 helper 冒烟测试（不连接任何真实 Agent）"
swiftc -Osize -wmo -target $T $HELPER_SOURCES -o build/clamshell-helper-test
out=$(print -r -- '{"session_id":"smoke","hook_event_name":"Stop"}' | build/clamshell-helper-test hook codex Stop)
[[ "$out" == "{}" ]] || { echo "FAIL: Codex Stop 应输出 {}，实际：$out"; exit 1; }
out=$(print -r -- '{"session_id":"smoke"}' | build/clamshell-helper-test hook codex UserPromptSubmit)
[[ -z "$out" ]] || { echo "FAIL: Codex UserPromptSubmit 不能输出文字（会进入模型上下文）"; exit 1; }
out=$(print -r -- '{"conversationId":"smoke","fullyIdle":true}' | build/clamshell-helper-test hook antigravity Stop)
[[ "$out" == '{"decision":"stop"}' ]] || { echo "FAIL: Antigravity Stop 输出：$out"; exit 1; }
out=$(print -r -- 'not json' | build/clamshell-helper-test hook gemini BeforeAgent)
[[ "$out" == "{}" ]] || { echo "FAIL: Gemini 输出：$out"; exit 1; }
build/clamshell-helper-test bogus args; echo "helper：输出契约正确，异常输入安全退出 0"

echo "== 5/5 无常驻轮询的静态核查"
if grep -nE 'Timer\.scheduledTimer|repeating: *\.(seconds|milliseconds)|DispatchSource\.makeTimerSource' main.swift Agents.swift Policy.swift Lease.swift Helper/main.swift | grep -v 'policyTimer\|let t = DispatchSource.makeTimerSource'; then
  echo "FAIL: 发现新的定时器"; exit 1
fi
grep -c 'repeating: .never' main.swift >/dev/null && echo "唯一的 V2 定时器是一次性（repeating: .never）"
echo "全部自动化测试通过（模拟测试，不等于 MacBook 实机合盖验证）"
