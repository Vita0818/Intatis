# Intatis

当前版本：**v0.48**（build 48）
状态：pre-1.0；源码与构建可验证，v0.48 Developer ID 发行候选尚待完成最终公证验收。

Intatis 是 Apple-first、Swift-native 优先的本地 AI 工作区。macOS 提供 Chat、Code、
Cowork 三个产品面；iOS 是严格的 Chat 子集；CLI 提供 headless Code/Cowork 和外部 MCP
client。所有运行时能力围绕结构化 EventLog、共享 AgentKernel、显式工具注册和权限链
组织，而不是让 UI 直接调用模型或本地执行器。

当前文档入口见 [`docs/README.md`](docs/README.md)，版本规则见
[`docs/VERSIONING.md`](docs/VERSIONING.md)。历史 v0.1–v0.16 里程碑不代表当前产品版本。

## 当前产品面

### macOS

- Chat：OpenAI-compatible streaming、provider/model/variant 配置、透明 hosted web search、
  citations、会话历史、多模态产物和本地诊断导出。
- Code：单 workspace agent、文件/patch/Git、managed terminal、Skills、MCP、文档/媒体、
  浏览器和模型驱动 Knowledge 工具；所有工具均经过 CapabilityLease、WorkspaceLease、
  PathConfinement 与权限链。
- Cowork：多 agent roster、FIFO scheduler、WorkTask/Goal、MessageBus/Mediator、per-agent
  exact inference binding、独立 permission reviewer 和 goal verifier 控制面。
- 设置：provider catalog、Intatis JSON/JSONC 配置、MCP、renderer fallback、第三方声明，
  以及只在本机生成且不上传的脱敏诊断 ZIP。

macOS 唯一发行 target 是 `IntatisMac`，通过 Developer ID、Apple notarization 和直接下载
分发。`IntatisMacAppStore` 是未删除的 legacy target，不属于产品或 release gate。

### iOS

iOS 只链接 Core、Protocol、Providers、Conversation、Artifacts、Multimodal 和 SharedUI。
它支持 Chat、provider 配置导入、会话历史、托管搜索、citations 和图片生成，但不链接
Tools、Permission、AgentKernel、Cowork、MCP 或本地 workspace/shell。

### CLI

`intatis` 支持 Chat/Code/Cowork REPL、managed execution、Skills、per-agent inference
profiles 和外部 MCP client。macOS/Linux 平台能力与 sandbox/guard 可用性按 host fail closed。

## 核心不变量

- `EventLog` JSONL 是 session canonical truth；projection 和 `session.json` 都可重建。
- Chat 无工具；Code/Cowork 的每个工具调用必须先经过 ToolRegistry、lease 和三层权限门。
- Cowork 不递归同步调用 `AgentLoop`；通信、委派和调度通过 mailbox/scheduler/event flow。
- secret 只从受控 credential reference 懒加载，不进入 EventLog、诊断包或仓库文档。
- iOS 是结构性子集，不靠运行时开关隐藏本地 agent 能力。
- 第三方源码和依赖必须固定 provenance、许可证并更新 `NOTICE.md`。

详细合同见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 和
[`docs/DO_NOT_BREAK.md`](docs/DO_NOT_BREAK.md)。

## 仓库结构

```text
Apps/                 macOS、iOS 与 CLI 入口
Packages/             14 个公共库、内部 C/guard target 与测试
Vendor/               经审计并固定的第三方派生源码
ThirdPartyNotices/    许可证、来源与资源清单
Tests/                MCP conformance 与独立 parity fixtures
docs/                 当前规范和已标记的历史设计文档
scripts/              构建、验证、诊断和发行脚本
project.yml           XcodeGen 及产品版本唯一事实源
Package.swift         SwiftPM 产品、target 与测试图
```

精确 target 和入口见 [`docs/PROJECT_MAP.md`](docs/PROJECT_MAP.md)。

## 开发与验证

要求 Xcode 27 / Swift 6.x、XcodeGen，以及当前依赖可用。常用命令：

```sh
scripts/check-version-consistency.sh
swift test
xcodegen generate

xcodebuild -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

当前测试状态和环境限制以 [`docs/TESTING.md`](docs/TESTING.md) 为准，不以 README 中的
历史测试数量判断 release readiness。

## macOS 直接分发

正式发行需要本机 Keychain 中有效的 `Developer ID Application` identity，以及用户自行
保存的 `notarytool` profile：

```sh
INTATIS_NOTARY_PROFILE=<profile-name> scripts/package-macos-release.sh
```

如果 GitHub 需要代理/VPN、Apple notarization 又需要直连，使用两阶段模式：

```sh
INTATIS_PAUSE_BEFORE_NOTARIZATION=1 \
INTATIS_NOTARY_PROFILE=<profile-name> \
  scripts/package-macos-release.sh
