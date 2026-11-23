# 预编译 Reminal 精简服务（仅用于没有 Go 的机器）

`reminal-1.4.1-darwin-arm64` 取自官方发布包 `ClamshellAssistant-1.4.1-macOS.zip`
（https://github.com/mehejun876-del/clamshell-assistant/releases/tag/v1.4.1 ，
zip SHA-256 `f4019cf75f06bd1a2b8ae9bb1fa3e69c3cd569da0863b8cea3d6c8a2a62c70e4`，与发布页 digest 一致）。

V2 **没有修改** `ThirdParty/reminal-lid` 的任何 Go 源码，因此这个二进制与从同一源码构建的结果功能一致。
`build.sh` 在找不到 Go 时通过 `REMINAL_LID_BIN` 复用它；有 Go 时始终从源码构建。
对应源码：本仓库 `ThirdParty/reminal-lid`（AGPL-3.0，见 `ThirdParty/Reminal-LICENSE` 与 `ThirdParty/NOTICE`）。
