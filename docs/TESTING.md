# TESTING

最近自查日期：2026-07-05

## 环境

- 操作系统 / 平台：macOS 13+（库与 CLI）；iOS 16+（IntatisiOS）；CLI 理论支持 Linux（`#if canImport(SwiftUI)` 守卫）
- 工具链版本：Swift 5.9
- 依赖管理：SwiftPM（`Package.swift`）+ XcodeGen（`project.yml` → `Intatis.xcodeproj`）。v0.1 **零第三方依赖**。
- 凭据 / 配置：UserDefaults（规范主键 `intatis.providerCatalog.v1`，provider 保存 `baseURL` + `chatEndpoint` + secret ref 元数据；聊天页当前选择保存到 `intatis.providerSelection.v1`；旧 `intatis.baseURL`、`intatis.model` 为迁移/兼容镜像）+ 配置文件 secret（macOS 设置页把用户主动输入的 API key 写入当前可编辑 OpenCode-compatible config `provider.<id>.options.apiKey`；iOS 默认写入 app container `Intatis/auth.json`，可由 `INTATIS_AUTH_FILE` 覆盖；真实 provider 请求也可从 OpenCode-compatible config `provider.<id>.options.apiKey`、auth JSON、`{env:NAME}`、`{file:path}` 懒加载并缓存 secret）+ macOS 高级 JSON/JSONC 配置（`INTATIS_CONFIG` / `~/.config/intatis/opencode.json` / `~/.config/intatis/intatis.json` / `~/.config/opencode/opencode.json`，旧 `config.json` 兜底兼容读取）。GUI 不再读写 OS Keychain。

## 构建

### SwiftPM（库 + CLI）

```sh
swift build                 # Debug
make build                  # 同上
swift build -c release      # Release
make release                # 同上
make install                # 符号链接到 BINDIR
```

### XcodeGen（.app bundle）

```sh
make app                    # xcodegen generate && open Intatis.xcodeproj
```

## 测试

```sh
swift test                  # 全部无头 XCTest
make test                   # 同上
swift test --filter IntatisCoworkTests
swift test --filter AutomaticPermissionReviewTests
swift test --filter IntatisPermissionTests/ReviewerTests
swift test --filter IntatisConversationTests
swift test --filter IntatisProvidersTests
swift test --filter IntatisConversationCodeTests
swift test --filter IntatisAgentKernelTests
swift test --filter CoworkEndToEndTests
```

- 测试 target（10）：`Packages/<Mod>/Tests/`。`IntatisSharedUI` 无测试。
- `swift test` 无头：无测试 target 依赖 UI/app target。

## Lint / Format

仓内无显式 lint/format 配置。`UNKNOWN` — 是否有 SwiftFormat/SwiftLint 需后续确认。建议至少 `swift build` 通过。

## 手动验证矩阵

