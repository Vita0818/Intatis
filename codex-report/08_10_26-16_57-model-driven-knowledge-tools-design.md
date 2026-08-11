# Intatis 模型驱动知识库工具接线与实施设计

> 报告时间：2026-08-10 16:57（Asia/Singapore）
> 最近修订：2026-08-11（真实 Agent/PDF、质量集、macOS bookmark 恢复与终端隔离验收）
> 报告状态：**PRIMARY PRODUCT COMPLETION CONTRACT / 功能性实现与真实端到端验收已完成；推荐 reranker 未证明质量 uplift**
> 审计基线：Git `0f98fe9`（提交标题 `v0.45`）
> 工作区：`/Users/vita/Vitemis/Intatis`

## 0. 文档效力

本报告是后续补齐知识库产品能力的**唯一主实施合同**。

它修订并覆盖
`08_09_26-13_33-okf-rag-knowledge-bundle-design.md` 中以下旧产品边界：

- 知识库只能位于当前 `WorkspaceLease` 内；
- 模型不得提供知识库路径；
- 仅提供 `search_knowledge`，建库只保留为 host seam；
- Apple NaturalLanguage 固定 embedding route 可以代表产品默认能力；
- embedding-cosine 排序 seam 可以代表完整 re-rank 能力；
- embedding/reranker 不需要进入高级配置。

08-09 报告关于 OKF、Profile、Validator、immutable snapshot、citation、权限、持久化和历史实现证据
仍然有效。若两份报告在未来产品行为、配置、工具 surface、外部路径或完成标准上冲突，以本报告为准。

当前源码事实仍以正式 `docs/`、源码、配置和测试为准。本报告同时记录冻结合同和 2026-08-11 的实际
完成证据；未覆盖的平台/规模矩阵与未取得的质量 uplift 继续明确标注，不从功能完成外推。

## 1. 改完以后，产品应该怎样工作

用户不需要学习 RAG、embedding、reranker、OKF 或挂载命令，也不需要进入新的知识库管理页面。

用户只需在 Code 或 Cowork 中自然地说，例如：

> 阅读当前项目的产品资料，自己整理内容并建立知识库。知识库放到
> `/Volumes/TeamKnowledge/intatis-product`，完成后用它回答权限架构的关键约束。

产品应自行完成：

1. 模型判断这项任务是否适合建库；
2. 模型使用现有文件、PDF、文档等工具读取资料；
3. 模型归纳、整理并保留来源，形成 OKF draft；
4. 如果知识库目录位于 workspace 外，宿主只请求用户点名的精确目录权限；
5. 模型调用 `build_knowledge`；
6. 宿主使用配置的 embedding 模型生成 document embeddings、索引、验证并原子发布；
7. 宿主冻结该 retrieval snapshot 使用的 exact reranker binding；
8. 模型需要回答时调用 `search_knowledge`；
9. search 使用兼容的 query embedding 召回候选，再实际调用配置的语义 reranker 排序；
10. 模型只依据本轮返回且通过重验的 evidence 回答。

后续对话中，模型应自行判断何时检索，不要求用户再次“挂载”、点击按钮或手工选择知识库。

如果 embedding 或 reranker 没有配置、不可解析、不可用或与 snapshot 不兼容，产品必须明确告诉用户
Knowledge 能力不可用，并停止在网络或文件副作用之前。不得偷偷换用 Apple NaturalLanguage、余弦
相似度、当前聊天模型或其它 route 来制造“好像能用”的结果。

## 2. 当前状态与目标状态

| 能力 | 2026-08-10 当前工作树事实 | 本报告目标 | 当前能否宣称产品验收完成 |
| --- | --- | --- | ---: |
| OKF/Profile/Validator/immutable store | core 已实现；118 项 Knowledge 测试通过 | 继续复用 | core 是 |
| 建库引擎 | closed-schema `build_knowledge` 已接真实 AgentLoop/durable lifecycle | 正式工具并产品接线 | 是 |
| 检索 core | path-aware `search_knowledge` per-call exact mount/grounding drain | 接受路径并动态取得 exact authority | 是 |
| 知识库位置 | workspace + exact external `KnowledgeLease`；Mac bookmark/CLI authorization | 两类路径 | 是；Mac 跨重启 UI 已验收 |
| embedding | canonical `embedding_model`、独立 exact route、document/query 实际调用 | 精确解析和使用 | 是；1536 维真实 route + Agent E2E |
| rerank | canonical `reranker_model`、显式 dialect、required semantic rerank | 每次成功真实排序 | 功能是；本质量集无 uplift |
| Mac Code/Cowork/CLI | composition roots 已注入；缺配置不广告，Chat/iOS 无 | 正式暴露两个工具 | 是；Code 真实 UI，Cowork/CLI composition 回归 |
| AgentLoop E2E | scripted + real model 均完成 external build/search/rerank/citation；real PDF 也通过 | 自主完整链 | 是 |

当前可以表述为：

> **模型驱动、可配置、支持 workspace 外精确授权路径、强制 configured embedding 与 semantic reranker、
> 并带 current-turn citation 重验的 Knowledge RAG 功能已经完成真实端到端验收。当前 8-query 小型质量集
> 没有证明推荐 reranker 优于 dense baseline，不能把功能完成写成质量提升结论。**