```

保持代理/VPN 开启完成依赖解析、构建和签名；脚本明确提示后保持终端打开，关闭代理/VPN
再按 Return。它会先验证 Apple 可达性，失败时原地等待重试，不重新构建。上传进度和
submission ID 会直接显示；Apple 处理默认等待 30 分钟，仍为 `In Progress` 时保留签名
产物并打印 `INTATIS_RESUME_RELEASE_DIR` 恢复命令。恢复同一 submission，不要重复上传。

该脚本只有在 universal Release、Hardened Runtime、Developer ID 签名、App/DMG 公证、
staple、codesign 和 Gatekeeper assessment 全部通过后，才向 `dist/` 输出 ZIP、DMG 与
SHA-256 清单。不要把证书私钥、Apple 密码或 app-specific password 写入仓库或对话。

## 配置与数据

- macOS/CLI 高级配置读取 `INTATIS_CONFIG`、Intatis-owned JSON/JSONC 路径及兼容 fallback；
  不默认读取 OpenCode app 配置。
- Cowork 自动权限审查使用顶层 `permission_reviewer_model` 固定独立模型，不新增设置 UI，也不跟随
  当前主 Agent、会话默认模型或后续 rebind。字段缺失时只继承该 JSON 文档的顶层 `model`；显式填写
  但无法解析、顶层兼容来源不可用或整份已选配置损坏/不可读时 fail closed。
- Code/Cowork 的 `generate_image` 与 `edit_image` 共用顶层 `image_model` 宿主路由；主 agent
  只提交任务参数，不选择 provider/model。`edit_image` 接收工作区内的 `imagePath`、编辑 prompt
  和新的 `.png` `outputPath`。未配置时明确失败，不再暗中回退到固定模型。
- macOS Chat/Code/Cowork 与 iOS Chat 的输入栏语音按钮共用顶层 `transcription_model` 宿主路由；
  再次点击会停止录音并转写，结果只追加到当前可编辑草稿，不会自动发送。未配置时在本地明确
  提示，不会回退到当前 Chat 模型，也不会为此增加另一套设置页面。
- session 数据默认位于用户 App Support 下，每个 session 使用 append-only EventLog。
- browser profile、workspace artifact、credential 和 bookmark 不应提交到 Git，也不会进入
  本地诊断 ZIP。
- 日志导出当前不做远程上传；Apple notarization 仅在用户显式运行发行脚本时发生。

最小配置示例（图片、语音和 Knowledge provider 也可与 Chat provider 相同）：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "chat/chat-model",
  "permission_reviewer_model": "chat/reviewer-model",
  "image_model": "images/gpt-image-1",
  "transcription_model": "speech/whisper-1",
  "embedding_model": "knowledge/BAAI/bge-m3",
  "reranker_model": "knowledge/BAAI/bge-reranker-v2-m3",
  "provider": {
    "chat": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://chat.example.com/v1",
        "apiKey": "{env:CHAT_API_KEY}"
      },
      "models": {
        "chat-model": { "name": "Chat Model" },
        "reviewer-model": { "name": "Permission Reviewer" }
      }
    },
    "images": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://images.example.com/v1",
        "apiKey": "{env:IMAGE_API_KEY}"
      },
      "models": {}
    },
    "speech": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://speech.example.com/v1",
        "apiKey": "{env:SPEECH_API_KEY}"
      },
      "models": {}
    },
    "knowledge": {
      "npm": "intatis:siliconflow-v1",
      "options": {
        "baseURL": "https://your-knowledge-provider.example/v1",
        "apiKey": "{env:KNOWLEDGE_API_KEY}"
      },
      "models": {}
    }
  }
}
```

`permission_reviewer_model` 是 Intatis 的顶层授权控制面字段，格式为
`<provider>/<model-id>`，并引用 provider `models` 中已配置的 base profile。Intatis 在启动/恢复
Cowork runtime 时冻结该 exact binding；每次审查仍从这个 binding fresh-resolve provider wrapper。
改变 Chat/Cowork 模型菜单、session default 或 `@main` binding 都不会重定向审查者。该字段省略时，
仅为旧配置兼容而一次性采用同一 JSON 文档的顶层 `model`；显式空值、错误类型、未知 provider/model
或不可解析引用不会回退主模型；已选配置文件本身无法读取/解析时，普通 provider 可继续沿用既有缓存，
但权限审查保持不可用。