| 场景 | 步骤 | 预期 | 状态 |
|---|---|---|---|
| IntatisMac chat | `make app` → Xcode 运行 IntatisMac → chat 发消息 | 流式回复 | UNKNOWN（需真机 + key） |
| IntatisMac cowork | Xcode 运行 IntatisMac → cowork → @mention | agent 间路由 + 权限卡片 | UNKNOWN |
| IntatisMac multimodal | Xcode 运行 → 图像/转写 | artifact 写入 + 事件 | UNKNOWN |
| IntatisMac 多 provider/model 设置 | 设置页新增 provider → 填 Base URL 或 Chat endpoint/API key → 新增/选择 model → 保存 → Chat/Code/Cowork 新请求 | Base URL 与 Chat endpoint 互相同步；metadata 不写入 UserDefaults 明文 key；用户本次输入的 API key 写入当前可编辑 provider JSON 的 `provider.<id>.options.apiKey` 而非 Keychain；已有 key 显示圆点占位；新请求使用选中 provider/model/chat endpoint | 构建通过；真实 endpoint/key UNKNOWN |
| IntatisMac 高级 JSON provider 配置 | 设置页点击 Open JSON → 编辑生成/打开的 `~/.config/intatis/opencode.json`、现有 `~/.config/opencode/opencode.json`（或 `INTATIS_CONFIG` 指定文件），按 OpenCode-compatible `enabled_providers` + `model` + `provider` map 配置 provider/model，并用 `options.apiKey` 的 OpenCode 原生明文、`{env:NAME}` 或 `{file:path}` 指向 secret → 重启或保存后发 chat | JSON/JSONC catalog 覆盖 UserDefaults；旧 `config.json` 与 direct `providers` 数组仍可读取但 Open JSON 优先生成/打开 `opencode.json`；模板含 `$schema` / `enabled_providers` / `npm` / `options.baseURL` / `models` 和 `{env:...}` key 引用；设置页 Save 会把本次输入的 key 写入同一文件 `provider.<id>.options.apiKey`；真实请求按 env/file/auth JSON/OpenCode config 取 secret；不读写 OS Keychain，未把 key 写入 UserDefaults | 构建通过；真实文件/key UNKNOWN |
| IntatisMac Chat 模型切换 | Chat 页打开模型菜单 → 选择另一个 provider/model → 发送下一条消息 | 菜单按 provider 分组；选择写入 `intatis.providerSelection.v1`；`ProviderRegistry` 立即重建；下一条 chat 使用新 provider/model；高级 JSON 文件不被自动改写 | 构建通过；真实 endpoint/key UNKNOWN |
| IntatisMac UI 信息架构 | 运行 IntatisMac → 在侧栏切换 Chat/Code/Cowork → 新建/恢复各 mode session → 发送或回放消息 → 调整窗口宽度 | `Intatis` 标题下方是横向 mode switch；剩余侧栏空间显示当前 mode 的 compact session history；New session 位于 history 区域；主 thread header 不再放 New/session/model 控件；模型/context/token 控制位于 composer；Chat 默认无右 inspector；Code/Cowork 右侧显示 structured status inspector；Chat/Code/Cowork 对话泡泡按整行 leading/trailing 对齐，短 user 消息也贴右，窄窗口下降低 gutter 和最大宽度，不靠内部 spacer 漂移；Git 只显示状态，不提供 commit/branch/PR/CI | `swift build`、full SwiftPM tests（275 tests, 0 failures）、IntatisMac Xcode Debug build、IntatisiOS Xcode Debug build 通过；合成 `NSHostingView` 渲染覆盖 Chat-shell、Chat-like bubble row、CodeShell、CoworkShell 的 360/500/700/940/980/1180pt 关键宽度，含短 user 泡泡、长 wrapped user 泡泡、窄窗口 composer 与宽屏 inspector；临时 `LayoutAssert` 像素级断言覆盖共享气泡行 320/360/380/420/500/560/700/760/940/1180/1440pt，验证短 user 泡泡右边界贴内容列右侧、assistant 泡泡左边界贴内容列左侧、长 user 泡泡不超过 `messageMaxWidth` 且不越出内容列；同一验证器新增 Chat-equivalent shell（320/360/500/700/760/940/1180/1440pt），并用诊断配色穿过真实 `CodeShell`（360/500/700/940/1180/1440pt）与 `CoworkShell`（360/500/700/980/1180/1440pt）路径，验证 header/composer/inspector 出现前后气泡列仍贴合内容列；隔离 HOME + placeholder auth 下 LaunchServices 可启动 Intatis 窗口，本轮 CGWindow 元数据确认窗口约 1022×660，AX trusted 但 `AXFocusedWindow` / `AXFocusedUIElement` / `AXWindows` 只暴露 app/menu 层级，CGWindow image capture 返回 failed；当前环境缺 Screen Recording/CGWindow 截图权限，运行态像素截图/人工视觉 QA 仍 UNKNOWN |
| IntatisMac Chat/Code/Cowork session/history | 侧栏切换 mode → 点当前 history 区域 New → 发送消息 → 从对应 mode history 恢复旧 session → 再发送消息 | 每个 session 对应独立 `<session>/events.jsonl` 与 artifacts 目录；New 不继续追加到旧会话；History 恢复旧投影；切换 mode 时 history set 随 mode 变化 | `swift build --scratch-path /private/tmp/intatis-ui-build` 与 macOS/iOS Xcode build 通过；GUI 手动 UNKNOWN |
| IntatisMac GUI token/turn stats | Chat/Code/Cowork 发送一轮模型请求；fake provider 覆盖拆分 usage chunk、OpenAI cached prompt tokens 与 Agent 多请求 usage | 最近一轮 `turn_stats` 被 GUI 投影为 composer-local 单行统计；有 cached usage 时显示 cached input、non-cached input、output、total；缺 cached/context 字段时降级为 prompt/completion/total 或耗时；同一响应内 split usage 字段级合并，Agent 工具循环跨请求累计；不占用主要对话区域 | full SwiftPM tests 通过（275 tests, 0 failures），Provider focused tests 通过（62 tests, 0 failures），Conversation focused tests 通过（34 tests, 0 failures），AgentKernel focused tests 通过（18 tests, 0 failures），macOS/iOS Xcode Debug build 通过；真实 endpoint usage 手动 UNKNOWN |
| API/provider 错误反馈 | fake HTTP/SSE 返回 401、provider error payload、HTTP 502 HTML、malformed SSE、缺 completion marker 的流式 EOF、非 2xx image/transcription、HTTP 2xx 但 image/transcription payload 不匹配、非 HTTP Chat endpoint/Base URL；ChatLoop/AgentLoop 与 Chat/Code projection 回放 provider 401/429、malformed SSE error、partial delta 后 error；tool-call stream 覆盖缺失/string index、JSON object arguments、截断/非法 JSON arguments、空 arguments 兼容、非首个 choice 的 content/tool_calls/finish_reason、多 choice 中 `tool_calls` finish reason 优先、`tool_calls` 结束但缺 tool name、tool-call delta 后错误 `stop` 结束态、旧式 `function_call` 结束态；工具调用覆盖坏 JSON / 非对象 / 缺 required 字段 / 基础类型错误 / 数值越界 / 字符串长度违规 / 未知字段参数 | `ProviderErrorFormatting` 输出包含状态码、可行动提示与裁剪后的结构化 provider message；HTTP 非 2xx 的 HTML/纯文本代理错误页只显示裁剪 `Preview`，不误标为 `Provider said`；非法 provider endpoint 在网络前变成 `config` 错误并提示检查 Base URL/Chat endpoint；image/transcription 2xx 异常 payload 变成带结构化 provider message 或 preview 的 decoding 错误，普通 HTML/缺字段 JSON/坏 base64 不误标为 `Provider said`；ChatLoop/AgentLoop 通过 `ErrorPayload` 记录明确 code/message；Chat / Code / Cowork 错误卡片显示 retry/config/endpoint 等恢复建议；partial assistant/agent 输出失败时保留已输出文本并标记 stopped；缺完成标记不得合成 completed；不完整 tool-call finish 或非空 arguments 非完整 JSON 不得合成成功；tool-call delta 归一为既有 `ToolCall`；坏工具参数在权限前变成 `invalid tool input:`；不写完整响应体或 secret | full SwiftPM tests 通过（275 tests, 0 failures），Provider focused tests 通过（62 tests, 0 failures），Conversation focused tests 通过（34 tests, 0 failures），macOS/iOS Xcode Debug build 通过；真实 provider/key UNKNOWN |
| Provider health check / 设置页 Test Provider | macOS 设置页点击 Test Provider，iOS Settings 点击 Test Provider；fake stream 覆盖 completed stream、missing `[DONE]`、`finish_reason` without `[DONE]`、缺完成标记 preview 保留、timeout、unknown endpoint、非法 provider URL、agent role 与 agent request body | 设置页先保存当前配置再测试；报告显示 ok/failed、endpoint/model/wire、耗时、首 token、usage/code/message、裁剪 preview；chat/agent health check 均请求 usage；非法 URL 报告 `config`，不尝试发起底层 transport；不显示 secret 或完整响应体；macOS/iOS 复用 provider 层逻辑；缺 `[DONE]` 但有 `finish_reason` 不误判为 partial stream，真正缺完成标记时报告 partial stream | Provider focused tests 通过（62 tests, 0 failures），full SwiftPM tests 通过（275 tests, 0 failures），macOS/iOS Xcode build 通过；真实 provider/key UNKNOWN |
| Provider retry/timeout/rate-limit policy | fake stream/data client 覆盖首字节前 503、mid-stream 503、tool-calling 503、finish 后 usage、重复完成信号、缺 completion marker、非 HTTP endpoint 预校验、image 503→200、image 429 Retry-After→200、image/transcription 2xx 异常 payload、transcription timeout、Retry-After delay cap、duration-style reset header | 首字节前 streaming 失败会 retry；收到 response bytes 后不会 retry；`finish_reason` 与 `[DONE]` 都可完成流，finish 后 usage 不丢失且 done 不重复；无完成信号的 EOF 会变成 endpoint 兼容错误；非法 provider URL 在 network/retry 前变成 config 错误；HTTP 非 2xx 未结构化响应体只显示裁剪 preview；image/transcription 走共享 retry/timeout，2xx 异常 payload 不 retry 而是明确 decoding 错误；`Retry-After` / rate-limit reset headers（数字秒、HTTP 日期、duration 字符串）影响 retry delay 并进入错误文案；错误包含可行动 timeout/status 文案 | Provider focused tests 通过（62 tests, 0 failures），full SwiftPM tests 通过（275 tests, 0 failures）且 macOS/iOS Xcode Debug build 通过；真实 provider/key UNKNOWN |
| 工具执行失败反馈 | Code/Cowork fake provider 触发 unknown tool、permission denied、tool error、坏 JSON 参数、非对象参数、缺 required 字段、基础类型错误、数值越界、字符串长度违规、未知字段参数、空 command/path/query/diff 参数、无参工具空参数、tool-calling partial stream EOF、不完整 tool-call finish、截断/非法 tool-call arguments、多 choice 工具 finish reason、非首个 choice tool-call、Agent 工具循环多请求 usage 累计 | `tool_result` observation 保留失败原因；坏 JSON / 非对象 / 缺 required 字段 / 基础类型错误 / 数字范围违规 / 字符串长度违规 / 被 `additionalProperties:false` 禁止的未知字段在权限请求和工具执行前返回 `invalid tool input:`；`read_file.maxBytes` 必须 `>= 1`；标准工具 path/query/command/diff 必须非空；required 为空的无参工具空参数归一为 `{}`；Code projection 标记失败、回填工具名并派生恢复建议；AgentLoop 对缺完成标记的 partial agent 输出写入 error 并标记 stopped；tool-call finish 缺完整工具调用或非空 arguments 非完整 JSON 时 provider 抛明确兼容错误；CLI 失败输出使用错误色；GUI 不解析 assistant transcript | full SwiftPM tests 通过（275 tests, 0 failures），AgentKernel focused tests 通过（18 tests, 0 failures），Cowork focused tests 通过（79 tests, 0 failures），Tools focused tests 通过（9 tests, 0 failures），Conversation focused tests 通过（34 tests, 0 failures），macOS/iOS Xcode Debug build 通过；GUI 手动 UNKNOWN |
| `/goal` Chat 标签 | Chat 输入 `/goal ship v0.12` → 发送 | 用户消息显示 Goal 标签；消息正文为 `ship v0.12`；provider 收到清洗后的目标文本；事件 `user_message.payload.tags == ["Goal"]` 且 `goal == "ship v0.12"` | SwiftPM focused tests 通过；GUI 手动 UNKNOWN |
| `/goal` Code 标签 | Code 输入 `/goal inspect workspace` → 发送 | Code 用户气泡显示 Goal 标签；AgentLoop 收到清洗后的目标文本；事件保留 Goal 元数据 | SwiftPM focused tests 通过；GUI 手动 UNKNOWN |
| `/goal` Cowork mention | Cowork 输入 `/goal @Alpha inspect` 或 `@Alpha /goal inspect` | 两种写法都路由到 @Alpha；用户事件 `to == Alpha`，显示 Goal 标签，agent 收到 `inspect` | SwiftPM focused tests 覆盖 Orchestrator payload；GUI 手动 UNKNOWN |
| CLI Cowork `/auto` 自动权限审查 | `intatis cowork` → 输入 `/auto` → 触发需要权限的写入/attach → 输入 `/default` | `/auto` 创建 `@permission-reviewer`；权限请求先生成 `permission_review`；allow 时工具执行，ask_user/错误时回退终端确认；`/default` 移除审查者；hard deny 不调用审查者 | `AutomaticPermissionReviewTests` 通过；真实 provider/key 手动 UNKNOWN；GUI UI 未实现 |
| IntatisMac 配置文件密钥 | 已有 auth JSON 或 OpenCode-compatible `options.apiKey` 时启动 app → 打开设置页 → 连续发送两条 chat | 启动、设置页和真实请求均不访问 OS Keychain；secret 从配置文件/env/file 读取并在进程内缓存；无 macOS Keychain 认证弹窗 | 构建通过；真机手动 UNKNOWN |
| IntatisiOS chat | Xcode 运行 IntatisiOS → chat | 流式回复，无工具/shell | UNKNOWN |
| IntatisiOS 多 provider/model 设置 | iOS Settings sheet 新增 provider/model → 填 Base URL 或 Chat endpoint/API key → 保存 → 发 chat | iOS 仍只链接 chat 子集；Base URL 与 Chat endpoint 互相同步；API key 写入 app container auth JSON 而非 Keychain；已有 key 显示圆点占位；新请求使用选中 provider/model/chat endpoint | 构建通过；真实 endpoint/key UNKNOWN |
| IntatisiOS Chat 模型切换 | Chat toolbar 模型菜单 → 选择另一个 provider/model → 发送下一条消息 | iOS 仍只链接 chat 子集；选择写入 `intatis.providerSelection.v1`；下一条 chat 使用新 provider/model | 构建通过；真实 endpoint/key UNKNOWN |
| IntatisiOS Chat session/history | iOS toolbar 点 `+` 新建 → 发消息 → 历史菜单恢复旧 session | iOS 仍只链接 chat 子集；每个 Chat session 对应独立 app container `<session>/events.jsonl` 与 artifacts 目录；恢复历史不触发 workspace/tool 模块 | `swift build --scratch-path /private/tmp/intatis-spm-build` 与 IntatisiOS Xcode build 通过；GUI 手动 UNKNOWN |
| IntatisiOS GUI token/turn stats | iOS Chat 发送一轮模型请求；fake provider 覆盖拆分 usage chunk 和 cached prompt tokens | iOS 仍只链接 chat 子集；最近一轮 `turn_stats` 通过 SharedUI 单行统计显示，不引入 workspace/tool 模块；同一响应内 split usage 字段级合并；cached/context 字段缺失时兼容旧显示 | full SwiftPM tests 通过（275 tests, 0 failures），Provider focused tests 通过（62 tests, 0 failures），Conversation focused tests 通过（34 tests, 0 failures），IntatisiOS Xcode build 通过；真实 endpoint usage 手动 UNKNOWN |
| iOS 子集边界 | 检查 IntatisiOS 链接的 product | 不含 Tools/Permission/AgentKernel/Cowork | 已确认（project.yml） |
| 权限门硬 deny | worker 尝试 spawn_agent | 被拒 | 已有测试覆盖 |
| Cowork 循环 | A→B→A 委派 | 被拒 | UNKNOWN — 见 COWORK_PRINCIPLES §8 |

## 验证边界声明

- 文档任务：至少运行 `git diff --check` 与 `git status --short`；**未运行构建/测试**，须声明。
- 代码任务：按改动风险运行相称的 `make test` / `make build` / `make app`；改 Cowork/AgentKernel 必须加测试（见 `docs/COWORK_PRINCIPLES.md` §8）。

## 常见问题

- **Linux 构建**：`IntatisSharedUI` 用 `#if canImport(SwiftUI)` 守卫，包应能在 Linux 无头构建。
- **Cowork 原则 vs 实现**：当前实现与 `docs/COWORK_PRINCIPLES.md` 原则有已知差距（见该文档 §6"当前已知 Cowork 问题"）。改动前先核对差距清单。