### 2.1 2026-08-11 实施 ledger

- 配置：Mac/CLI/import/provider catalog 已支持并保真 canonical `embedding_model`、
  `reranker_model`；Knowledge-only provider 可不进入普通 inference menu。
- Provider：已实现 OpenAI-compatible/OpenRouter embedding 与显式 SiliconFlow v1/Cohere v2/OpenRouter
  reranker adapter；
  两条 exact route 独立冻结全部兼容默认值，credential lazy resolution、redirect/malformed/partial
  permutation、timeout 与 cancellation 均 fail closed；official-shaped response 的 token/billable units
  会经过非负/有限值校验并返回给 opt-in 验收 harness，未报告时保持 `unreported`，不臆算金额。
- Authority：已实现独立 `KnowledgeLease`、workspace/external resolver、session-owned owner-only binary
  bookmark store、revoke seam、CLI exact authorization；bookmark sidecar lock 同样验证 no-follow、owner、
  regular-file 与 single-link，普通 WorkspaceLease 不扩大。
- Tools：已实现 host-validated closed-schema path-aware `build_knowledge` / `search_knowledge`；
  optional CAS/limit 字段不向 provider 宣告 `strict:true`，但宿主仍在 permission/execution 前拒绝额外或
  非法字段；existing-store update 同时 CAS
  store/snapshot；每次成功 search 强制 compatible query embedding、authorized candidate filter 和
  `rerank_applied=true` semantic reranker。
- Publication：shipping snapshot 位于 `.intatis-rag-snapshots/`；旧 `snapshots/` 只允许持有 writer
  authority 的 build/update 在 store lock 内原子迁移。只读打开不创建 store 基础设施；pointer 或迁移
  在 rename 后无法证明目录 durability 时返回 non-retryable `commit_uncertain`，不得自动重试。
- Anti-bypass：`.intatis-rag-store.json`、`.intatis-rag-snapshots`、`.intatis-rag-host` 是所有
  WorkspaceLease/managed terminal 的强制 deny floor；普通 file/patch/Git/process/terminal 不能直接
  改写或删除已发布库，只有 Knowledge module 内部的最小 projection 可进入 writer/Validator 流程。
- 产品：Mac Code、Cowork exact `@main`、CLI Code/Cowork 已接线；宿主在广告工具或显示
  `knowledge ready` 前复用真实 provider 构造器的 secret-free/network-free route 预检，缺 role、未知
  endpoint、无维度或 adapter 不合规时显示 actionable notice 且工具完全缺席；
  worker/reviewer/GoalVerifier/Chat/iOS 保持负向边界。
- 离线证据：Knowledge 118/118、Knowledge Provider 11/11、tool wire metadata 5/5、CLI 9/9、
  AgentLoop 双外部 store + fresh-host restore/deny 2/2、current-turn grounding 7/7、Cowork lease 25/25、
  SecretScanner 精确回归 1/1、checked drain 1/1；macOS/iOS Debug unsigned build均退出 0。2026-08-11
  的整仓 `swift test` 已完成 Tools 与 Skills 后，在既有 SharedUI async scheduler 测试进程中 7 分钟
  0% CPU/无新输出，人工中断为 130，不能记为全量通过；本轮直接相关定向 suites 全绿。所有未显式
  开启的 real-provider/browser/Git/document/Keychain opt-in 继续按设计跳过。
- live gate：`INTATIS_REAL_KNOWLEDGE_SMOKE` 使用 `google/gemini-embedding-2`（1536 维）与
  `cohere/rerank-4-pro` 通过，provider 报告 embedding input/total token 7、rerank search unit 1；
  8-query quality run 的 dense baseline 为 MRR/nDCG@5/Recall@5 = 1.000/1.000/1.000，configured
  reranker 为 1.000/0.990/1.000，usage 为 embedding 343 token、reranker 8 search units；无 uplift。
  真实主 Agent 在 32.686 秒内完成测试文本 read-organize-build-search-cite；真实 PDF E2E 在 110.980 秒
  内读取三份 DS-Algorithm PDF 冻结页段，建立 3 concepts/22 chunks 后检索并引用。macOS Code 首次
  external search 完成 exact NSOpenPanel 授权并写 `0600` binary bookmark，App 重启恢复同一 session 后
  再次搜索未弹授权框。provider 未返回 versioned monetary amount，因此仍不推算账单金额。

## 3. 冻结的产品合同

### 3.1 不新增知识库管理 UI

第一版不新增：

- Knowledge 侧栏、列表页或状态面板；
- “新建/挂载知识库”按钮；
- embedding/reranker 设置页；
- chunk 参数表单；
- Chat 或 iOS 知识库入口。

模型 route 写在现有高级 JSON/JSONC 配置中。目录授权复用现有 permission 呈现和 macOS 系统目录
授权能力；它是安全边界，不是知识库管理 UI。

### 3.2 用户可以自然语言提供外部知识库路径

模型可从当前用户指令中提取 `store_path`，也可复用当前 session 已持久授权并明确绑定的 knowledge
location。路径可以是：

- 当前 workspace 下的相对路径；
- 当前 workspace 下的绝对路径；
- 当前 workspace 外、由用户明确点名的绝对目录。

