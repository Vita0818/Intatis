# NEXT_TARGET

文档状态：唯一活跃目标
最近核对：2026-08-19
产品基线：v0.55（build 55）

## 目标：完成 v0.55 Developer ID 直接分发候选

把当前 v0.55 源码收敛为可验证、可安装、可直接分发的 macOS ZIP/DMG；不走 App Store。

## 已完成

- 版本事实源已推进为 `0.55 (55)`。
- 新增版本一致性检查，覆盖 `project.yml`、参考 Info.plist、当前入口文档和生成工程。
- `IntatisMac` 显式启用 Hardened Runtime。
- `scripts/package-macos-release.sh` 已实现 universal Release、Developer ID App/DMG
  signing、Apple notarization、staple、codesign、Gatekeeper assessment、拖放安装 DMG 和
  ZIP/DMG SHA-256 清单；不构建 legacy App Store target。
- 当前仓库文档已重新划分为当前规范和历史证据，README/状态/测试不再以旧 v0.9/v0.16
  里程碑冒充当前版本。
- v0.55 的 Xcode 工程生成、版本一致性、macOS universal Release 与 iOS Simulator Debug
  正在本轮重新验证；旧 v0.48 构建证据不替代本轮结果。
- 本机 `/Applications/Intatis.app` 当前仍安装 `0.48 (48)` ad-hoc Hardened Runtime 开发构建，
  严格 codesign、entitlements、无 quarantine 与 staging 可执行文件一致性均已验收。安装前的
  `0.40 (40)` 保留为 `~/.Trash/Intatis-before-install-20260811-201644.app` 可恢复备份。该开发安装不能作为 v0.55 Developer ID
  公证发行证据。
- AgentKernel soft-token-budget stale fixture 已在不改生产预算保护的前提下收口；focused
  用例、169 项 AgentKernel suite 与完整 `swift test` 均通过。
- 用户宿主环境已具备有效 Developer ID Application identity，并已保存 `Intatis-Notary`
  notarytool Keychain profile；凭据和私钥均未写入仓库。
- 发行脚本已支持构建/公证分段切换网络：GitHub 依赖解析和签名阶段保持代理/VPN，暂停后
  关闭会阻断 Apple 的代理/VPN，再原地继续公证，无需重新构建。
- Apple 已接收两次旧 App submission；2026-08-18 只读查询确认两条均已 `Accepted`、
  `In Progress=0`。它们不能作为 v0.55 公证证据。旧脚本的无输出
  `--wait` 已被用户中断，且旧临时 App 已清理。发行脚本现改为显示 upload/status、保存
  submission ID、默认 30 分钟有界等待，并在超时/中断时保留可恢复签名 App/DMG。

## 剩余 release gate

1. 运行 v0.55 版本一致性、SwiftPM、shipping target、bundle metadata/architecture 与发行脚本预检。
2. 本地门槛通过后，在代理/VPN开启时只运行一次：

   ```sh
   INTATIS_PAUSE_BEFORE_NOTARIZATION=1 \
   INTATIS_NOTARY_PROFILE=Intatis-Notary \
     scripts/package-macos-release.sh
   ```

3. 脚本显示网络切换提示后保持终端打开，关闭会阻断 Apple 的代理/VPN，再按 Return；若
   Apple 探测失败，调整网络后按提示原地重试。
4. 若 30 分钟后仍为 `In Progress`，不要再次上传；用脚本打印的
   `INTATIS_RESUME_RELEASE_DIR` 命令稍后恢复同一 submission。
5. 记录最终 ZIP/DMG 文件名、SHA-256、notarization Accepted、stapler validate、codesign、
   Gatekeeper assessment，以及一台干净 macOS 用户环境的安装/首次启动结果。

## 明确非目标

- 不构建、修复或发布 `IntatisMacAppStore`。
- 不为 App Store App Sandbox 裁剪 terminal、Git、MCP、Skills 或 workspace 能力。
- 不实现诊断日志远程上传。
- 不在缺证书、公证或 Gatekeeper 证据时输出“正式发行”结论。
- 不用字体截图替代 Dynamic Type、VoiceOver、中英混排、final bundle/hash/license/size 等正式验收；
  不覆盖已有签名/公证 recovery artifact。
- 不把历史 v0.10/v0.16 文档批量改名为当前版本；它们是历史证据。

目标完成后删除本文件或替换为下一个单一目标，不再追加已完成里程碑流水账。
