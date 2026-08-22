# NEXT_TARGET

文档状态：唯一活跃目标
最近核对：2026-08-22
产品基线：v0.55（build 55）

## 目标：把 Codex Runtime 第一版收敛为可分发、可完整试用的 v0.55 候选

当前 Code、Cowork 与 CLI Code/Cowork 已切到基于官方 Codex App Server 0.145.0的窄派生
`0.145.0-intatis.2`，旧 Swift agent core 没有生产 fallback。下一目标不是再写一个 adapter 或补第二套内核，而是在同一官方
extension/API 上完成分发和产品投影。

## 已完成

- 固定 OpenAI Codex `rust-v0.145.0` / peeled commit
  `25af12f7e61572b0bc18ddb1008be543b91519b0`；记录 Apache-2.0、upstream NOTICE 与
  Ratatui-derived attribution。
- checked-in patch恢复旧链路的request-owned `options.provider` opaque passthrough，只占据最终Responses
  `provider`子树；无控制header、generic whole-body、proxy/translator，未来provider-owned字段无需再改
  Rust。派生binary与官方`codex`分名安装，后者不被覆盖。
- 新增 `IntatisCodexRuntime`：exact executable/version、isolated CODEX_HOME、owner-only storage、
  stable stdio JSON-RPC、thread start/resume、turn start/wait/interrupt、item stream、command/file/
  permission approval、Goal 与 shutdown。
- Intatis provider 直接投影为 `wire_api=responses`、`requires_openai_auth=false`；credential只进
  child environment，不使用 ChatGPT login。
- 通过 official `model_catalog_json` 把 auto-review model 固定到 selected Responses model；0.145.0
  exact catalog schema 已由真实 App Server offline handshake 验证。
- macOS Code/Cowork 保留原 UI shell，但 shipping send/start/cancel/shutdown 只调用 Codex；旧
  AgentLoop/Orchestrator方法编译期不可用。
- CLI `intatis code|cowork` 使用同一 runtime；Chat 仍使用原 ChatLoop。
- legacy EventLog session without Codex mapping 明确拒绝自动空-thread迁移；source rollback可行，
  runtime backend fallback不存在。
- fake full-turn协议测试、真实 pinned App Server offline handshake、CLI startup/exit smoke、macOS
  Debug build 已通过；最终全量验证以当前工作树收口结果为准。

## 下一阶段必须完成

1. **Codex binary distribution closure**

   - 从 fixed commit/Cargo.lock + checked-in patch 产出 arm64+x86_64；保存 source/toolchain/binary hash。
   - 完整审计并分发 Cargo dependency license/NOTICE closure。
   - 组装 universal或明确 architecture-correct auxiliary executable。
   - nested binary先 Developer ID签名，再签 outer App；跑 Hardened Runtime、notarization、staple、
     Gatekeeper、fresh-user startup与 exact `codex --version`。

2. **官方 MCP/plugin 接线**

   - 只使用 Codex config/plugin/MCP official extension point。
   - 把 Intatis 已批准的 MCP server配置投影到 isolated CODEX_HOME，先做 secret/permission/provenance
     设计；不得把原 Intatis MCP runtime当并行工具 backend。
   - 自动权限审查等 Intatis差异能力若保留，优先做 Codex plugin/MCP；无法用官方 extension精确表达
     时停下请求用户决定。

3. **Cowork UI 完整投影**

   - 通过稳定 parent/child thread与collaboration item API显示 child roster、状态和可选 transcript。
   - 评估 stable API是否足以恢复完整 item history；experimental pagination不得未经新决定进入
     shipping path。
   - Intatis WorkTask卡片若继续保留，必须明确是 app-owned product metadata，经官方 MCP/plugin
     接线，不得复制 Codex scheduler。

4. **Goal/approval/interaction 完整性**

   - 将 upstream thread Goal投影到现有 Goal card并实现 pause/resume/clear；Codex保持唯一 Goal执行权威。
   - 接 `request_user_input` 与 MCP elicitation的现有 UI；unsupported request仍 fail closed。
   - 验证 auto-review在目标非 OpenAI Responses provider上的真实 tool call；provider不支持原生 Codex
     tool shape时明确失败，不做协议转换。

5. **历史与删除生命周期**

   - 设计显式、可预览、可回退的 legacy session migration或保持“新建 session”政策；禁止静默注入。
   - session delete必须同时精确 drain process并删除该 session自己的Codex store；不得影响其他 thread。
   - `/clear` 应调用官方 thread replacement/archive/delete语义并保留历史，不能直接删 mapping猜状态。

6. **验证与发布**

   - 补 UI ViewModel source-shape/fixture与 approval/cancel/resume/migration tests。
   - 运行完整 `swift test`、macOS Debug/Release、iOS Simulator、CLI macOS/Linux gate。
   - 完成最终 docs、NOTICE、bundle inventory、size、签名/公证和干净机测试后，才能恢复 v0.55
     Developer ID发布目标。

## 明确非目标

- 不重新实现 Codex agent loop、tool scheduler、sandbox、auto-review、context、MCP或subagent core。
- 不新增旧 AgentLoop/Orchestrator自动 fallback、parallel/shadow backend或Chat Completions translator。
- 不用 ChatGPT login替代 Intatis provider credential。
- 不把 current Codex main/experimental schema冒充 pinned 0.145.0 stable contract。
- 不让 Codex runtime进入 Chat或iOS target。
- 不在 binary/license/sign/notarization证据缺失时宣称当前 App 已可独立分发。

目标完成后删除本文件或替换为下一个单一目标，不继续追加里程碑流水账。