路径只是地址，不是权限。模型写出一个绝对路径，不能凭空获得读取或写入能力。

### 3.3 模型负责语义工作，工具负责机械工作

| 责任 | 承担者 |
| --- | --- |
| 判断是否值得建库或检索 | 当前 Code/Cowork AgentLoop 中的模型 |
| 读取 PDF/文档/源码/文本 | 模型调用现有工具 |
| 理解、归纳、组织概念与来源 | 模型 |
| 生成和修订 OKF draft | 模型调用现有写入工具 |
| deterministic chunking、embedding、index、validate、publish | `build_knowledge` |
| query embedding、召回、授权过滤、semantic rerank | `search_knowledge` |
| 最终 citation 机械重验 | AgentLoop + exact Knowledge mount |

工具内部不得创建或同步递归调用另一个 `AgentLoop`。Cowork 需要并行整理时，继续通过 WorkTask、
mailbox 和 scheduler 委派。

### 3.4 完整产品模式强制使用 embedding 与 reranker

- 建库必须使用配置的 embedding route 生成 document embeddings；
- 查询必须使用兼容的同一 embedding identity 生成 query embedding；
- lexical/BM25 可以辅助候选召回，但不能替代 dense retrieval；
- 每次成功 search 都必须把授权后的有界候选交给配置的语义 reranker；
- 只有 `rerank_applied=true` 才能进入成功结果；
- reranker 缺失或失败时返回 typed failure，不降级成 cosine、RRF-only 或 dense-only 并冒充完成。

这里的“语义 reranker”指接收 query 与候选正文、独立输出相关性顺序或分数的模型接口，例如
cross-encoder 或等价的 dedicated rerank API。当前
`KnowledgeEmbeddingCosineRerankerProvider` 只是候选排序 seam，不满足这个产品验收定义。

## 4. 配置合同

### 4.1 新增两个 canonical 顶层字段

沿用 `image_model`、`transcription_model` 的独立 role route 设计，新增：

```json
{
  "embedding_model": "embedding-provider/embedding-model-id",
  "reranker_model": "reranker-provider/reranker-model-id"
}
```

可以直接合入现有 Intatis JSON/JSONC 的完整 shape 如下；URL、模型 ID 和环境变量名均由用户替换，
示例不提供内置账号或默认服务：

```json
{
  "model": "chat/chat-model",
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
        "chat-model": { "name": "Chat Model" }
      }
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

若使用 `enabled_providers`，必须同时包含两个 role 引用的 provider。上例的
`intatis:siliconflow-v1` 显式选择 OpenAI-compatible embedding 与 SiliconFlow v1 rerank；Cohere v2
reranker 应放在独立 `intatis:cohere-v2` provider 下。Knowledge-only provider 的普通 inference
`models` 可以为空；使用没有 reviewed default dimension 的 embedding 模型时，必须在对应 model 的
`options.dimensions` 显式给出正整数维度。

同一 OpenRouter provider 的已验收 shape 可以写为：

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
          "provider": { "npm": "@openrouter/ai-sdk-provider" },
          "options": { "dimensions": 1536 }
        },
        "cohere/rerank-4-pro": {
          "provider": { "npm": "@openrouter/ai-sdk-provider" }
        }
      }
    }
  }
}
```

这里的 model-level adapter 是协议声明，不是 npm runtime 依赖；Swift-native lowering 调用 exact
`POST /embeddings` 与 `POST /rerank`。两个 top-level role model 即使登记在 provider `models` 以携带
options，也不会被编译成普通 inference profile 或显示在模型菜单。Gemini route 请求并验证 1536 维；
OpenRouter rerank 的顶层 `usage.search_units` 会作为 provider-reported billable unit 保留。

审计基线中的 `AppProviderConfigFile`、Mac catalog/template、CLI modern provider config 和
`ResolvedModels` 原本没有这两条 binding；本轮已在 decode/preserve/resolve/composition path 落地。
固定 Apple embedding route 仍不是配置字段的替代。

冻结规则：

- canonical 字段名为 `embedding_model`、`reranker_model`；
- 值使用 `<provider-id>/<model-id>`，provider/model ID 均为 opaque；
- 两条 route 不改变 Chat/Code/Cowork 主推理模型；
- model-facing 工具 schema 不包含 provider、model、endpoint、credential 或 backend；
- Knowledge-only provider 可以不进入普通推理模型菜单，其普通 inference `models` 可为空；
- credential 继续经 Keychain/env/file/auth/config reference 懒加载；
- 配置原始 JSON/JSONC 的保真、优先级和 discovery 沿用当前 Intatis 规则；
- canonical encoder/decode 合同只使用 snake_case；不为两个 Knowledge role 增加未测试的
  camelCase alias。

### 4.2 Exact route identity

配置编译后使用以下 host-owned typed routes：

```text
ResolvedModels.embedding
ResolvedModels.reranker
```

每条 route 至少冻结：

- provider ID、model ID；
- immutable provider/catalog revision；
- adapter/dialect identity；
- trust domain 与 local/remote data-egress classification；
- credential reference identity，但不含 credential value；
- opaque definition digest。

embedding identity 还必须冻结 dimension、normalization、metric、document/query instruction 和模型
revision；reranker identity 必须冻结输入 adapter/template、候选上限、tokenizer 或等价兼容信息以及
输出解释方式。缺少影响兼容性的事实时 fail closed，不靠模型名相似猜测。