`image_model` 是 Intatis 的顶层扩展字段，格式为 `<provider>/<model-id>`。专用图片 provider
可保持空 `models`，因此不会混入 Chat/Code/Cowork 的推理模型菜单；当前 backend 要求该 route
兼容 `POST <baseURL>/images/generations` 与 multipart `POST <baseURL>/images/edits`，并返回
`data[].b64_json`。`edit_image` 当前支持单张 PNG/JPEG/WebP 输入（最多 50 MiB）并写出新的 PNG；
尚不支持 mask、多参考图或原地覆盖输入图。

`transcription_model` 同样是 Intatis 的顶层扩展字段，格式为 `<provider>/<model-id>`。专用语音
provider 可保持空 `models`，不会混入推理模型菜单；输入栏按 Flotis 的单模型 recorded-file runtime
录制 WAV/16 kHz/mono。compatible provider 使用 multipart，exact OpenRouter adapter 使用 JSON-base64
`input_audio`，两者都调用 `POST <baseURL>/audio/transcriptions`。录音和 upload body 使用有界、
owner-only 的临时文件，转写完成、失败或取消后即清理；用户按下 Send 前，音频和转写草稿都不会写入
EventLog 或 ArtifactStore。该接入不包含多模型对比，也没有新增设置页。

`embedding_model` 与 `reranker_model` 是 Knowledge 的两个独立必填 route，均只接受
`<provider>/<model-id>`；缺少任意一个时，Code/Cowork 不会获得 `build_knowledge` 和
`search_knowledge`。上例中的 URL 和模型 ID 是需要替换的配置值；`intatis:siliconflow-v1`
表示该 provider 同时使用 OpenAI-compatible `POST <baseURL>/embeddings` 和显式
`POST <baseURL>/rerank`。若 reranker 使用 Cohere v2，应为它建立独立 provider 并将 `npm` 写为
`intatis:cohere-v2`。Knowledge-only provider 的 `models` 可保持空对象，不会进入普通推理模型菜单；
若使用没有内置维度定义的 embedding 模型，则必须在对应 model 的 `options.dimensions` 中显式声明
正整数维度。若配置使用 `enabled_providers`，也必须把 Knowledge route 的 provider ID 加入其中。
Knowledge 工具仅接入 macOS/CLI 的 Code 与 Cowork，不进入 Chat 或 iOS。
用户无需学习挂载命令或新增管理页面：可以用自然语言要求 Agent 读取当前 workspace 的文本、PDF
或其它文档，整理为有来源的 OKF draft，并把库建立在 workspace 内或用户点名并精确授权的外部目录。
成功 build/query 会分别使用这里配置的 embedding route；每次成功 search 还必须实际使用这里配置的
semantic reranker，并要求最终回答引用本轮返回的 exact evidence ID。

使用同一个 OpenRouter provider 的已验收配置片段如下。即使 provider 默认仍用于普通
OpenAI-compatible Chat，这两个 model 也应以 model-level `@openrouter/ai-sdk-provider` 冻结 Knowledge
协议；顶层 role 引用的 exact model 会保留 adapter/options，但不会进入 Chat/Cowork 推理模型菜单。

```json
{
  "embedding_model": "OpenRouter/google/gemini-embedding-2",
  "reranker_model": "OpenRouter/cohere/rerank-4-pro",
  "provider": {
    "OpenRouter": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://openrouter.ai/api/v1",
        "apiKey": "{env:OPENROUTER_API_KEY}"
      },
      "models": {
        "google/gemini-embedding-2": {
          "name": "Gemini Embedding 2",
          "provider": { "npm": "@openrouter/ai-sdk-provider" },
          "options": { "dimensions": 1536 }
        },
        "cohere/rerank-4-pro": {
          "name": "Cohere Rerank 4 Pro",
          "provider": { "npm": "@openrouter/ai-sdk-provider" }
        }
      }
    }
  }
}
```

## 许可证

Intatis 自有代码和第三方采用状态见 [`NOTICE.md`](NOTICE.md)、
[`ThirdPartyNotices/`](ThirdPartyNotices/) 与
[`docs/OPEN_SOURCE_REUSE.md`](docs/OPEN_SOURCE_REUSE.md)。