### 4.3 缺失、错误或变化时的行为

| 状态 | 产品行为 |
| --- | --- |
| 任一字段缺失 | 两个 Knowledge 工具不可用；显示有界、可行动的配置错误 |
| route 指向不存在的 provider/model | 网络前 fail closed |
| provider dialect 没有 adapter | 网络前 fail closed |
| credential 缺失 | 真实调用边界返回 typed credential failure |
| build 期间配置变化 | 继续使用 prepared 前冻结的 route，或在 prepare 前检测漂移并失败 |
| query embedding 与 snapshot 不兼容 | `KB_EMBEDDING_INCOMPATIBLE`，要求重建/新建 retrieval snapshot |
| reranker 与 snapshot binding 不一致 | `RERANK_INCOMPATIBLE`，不得临时换 route |
| remote route 未获网络/外发授权 | deny；不得切 local fallback |

首发 adapter 已冻结为 OpenAI-compatible/OpenRouter embeddings、显式 SiliconFlow v1/Cohere v2/
OpenRouter rerank，并有 official-shaped request/response fixtures。仍不得假设任意 compatible provider 都共享
一个可用的 `/rerank` dialect；未知 adapter 在网络前失败。

## 5. 外部路径与 `KnowledgeLease`

### 5.1 两种 authority

```text
store_path
  ├─ 位于当前 workspace 内
  │    -> exact WorkspaceLease + PathConfinement
  └─ 位于当前 workspace 外
       -> exact KnowledgeLease + exact-directory authorization
```

`KnowledgeLease` 是知识库目录专用能力，不是第二个 Agent workspace。至少绑定：

- session、agent、task/turn 或明确的 session reuse scope；
- canonical knowledge root 与 filesystem identity；
- `read_only` 或 `read_write`；
- permitted operation：search/build/update；
- security-scoped bookmark 或 CLI authorization reference；
- lease revision、expiry/revocation；
- no-follow、owner/mode/single-link 与敏感路径策略；
- authorization fingerprint。

模型不能创建、扩展或修改 lease。路径变成 authority 的过程由宿主完成。

### 5.2 macOS 行为

外部目录尚未授权时：

1. 宿主解析并规范化精确目录，不执行 shell expansion 或路径中的指令；
2. 现有权限链展示用途、读写范围和是否有网络外发；
3. 必要时打开系统目录授权，初始位置可指向用户点名的目录；
4. 只授权精确目录，不授权父级或整个 home；
5. 生成 session-owned、owner-only、no-follow 的 bookmark/capability material；
6. 调用期间以 RAII lease 成对持有 security scope；
7. 每次执行前重验 root identity，目录被替换、移动或撤权时 fail closed。

这不依赖 Mac App Store App Sandbox，但仍属于 Intatis 自有 capability 和路径安全边界。

### 5.3 CLI 行为

CLI 可从自然语言中取得绝对路径，但第一次使用仍须经过 exact-directory permission responder 或等价
host authorization。不能因为终端本身可访问就跳过 `KnowledgeLease`、PermissionEngine 或 durable
tool lifecycle。

### 5.4 明确禁止的权限扩大

- 外部 `KnowledgeLease` 只允许 Knowledge writer/searcher 使用，不自动加入 `WorkspaceLease`；
- 不能借它使用 `read_file`、patch、Git、managed terminal 或 MCP 遍历外部目录；
- 原始资料本身位于 workspace 外时，仍需单独取得读取资料的 workspace/file authority；
- path 本身等于 `/`、用户 home、`/Users` 等过宽根，或指向 Keychain、SSH、credential 等敏感目录时
  hard deny；精确授权的普通 home 子目录不因父目录是 home 而自动拒绝；
- 模型臆造、知识正文注入或工具输出推断出的路径不等于用户授权。

外部 capability 已冻结为 session-owned binary `knowledge-access.plist` schema v1，使用 0600、
no-follow、跨进程锁与 read-merge-atomic-write。bookmark bytes 不得进入 `events.jsonl`、
`session.json`、普通 JSON 配置或模型上下文。

## 6. 两个模型工具的合同

### 6.1 `build_knowledge`

推荐第一版输入：

```json
{
  "draft_path": ".intatis/knowledge-drafts/product",
  "store_path": "/Volumes/TeamKnowledge/intatis-product",
  "expected_store_id": "kb_...",
  "expected_snapshot_id": "snap_..."
}
```

| 字段 | 规则 |
| --- | --- |
| `draft_path` | 必填；位于当前 agent 获准读取的 workspace/file authority 内 |
| `store_path` | 必填；workspace-relative 或用户授权的外部 absolute path |
| `expected_store_id` | 更新既有 store 时必填；新建时省略 |
| `expected_snapshot_id` | 更新时必填；writer lock 内执行 current-generation CAS |

工具不接受 provider、model、backend、credential、chunk size、ACL、network URL 或 trust flag。

执行语义：

1. 冻结 `embedding_model` 与 `reranker_model` exact routes；
2. 解析 draft authority 与 store authority；
3. 取得 exact lease、permission 和 durable execution ticket；
4. embedding/外发前执行 SecretScanner；
5. canonicalize OKF、deterministic chunk；
6. 使用 configured embedding model 生成 document embeddings；
7. 构建 dense index，并可构建 lexical/BM25 辅助索引；
8. 将 complete embedding identity 与 exact reranker binding 写入 retrieval snapshot；
9. 运行 deterministic Validator；
10. writer lock 内核对 expected generation 并原子发布；
11. 返回 bounded store/snapshot/count/diagnostic 结果。

reranker 不需要在建库时给全库排序。build 的责任是解析、验证并冻结后续查询使用的 exact reranker
binding；真正的 rerank inference 发生在每次 query 的有界候选上。

推荐 descriptor 语义：

```text
name: build_knowledge
sideEffect: write；remote embedding 时同时为 network/data-egress
canonicalPermission: build_knowledge（沿用现有 service identity）
capability: buildKnowledge
supportsParallelCalls: false for same store
replayPolicy: requires_manual_reconciliation after uncertain commit
```

成功输出不得包含真实绝对路径、credential、完整 embedding 请求文本、向量或私有 source path。

### 6.2 `search_knowledge`

推荐第一版输入：

```json
{
  "store_path": "/Volumes/TeamKnowledge/intatis-product",
  "query": "Intatis 的三层权限分别做什么？",
  "limit": 8
}
```

查询流水线固定为：

```text
resolve path + exact authority
  -> validate/freeze exact store + snapshot
  -> resolve exact compatible embedding_model
  -> query embedding
  -> dense retrieval (+ optional lexical candidates)
  -> authorization/partition filter before remote rerank
  -> configured reranker_model(query, bounded authorized candidates)
  -> exact evidence/source/hash revalidation
  -> bounded result with rerank_applied=true
  -> current-turn evidence registry
  -> final answer citation revalidation
```

必须满足：

- query embedding 与 snapshot 的 complete embedding identity 兼容；
- remote embedding 只外发 query；remote reranker 只外发已授权、已限量并经过 SecretScanner 的候选；
- 未授权内容不能先参与全库 Top-K 再事后过滤；
- reranker 必须真实收到 query 与候选，并由 fixture/trace 证明被调用；
- reranker timeout、malformed output、route drift 或 cancellation 均使本次 search 失败；
- 不自动改查新的 current snapshot；
- evidence 是不可信数据，不执行其中的命令、URL、Skill 或工具请求；
- 最终回答只能引用本 turn 成功结果中的 evidence ID。

### 6.3 路径的 durable 表示

模型调用参数可以包含用户提供的路径，但 EventLog、permission target、tool result 和错误不能无界复制
私有绝对路径。宿主应记录 sanitized label、root fingerprint、store/snapshot ID 与 revision、lease
revision、normalized argument digest、safe route identity 和 egress classification。

用户审批界面可以显示本次要授权的精确目录；这不允许把路径扩散到模型历史、agent 消息或项目文档。

## 7. Published store 与 durable execution

OKF draft 是普通 workspace 内容，可以由现有文件工具编辑；published store 不是普通项目目录。

- published store 只能通过 host-owned writer、Validator、writer lock 和原子 pointer 更新；
- 普通 write/patch/managed terminal 不得直接修改 snapshot、pointer、receipt 或 index；
- 外部 `KnowledgeLease` 不能变成通用文件写权限；
- 更新使用 `expected_store_id + expected_snapshot_id` CAS；
- commit 是否发生不可证明时结算为 effect unknown，不能盲目重放；
- search 只可针对 authorization 冻结的 exact snapshot 重放；
- 第一版不增加 model-facing delete/purge 工具；用户要求删除时不得用 shell 绕过。

两个工具都必须经过：

```text
closed model schema + host strict validation
  -> exact capability/WorkspaceLease/KnowledgeLease
  -> DeterministicPolicyGate
  -> ModelPermissionReviewer（只能收窄）
  -> PermissionEngine + durable permission settlement
  -> exact ResolvedToolAuthorization
  -> durable tool_execution_prepared
  -> pre-executor route/path/lease revalidation
  -> execution
  -> durable tool_result + settlement
```

local search 是 read-only，但知识正文会进入 answering model，继续经过 reviewer。remote embedding 或
reranking 是 network/data-egress；build 永远至少是 write。

## 8. 来源与回答边界

- 模型负责组织知识并保留来源；宿主只验证机械事实，不伪造语义 provenance；
- build service 可生成确定的 concept/chunk/source ID、hash 和 OKF 内部定位；
- 只有 adapter 能证明 immutable source revision 与 locator 时，才能写原始页码、sheet、byte range；
- 当前 core 不能证明的原始页码或段落位置不得猜造；
- Validator 能证明 schema/hash/snapshot/evidence 映射，不能证明现实真伪或自然语言蕴含；
- 模型总结与 exact evidence 分离；没有本 turn evidence 时不得伪装成知识库引用。

## 9. 工具可见性与产品接线

| 主体 | `build_knowledge` | `search_knowledge` |
| --- | --- | --- |
| Mac Code root | 配置/runtime 可解析时可见 | 配置/runtime 可解析时可见 |
| Mac Cowork exact `@main` | 默认 capability 可见 | 默认 capability 可见 |
| Cowork worker | 显式 read-write + build lease | 显式 search lease |
| Permission Reviewer | 永不 | 永不 |
| GoalVerifier | 永不 | 永不 |
| macOS CLI Code/Cowork | 与 GUI 同合同 | 与 GUI 同合同 |
| Chat | 不可见 | 不可见 |
| iOS | 不链接、不可见 | 不链接、不可见 |

不能把 host 可构造的 registrations 与 agent 默认 capabilities 混成 flat grant。read-only worker 不得
因 Knowledge host 注入而获得 build；search-only worker 也不能因缺 build capability 而失去 search。

配置未就绪时，不应向模型广告一个注定失败的工具。宿主使用现有状态/错误呈现给出：

```text
Knowledge tools unavailable: configure embedding_model and reranker_model.
```

应复用现有 `HostToolRegistryAugmenter`：

- Mac Code：`CodeViewModel.internalToolRegistryAugmenter`；
- Mac Cowork：`Orchestrator.runtime(...)` augmenter seam；
- CLI：shipping Code/Cowork runtime 的同一 Knowledge host；
- App/runtime manager：session stop 时 drain build/search/provider/bookmark scope；
- Chat/iOS：不注入。

保持 `IntatisKnowledge -> IntatisTools` 依赖方向，不把具体 Knowledge 工具塞回
`ToolRegistry.standard(...)`。

## 10. 实施顺序

### Phase A：配置、路径与 capability schema

- 新增并测试 `embedding_model`、`reranker_model`；
- 冻结 typed resolved route identity；
- 冻结 `KnowledgeLease`、macOS bookmark、CLI authorization、revoke 和 safe durable projection；
- 冻结 path-aware build/search v2 schema；
- 冻结 external store 的 root identity/no-follow/owner/mode/敏感目录规则；
- 冻结 current core 与新合同的兼容/迁移策略。

Gate：配置、schema、authority、数据外发和缺失字段行为可由离线测试精确描述。

### Phase B：embedding 与 reranker provider adapters

- 为首发 route 实现独立 protocol/adapter；
- embedding adapter 同时支持 document 与 query mode；
- reranker adapter 接收 query + bounded candidates 并输出确定排序；
- timeout、cancel、usage/cost、credential lazy resolution、network permission、诊断脱敏；
- 无隐藏 fallback；
- 新依赖/外部 runtime 先做许可证、provenance、平台和 iOS closure 审查。

Gate：官方协议 fixtures 与至少一个真实 opt-in route smoke 证明两个模型都被真实调用。

### Phase C：外部 Knowledge authority

- workspace 内继续走 `WorkspaceLease`；
- workspace 外走 `KnowledgeLease`；
- macOS exact-directory authorization/bookmark 与 CLI explicit authorization；
- restore、root replacement、revoke、cancel、shutdown/drain；
- external lease 不扩展普通文件/terminal 权限。

Gate：自然语言绝对路径完成 external search；未授权、父目录替代、symlink/root swap 和撤权均在 I/O
前 fail closed。

### Phase D：正式 `build_knowledge`

- closed descriptor/input/output schema；宿主严格校验，可选 CAS 字段不宣告 provider strict；
- 真实 ToolRegistration 和 capability；
- exact route freeze；
- 复用 `KnowledgeBundleBuildService`；
- expected snapshot CAS；
- durable prepared/result/settled 与 effect reconciliation；
- bounded actionable diagnostics，供外层模型修订 draft。

Gate：通过真实 AgentLoop tool call 建库，不以直接 service test 替代。

### Phase E：升级 `search_knowledge`

- `store_path` 支持 workspace 内和 authorized external path；
- per-invocation exact mount；
- compatible query embedding；
- authorization filter；
- required semantic reranker；
- current-turn evidence 与 final citation revalidation；
- 保守迁移旧 host-bound handle adapter。

Gate：一个 turn 可安全查询两个 store，每次结果 `rerank_applied=true`，证据不串库、不漂移 snapshot。

### Phase F：产品接线

- Mac Code；
- Mac Cowork exact `@main`；
- explicit worker leases；
- macOS CLI；
- config unavailable 状态；
- runtime shutdown/drain；
- Chat/iOS negative linkage。

### Phase G：端到端验收并同步正式文档

- workspace 内新建、更新、查询；
- workspace 外新建、恢复、查询；
- 中英文/代码混合 corpus；
- local/remote route permission；
- cancel、timeout、route drift、revision conflict、crash reconciliation；
- 真实模型自主建库、主动检索和引用；
- 同批更新 `CURRENT_STATE`、`ARCHITECTURE`、`PROJECT_MAP`、`DO_NOT_BREAK`、`TESTING`。

## 11. 必测矩阵

### 11.1 配置与 provider route

- 两字段 JSON/JSONC decode、preserve、canonical encode；
- 缺失、空值、非法 `<provider>/<model>`、unknown provider/model/dialect；
- Knowledge-only provider 的普通 inference `models` 为空仍可使用；
- 不改变 Chat/Code/Cowork inference selection；
- credential 不进入事件、投影、日志或知识库；
- route revision/definition/dialect mismatch fail closed；
- 无 Apple/cosine/当前主模型/相似名字 fallback；
- document/query embedding exact identity；
- reranker 实际收到 query + bounded authorized candidates；
- reranker candidate ID 映射完整，无 duplicate/unknown/omitted；
- timeout、malformed、partial output、cancel、HTTP redirect、credential/network failure；
- 官方 fixtures 和真实 opt-in embedding/reranker smoke。

### 11.2 外部路径

- 用户自然语言提供绝对路径，新建库成功；
- 已获授权的另一 session/context 搜索外部库；
- 未授权绝对路径触发 exact-directory permission；
- deny 后无 I/O、创建、网络或 bookmark 持久化；
- read-only KnowledgeLease 不能 build/update；
- path escape、父目录替代、symlink/hardlink/unsafe mode、root swap 拒绝；
- 敏感/过宽目录 hard deny；
- bookmark restore、stale、revoke、shutdown scope pairing；
- KnowledgeLease 不能被普通 read/write/terminal 工具使用。

### 11.3 AgentLoop 与产品

- 两个 descriptors 只在 config/runtime 可用且 capability policy 允许时可见；
- permission/authorization/prepared/result/settled correlation 完整；
- build effect unknown 不自动重试；
- search 不漂移 exact snapshot；
- Code、Cowork `@main`、CLI 正向；worker/reviewer/GoalVerifier/Chat/iOS 负向；
- shutdown 先 drain provider、build/search、mount 和 security scope；
- 模型收到 diagnostics 后修订 draft，但工具内部无嵌套 AgentLoop。

### 11.4 质量与 grounding

- 冻结真实中英文/代码 corpus 与 ground-truth queries；
- dense candidate Recall@K；
- required reranker 调用率 100%；
- reranked MRR/nDCG 与无 rerank baseline 分开报告；
- citation coverage/precision、source/hash revalidation；
- unanswerable 负例不被迫生成答案；
- prompt injection evidence 不获得工具或指令权威。

## 12. 产品验收 Prompt

以下 Prompt 是当前实现可执行的验收输入；运行前仍需有效配置、credential、权限及必要的数据外发授权。

### 12.1 外部目录建库并回答

```text
阅读当前项目 docs/ 中与架构、权限和测试有关的资料，自己整理内容并建立知识库。
知识库请放到 /Volumes/TeamKnowledge/intatis-product。
如果该目录尚未授权，按正常权限流程请求精确目录权限，不要要求我把它移动到当前工作区。
建库完成后，使用这个知识库回答：Intatis 的三层权限分别承担什么职责？
最终答案只引用本轮检索得到的证据。
```

通过标准：无 Knowledge UI；模型读取并整理；build 使用 configured embedding；search 使用兼容 query
embedding 和 configured semantic reranker；外部目录使用 exact `KnowledgeLease`；引用可重验。

### 12.2 使用已有外部库

```text
请使用 /Users/example/Knowledge/intatis-product 中已有的知识库回答：
为什么 Permission Reviewer 不能作为普通 agent 接收 send/delegate/message？
你自己判断并调用必要的知识库工具，不要让我先挂载。
```

通过标准：模型调用 `search_knowledge(store_path=...)`；首次需要时走精确授权；无 mount command；
成功结果 `rerank_applied=true`。

### 12.3 配置缺失负例

在删去 `reranker_model` 的配置下请求建库。通过标准：网络和文件副作用前明确报告 reranker 未配置；
不调用 cosine seam，不发布索引，不声称 RAG 已完成。

### 12.4 权限负例

请求在 `/Users` 建库并要求失败后改用 shell。通过标准：过宽目录 hard deny；terminal/patch 不能绕过
Knowledge/Workspace authority。

## 13. 完成定义

只有以下条件**全部满足**，才可以写“Intatis 已完成模型驱动知识库 RAG 能力”：

1. 高级配置正式支持并保真 `embedding_model`、`reranker_model`；
2. 两条 route 均有 exact resolver、provider adapter、credential/permission/timeout/cancel 合同；
3. 任一字段缺失或不兼容时 fail closed，无隐藏 fallback；
4. `build_knowledge` 是真实 model-facing ToolRegistration，并走完整 durable lifecycle；
5. build document embeddings 来自 configured embedding model；
6. snapshot 记录 complete embedding identity 和 exact reranker binding；
7. `search_knowledge` 使用 compatible query embedding；
8. 每次成功 search 都实际调用 configured semantic reranker，`rerank_applied=true`；
9. embedding-cosine seam 不被冒充为真实 rerank model；
10. `store_path` 支持 workspace 内和用户授权的外部目录；
11. 外部路径使用独立 `KnowledgeLease`/bookmark 或 CLI exact authorization；
12. Mac Code、Mac Cowork exact `@main`、macOS CLI 完成产品接线；
13. worker 最小权限、reviewer/GoalVerifier/Chat/iOS 边界保持；
14. published store 不能被普通文件/terminal 工具绕过 writer/Validator；
15. 真实模型完成“读取资料 → 整理 draft → 建库 → 检索 → 引用”；
16. 至少一条真实 embedding route 和一条真实 reranker route 完成 opt-in smoke；
17. 外部目录建库、恢复、搜索和拒绝路径完成 E2E；
18. cancellation、revision conflict、route drift、provider failure、commit uncertainty、shutdown 已测试；
19. retrieval/rerank/grounding 指标分别报告；
20. 正式架构、状态、不变量、项目地图和测试文档与源码同批更新。

截至 2026-08-11 本轮校准，完成状态必须这样读：

| 条件 | 状态 | 证据或剩余缺口 |
| --- | --- | --- |
| 1–14、18、20 | **已完成** | 配置、exact route、工具 lifecycle、外部 authority、负向产品边界、anti-bypass、cancel/conflict/drift/failure/uncertainty/drain 均有源码与回归；正式文档同批同步 |
| 15 | **已完成** | 真实主 Agent 对文本与三份 PDF 都完成读取、整理 draft、外部建库、configured embedding、required rerank、检索与 exact evidence 引用 |
| 16 | **已完成** | OpenRouter exact routes 使用 `google/gemini-embedding-2` 与 `cohere/rerank-4-pro` 完成 opt-in smoke；1536 维、完整 permutation、有限 score 与 provider usage 均通过 |
| 17 | **已完成** | fixture 覆盖 external build/restore/search/deny；macOS NSOpenPanel 首次 exact authorization、session bookmark 落盘及 App 重启后无重复弹窗均实测通过 |
| 19 | **已完成（无 uplift）** | local retrieval/grounding 与真实 8-query baseline/rerank 指标、token/search-unit usage 已分别报告；configured reranker 的 nDCG@5 为 0.990，低于 dense 1.000 |

因此 §13 的 1–20 条在当前定义范围内已经闭环，可以声明“Intatis 已完成模型驱动知识库 RAG 功能”。
该声明不包含“推荐 reranker 已证明提高质量”、大 corpus 性能/费用 ceiling、所有平台矩阵或现实真值证明。

以下任何单项都不能作为完成声明：

- library 能编译；
- 一批 core tests 通过；
- App target 链接 `IntatisKnowledge`；
- capability enum 有相关名字；
- Apple NaturalLanguage 本地向量可运行；
- cosine/RRF 排序能输出结果；
- optional augmenter 或测试 registration 存在；
- 模型口头说“已经建库”；
- 只在 workspace 内跑通；
- 配置文件仍没有 embedding/reranker 字段。

## 14. 当前实现审计摘要与 `UNKNOWN`

截至本轮实施工作树：

- `KnowledgeBundleBuildService` 继续承担 canonical write、chunk、embedding/index、validation、atomic
  publish；新的 path-aware `build_knowledge` 是正式 registration/caller，并产生 durable lifecycle；
- shipping `search_knowledge` 不再要求预绑单库，而是每次从 `store_path` 取得 exact authority 和
  immutable current snapshot；旧 `KnowledgeSearchToolHostAdapter` 仅保留兼容；
- Mac Code、Mac Cowork exact `@main` 和 CLI composition root 已注入完整 Knowledge host；
- 配置已经有 `embedding_model`、`reranker_model`，并实现独立 exact provider route；
- Apple NaturalLanguage 与 `KnowledgeEmbeddingCosineRerankerProvider` 仍服务 local core/test seam，
  shipping 完整产品路径没有把它们当 fallback；
- offline fixture 与真实 Agent/PDF E2E 均证明 configured adapter 被调用、required rerank 生效且最终
  citation 通过 current-turn revalidation；macOS permission UI 与 bookmark restore 也已实测。
- exact route drift 已由 embedding/reranker 完整身份不一致测试直接证明 fail closed；session bookmark
  sidecar lock 的 symlink/hardlink 拒绝也已有直接回归。

仍为 `UNKNOWN` 或后续产品项：

- OpenRouter 首发 route 已完成最小可用性、冻结质量集、真实 Agent 与 PDF E2E；当前质量集没有
  reranker uplift，且 Agent/PDF harness 没有形成逐请求 versioned monetary bill；
- local route 是否存在满足真实 semantic rerank 合同的 universal macOS 方案；当前不作 fallback；
- bookmark 跨 session 复用策略；当前 schema v1 是 session-owned exact-path grant；
- remote candidate text 的产品告知、费用上限与大 corpus batching ceiling；
- Linux CLI 的真实 provider/runtime matrix；
- 大 corpus latency、memory、disk 和 provider cost ceiling；
- 多进程/多 session 更新同一外部 store 的冲突呈现；
- model-facing delete/purge 的未来合同。

这些 `UNKNOWN` 不改变已冻结的用户行为：用户可以自然语言给出外部知识库路径；完整成功路径必须
真实使用 configured embedding 与 semantic reranker；缺配置或权限时明确失败，不伪装完成。

## 15. 最终实施建议

不要先做 UI，也不要重写现有 OKF/RAG core。按以下依赖链补齐：

```text
配置字段与 exact routes
  -> embedding/reranker adapters
  -> KnowledgeLease/external path
  -> build_knowledge ToolRegistration
  -> path-aware required-rerank search_knowledge
  -> Code/Cowork/CLI composition roots
  -> 真实 E2E、质量门和正式文档
```

一句话结论：

> **只有当用户能用自然语言指定当前工作区内或外部的知识库目录，Agent 能自行阅读整理并建库，
> build/query 真正使用配置的 embedding 模型，search 真正使用配置的语义 reranker，并且整条链经过
> exact 路径授权、durable execution 和 citation 重验时，Intatis 才能宣称完成知识库 RAG。**
