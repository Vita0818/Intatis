# Intatis OKF-based RAG 知识库四组件设计分报告

日期：2026-08-09

状态：`FOUR-COMPONENT LOCAL CORE IMPLEMENTED / PRODUCT SURFACE SUPERSEDED BY 2026-08-10 MAIN CONTRACT`

面向读者：后续负责设计、实现、审查和验证 Intatis 知识库能力的 Codex / Intatis 维护者

报告性质：dated design + implementation evidence。当前产品事实仍以 `docs/`、源码、工程配置和测试为准；本报告不覆盖当前 active target。本文最初的 pre-implementation 审计结论保留为历史背景，2026-08-09 的实现状态以紧随其后的 ledger 和第 15 节为准。

当前产品基线：Intatis `v0.40 (build 40)`

当前 active target：Developer ID 直接分发；与本报告中的 RAG 设计无关。

> **后续实施注意：**时间更晚的
> `08_10_26-16_57-model-driven-knowledge-tools-design.md` 是知识库产品补齐的唯一主实施合同。本报告
> 继续作为 OKF/Profile/Validator/immutable-store/search core 与 2026-08-09 实现证据；以下旧产品
> surface 不再约束后续实现：仅限 workspace、模型不得传 path、只暴露 search、固定 Apple embedding、
> optional/cosine rerank 以及不配置 embedding/reranker。新合同要求自然语言 external path、独立
> `KnowledgeLease`、`build_knowledge` + path-aware `search_knowledge`、canonical
> `embedding_model`/`reranker_model`，并且每次成功 search 都真实使用 semantic reranker。
>
> 2026-08-10 当前工作树已按新合同落地配置、provider adapters、external `KnowledgeLease`、两个
> model-facing tools 与 Mac/CLI composition，并通过离线 AgentLoop E2E；真实 provider/主模型、
> macOS bookmark UI 和质量 uplift 仍待验收。精确状态以 08-10 报告及正式 `docs/` 为准；若两份
> 报告在未来产品行为或完成标准上冲突，以 08-10 报告为准。

## 实现 ledger（2026-08-09 current working tree）

四组件合同已作为 non-iOS、Swift-native core 落地；这里的“已实现”不等于已经出现用户可见的
知识库管理页或默认挂载：

| 组件 | 当前实现 | 边界 |
| --- | --- | --- |
| 固定标准 | `ThirdPartyStandards/OpenKnowledgeFormat/0.2/` byte-exact SPEC/LICENSE/UPSTREAM/SHA256SUMS；`NOTICE.md` 与 `ThirdPartyNotices/OpenKnowledgeFormat.md` 记录 Apache-2.0 provenance | 不包含上游 reference agent、Python package、prompt、viewer、sample bundle 或品牌资产 |
| 薄 adapter | public non-iOS `IntatisKnowledge` target；9 份 strict schema；whole-tree OKF conformance + canonical v0.2 writer；`KnowledgeBundleBuildService`、deterministic chunker、完整 embedding/component/composite identity、immutable store | 原始连接器、PDF/Office/OCR、语义清洗和产品 UI 仍由其它工作流负责；build service 要求 exact resolved authorization，但不是 model-facing `build_knowledge` 工具，本轮也没有接 Agent producer 的 durable caller |
| deterministic Validator | bounded Yams AST、schema/identity/path/hash/checksum/content-seal/index/source-locator/secret validation、validation receipt | 机械一致性 validator，不声称证明外部事实、自然语言蕴含或人工审校质量 |
| `search_knowledge` | opaque snapshot-bound mount、exact query embedding、profile-selected dense-only 或 BM25+RRF hybrid、exact optional/required reranker seam、ACL pre-filter、bounded evidence、current-turn final grounding revalidation | 只有 host 显式注入 optional augmenter 才向 Code/Cowork 暴露；Chat/iOS/UI/CLI mount command/MCP Server 均未接入 |

主要实现文件位于 `Packages/IntatisKnowledge/Sources/`；generic host seam 位于
`Packages/IntatisTools/Sources/HostToolRegistryAugmentation.swift`，Agent final-grounding seam 位于
`Packages/IntatisAgentKernel/Sources/TurnGroundingEvidenceRegistry.swift` / `AgentLoop.swift`。Code 与
Cowork 只接收 optional augmenter，默认 `nil`。

当前本地 route 固定为 Apple NaturalLanguage sentence embedding exact identity、L2/cosine
`Float32` exact KNN，并按 profile 选择 dense-only 或 Intatis BM25 + deterministic RRF hybrid。仓内的
`KnowledgeEmbeddingCosineRerankerProvider` 是最小 exact reranker seam，不是 cross-encoder。
remote embedding/reranker 没有隐藏 fallback；host 若以后接入，必须把工具标为 network-backed 并
经过既有网络权限链。

最新 fresh full evidence：`IntatisKnowledgeTests` 106/106、
`TurnGroundingEvidenceRegistryTests` 6/6；真实 Cowork AgentLoop probe 证明 permission
request/resolved → durable prepared → structured `tool_result` → settled → final citation revalidation →
close/drain；snapshot-bound dynamic registration 的 local intent/preview 与 deterministic reviewer
boundary 另有 direct + durable 回归。`IntatisMac` unsigned arm64 Debug 构建通过；`IntatisKnowledge` 与 `IntatisCLI` 的 arm64
及 x86_64 cross-build 通过。x86_64 结果只证明编译，Intel 真机 NLEmbedding availability/质量仍为
`UNKNOWN`。

## 0. 本报告收敛结论（四组件边界已同用户确认）

Intatis 的第一版传统 RAG 知识库候选方案收敛为且只收敛为四个产品组件：

1. **固定并下载一份上游知识格式规范**：采用 Open Knowledge Format（OKF）v0.2 作为知识正文、目录、来源、信任和生命周期的开放基线。
2. **一个很薄的 Intatis RAG Profile / adapter**：只补 OKF 故意没有规定的 chunk、embedding、派生索引、composite retrieval snapshot 和检索兼容信息。
3. **一个小型、确定性、非 AI Validator**：机械验证格式、路径、来源映射、hash、模型/维度兼容、索引完整性和查询结果引用；不能假装证明现实世界真伪或语义蕴含。
4. **一个模型可调用的 `search_knowledge` 工具**：内部完成 query embedding、候选召回、权限过滤、融合、rerank、证据复核和有界返回；LLM 不直接操作向量库，也不分别调用 embedding 或 reranker。

一句话合同：

> **OKF 规定知识怎么写；Intatis RAG Profile 补齐检索兼容信息；Validator 决定某一代知识库能不能安全使用；`search_knowledge` 决定怎么查并只返回可追溯证据。**

构建知识库的 Agent **不是第五个产品组件**。它只是现有 Code/Cowork Agent 执行能力的一种生产者工作流：模型负责语义清洗、组织、摘要和切片建议；宿主负责 identity、hash、来源定位、写入事务和最终验证。

完整主链固定为：

```text
原始知识 / 外部解析结果
  -> 现有 Agent 工作流执行语义清洗、组织、来源标注和切片
  -> staging OKF Bundle + Intatis RAG Profile + complete retrieval snapshot
  -> deterministic Validator
  -> validated immutable snapshot
  -> host 挂载并签发 opaque knowledge-base handle
  -> search_knowledge(query, optional bounded limit)
       -> resolve caller-authorized corpus/partitions
       -> query embedding
       -> lexical + dense retrieval inside authorized corpus
       -> fusion + rerank
       -> final authorization revalidation
       -> exact evidence/source/hash revalidation
       -> bounded evidence results
  -> 最终回答 LLM 只依据返回 evidence 组织答案和引用
```

## 1. 这项设计解决什么问题

### 1.1 用户设想是成立的

用户不需要在每次问答时重新解析、清洗、切片和 embedding 全部原始文档。正确分工是：

- **建库阶段**提前做昂贵、可复用、需要全局一致性的工作；
- **查询阶段**只做每个问题独有的 query embedding、召回、过滤、rerank 和证据选择；
- 用户或宿主在查询前提供一次知识库目录，后续模型使用一个稳定工具；
- 知识库目录必须遵守同一规范，才能在不同 Agent、LLM、embedding 和 reranker 之间复用。

因此，“把已经做好的知识库路径交给查询系统”是合理产品模型。本报告实现时采用 host 预绑路径、
模型只见 opaque handle/query 的 local-core 合同；这是当前源码事实。08-10 主合同已将后续产品行为
修订为：用户可自然语言提供 workspace 内或外部 `store_path`，模型可以传递该地址，但宿主必须用
exact `WorkspaceLease` 或独立 `KnowledgeLease` 将 path 转为 authority。

### 1.2 查询时仍然必须做的工作

以下工作无法全部预先完成，因为它们依赖当前用户问题：

- 生成 query embedding；
- 依据当前问题查 lexical/dense 索引；
- 按当前 session/agent/task/lease 过滤候选；
- 对本次候选执行 rerank；
- 依据当前上下文预算截取结果；
- 在返回前复核 evidence/source revision；
- 处理取消、超时、模型不可用和 snapshot 更新竞态。

这些属于查询，不属于重新建库。

### 1.3 查询时明确禁止偷偷做的工作

`search_knowledge` 不得在一次普通问答中隐式执行：

- 重新解析全量 PDF/Office/网页；
- 重新清洗全部知识；
- 重新切片全部文档；
- 重新 embedding 全库；
- 自动下载模型或大型 runtime；
- 索引损坏后在后台无提示重建；
- 主索引失败后静默改用另一套模型/数据库/远程服务；
- 把缺失来源的模型总结当成已验证证据。

索引缺失、陈旧或不兼容时应明确返回 typed failure，并由独立的建库 Agent 工作流修复。不能为了表面“总能回答”而把昂贵且有副作用的建库操作藏进只读查询工具。

## 2. 范围与非目标

### 2.1 本报告范围

- embedding identity 与派生向量索引的兼容合同；
- OKF 知识 bundle 的 Intatis RAG Profile；
- deterministic validation / grounding contract；
- Code/Cowork/macOS/CLI 将来可用的模型查询工具；
- immutable snapshot、增量更新、删除、查询快照和失败语义；
- 与 Intatis 现有 ToolRegistry、PermissionEngine、WorkspaceLease、EventLog 和 provider exact binding 的集成边界；
- 后续实现和测试顺序。

### 2.2 明确不在本报告范围

- 原始外部知识连接器；
- PDF、Office、网页、图片、OCR 的具体解析实现；
- 建库产品 UI、管理页、状态页或可视化；
- Chat 模式接入；
- iOS 接入；
- Intatis MCP Server、server transport、server OAuth 或托管服务；
- 把任意第三方 RAG 产品整体嵌入 Intatis；
- 训练或微调 embedding/reranker 模型；
- 自动证明任意自然语言答案在语义上被证据蕴含；
- 当前 v0.40 Developer ID release target 的变更。

### 2.3 初始仓库事实（实现前历史基线）

以下是本报告开始设计时的审计快照，不是 2026-08-09 实现后的 current state；当前事实见文首
implementation ledger、`docs/CURRENT_STATE.md` 和源码：

- Intatis 没有完整的 RAG/Knowledge 产品或 ingestion → chunk → embed → retrieve → rerank → citation 闭环；
- provider `Capability.embedding` 只是能力枚举，不能当作 embedding endpoint/client/model/index 已实现；
- 现有 BM25 用于 external MCP deferred `tool_search` 的**工具元数据目录**，不是用户知识库；
- `read_pdf` / `read_document` 是对指定 workspace 文件的按需读取，不是知识库 ingestion；
- EventLog、ArtifactStore、session projection 和 replacement-history compaction 是持久化/上下文基础设施，不是向量检索；
- Chat hosted web search 是当前模型的厂商托管网页搜索，不是本地知识库 RAG；
- Intatis 当前只实现 external MCP **client**，没有产品 MCP Server target。

因此在初始审计时，本文所有 schema、目录、工具和错误码，除明确引用 OKF/MCP 官方字段外，均是
**PROPOSED**。它们随后作为 `IntatisKnowledge` core contract 落地；用户可见 mount/management
surface 仍未 shipped。

## 3. 标准选择结论

### 3.1 没有一个成熟统一的“完整 RAG 知识库文件标准”

当前市场没有一套同时被 LangChain、LlamaIndex、Haystack、主流向量数据库、各 embedding/reranker 和 agent runtime 普遍采用、且完整规定以下全部内容的中立标准：

- 语义知识正文；
- 来源、信任和生命周期；
- chunk identity 与原文定位；
- embedding identity；
- dense/lexical/ANN 文件格式；
- rerank；
- 查询工具；
- citation/grounding；
- 权限与增量更新。

各框架的 `Document` / `Node` 是自己的运行时对象，不是可长期交换的跨产品文件规范。任何声称“市面上绝大多数传统 RAG 都遵循同一完整 bundle 格式”的说法都不准确。

### 3.2 选择 OKF v0.2 的理由

Open Knowledge Format v0.2 是当前最匹配用户设想的开放知识内容基线：

- 知识 bundle 是普通目录；
- concept 是 UTF-8 Markdown + YAML frontmatter；
- 人和 Agent 都能直接读写；
- 可用 Git、zip/tar 或目录分发；
- `index.md` 支持 progressive disclosure；
- `sources`、`generated`、`verified`、`status`、`stale_after` 为 provenance/trust/freshness/lifecycle 提供共同词汇；
- 逐 claim 来源可用 Markdown footnote label 与 `sources[].id` 关联；
- 未知 `type` 和未知扩展字段必须被兼容，允许 Intatis 做薄 Profile；
- 它明确不绑定某个 agent、模型厂商、数据库或 serving system。

OKF v0.2 的最小 conformance 只有：

1. 每个非保留 `.md` 文件有可解析的 YAML frontmatter；
2. 每个 concept 有非空 `type`；
3. 出现 `index.md` / `log.md` 时遵守对应结构。

消费者不能仅因缺少可选字段、未知 type、未知 frontmatter key、断链或缺少 index 而拒绝基础 OKF bundle。

### 3.3 不得夸大 OKF 的成熟度

OKF v0.2 是 Google Cloud 团队刚公开的开放规范，不是 W3C、IETF、ISO 制定的正式标准，也不是已被所有 RAG 框架广泛实现的行业事实标准。官方 reference agent/visualizer 是 proof of concept。

正确表述：

> Intatis 采用 OKF v0.2 作为上游开放知识内容规范，并定义一个可被普通 OKF consumer 忽略的薄 RAG Profile。

错误表述：

> Intatis 完全采用了传统 RAG 的统一行业标准，因此任意向量数据库和 reranker 都能直接读取。

### 3.4 OKF 明确不负责的部分

OKF 官方 non-goals 明确列出的只有：

- 不规定固定 concept taxonomy；
- 不强制规定 storage、serving 或 query infrastructure；
- 不替代 Avro、Protobuf、OpenAPI 等领域 schema；
- 不规定 executor/attester code 的 packaging 或 invocation。

规范正文没有定义 chunk、embedding、向量/lexical/ANN index、reranker 或 RAG
查询工具。后一句是对规范覆盖面的直接核对结论，不应伪装成官方 non-goals 的
逐字列表。runtime protocol、receipt/verdict wire、attester ABI/portability/sandbox
和 attestation cache 则属于规范的 `Considered and deferred`，也不应与 non-goals
混为一类。

所以 Intatis Profile 是必要的，但必须保持“补空白”而不是重新发明 OKF。

### 3.5 其它标准/格式为什么不作为 P0 基线

| 候选 | 擅长 | 不作为本方案基础格式的原因 |
| --- | --- | --- |
| BagIt / RFC 8493 | 文件清单、checksum、可靠交换 | 不理解知识语义、chunk、embedding 或 grounding；未来可作为归档外壳 |
| RO-Crate 1.3 | JSON-LD research object、文件/作者/许可证/provenance | 比当前需求重，仍不规定 RAG index/query；未来可作为跨组织归档外壳 |
| DoclingDocument | 文档解析后的布局、表格、图片和 provenance IR | 属于解析器生态的中间表示，不是最终知识 bundle 标准；解析又在别的会话负责 |
| VDF / vector-io | 向量数据导入导出 | 维护面和采用面较窄，只覆盖向量数据，不能替代知识正文/provenance/grounding |
| LangChain/LlamaIndex/Haystack objects | 各自运行时检索对象 | 框架专属，不是稳定、跨产品、可直接版本控制的文件规范 |

## 4. 组件一：固定并下载 OKF v0.2

### 4.1 固定的上游证据

截至 2026-08-09 的核对结果：

```text
Repository:
https://github.com/GoogleCloudPlatform/knowledge-catalog.git

OKF_SPEC_PIN:
3fcbb9f828c2f23d109c855ee403c3a4c81f3a96

OKF_AUDITED_REPO_HEAD:
374e0bc4c644310ff56cdf9c0fe81eccdec862b0

SPEC.md Git blob:
a516d50128f5aa1f5746d1464661a39f7143e875

SPEC.md SHA-256:
5a3311d270bebb16d558010e75064f5b75323f284992641732b1c8097511f948

LICENSE.md SHA-256:
8c6db340475136df3c1201d458fa5755698eace76e510471ecc9d857d6083dac

License:
Apache License 2.0

Official Git tag for v0.2:
not observed as of audit; do not use a floating or invented tag
```

`OKF_SPEC_PIN` 固定规范内容；`OKF_AUDITED_REPO_HEAD` 只记录审计时上游仓库状态。以后不得把浮动 `main` 当成规范身份。

### 4.2 已采用的最小文件集

仓库已只保存：

```text
SPEC.md
LICENSE.md
UPSTREAM.md          # Intatis 自写 provenance record
SHA256SUMS           # Intatis 自写完整性清单
```

不要为了“采用规范”把 reference agent、visualizer、BigQuery/Gemini runtime、sample credentials 或整个上游仓库引入 Intatis 发行依赖。

实际落点为 `ThirdPartyStandards/OpenKnowledgeFormat/0.2/`；`UPSTREAM.md`、
`SHA256SUMS`、`NOTICE.md` 与 `ThirdPartyNotices/OpenKnowledgeFormat.md` 已同步记录
provenance、许可证和完整性。上游 reference agent、visualizer、sample bundle 和
Python/runtime 未进入 Intatis 依赖闭包。

### 4.3 可复现下载步骤

```sh
git clone --filter=blob:none --sparse \
  https://github.com/GoogleCloudPlatform/knowledge-catalog.git \
  knowledge-catalog

git -C knowledge-catalog sparse-checkout set okf
git -C knowledge-catalog checkout --detach \
  3fcbb9f828c2f23d109c855ee403c3a4c81f3a96

git -C knowledge-catalog rev-parse HEAD
git -C knowledge-catalog show HEAD:okf/SPEC.md | shasum -a 256
git -C knowledge-catalog show HEAD:okf/LICENSE.md | shasum -a 256
```

然后只复制已审文件。复制与“自行实现兼容 parser”是两件事：复制规范文件要记录许可证/provenance；只实现兼容格式则不等于引入上游 runtime。

### 4.4 OKF 基础兼容策略

Intatis consumer 应：

- 精确支持 `okf_version: "0.2"`；
- 对 v0.1 可选兼容 `timestamp` 和正文 `# Citations` fallback；
- 新写 bundle 只写 v0.2 canonical `generated.at` 和 `sources`；
- 保留未知 frontmatter key；
- 对未知 `type` 当普通 concept；
- 将 OKF 基础 conformance 与 Intatis Profile conformance 分开报告；
- 不把 OKF trust tier 当作访问权限；
- 不因 OKF 容忍断链，就允许 grounding 所依赖的 evidence/source 断链通过 Intatis strict validator。

## 5. 组件二：Intatis OKF RAG Profile 0.1

### 5.1 Profile 的唯一职责

Profile 只回答以下 OKF 未回答、但传统 RAG 必须回答的问题：

- 这是哪一个不可变 bundle revision？
- 哪个 chunker、规范化方式和版本产生 retrieval units？
- chunk 如何精确映射回 OKF concept 和来源？
- 哪个 embedding 模型/修订/维度/归一化/metric 生成向量？
- lexical/dense index 属于哪一代、是否完整、能否重建？
- query runtime 与 index 是否兼容？
- rerank 是 required、optional 还是 disabled？
- 当前 composite retrieval snapshot 是否已由 deterministic Validator 通过？

Profile 不负责：

- 重新描述完整知识正文；
- 保存 API key、Authorization、provider endpoint 或私有 headers；
- 给模型授予目录权限；
- 把索引变成知识真值；
- 规定所有实现必须用同一个数据库二进制格式；
- 宣称某段文字在现实世界中必然为真。

### 5.2 推荐目录结构

以下结构属于 `Intatis OKF RAG Profile 0.1` 的 **PROPOSED** 设计：

```text
knowledge-store/                 # user supplies this stable path to the host
  .intatis-rag-store.json        # atomically selected current snapshot; not an OKF file
  .intatis-rag-host/             # owner-only cross-process coordination; not model-facing
  .intatis-rag-snapshots/
    snap_<opaque-id>/            # one complete immutable query snapshot
      index.md                   # OKF root index; okf_version: "0.2"
      log.md                     # optional OKF history captured at this revision
      concepts/
        ... .md                  # canonical OKF concepts for this exact revision
      references/
        ...                      # optional immutable source snapshots

      .intatis-rag/
        profile.json             # thin profile for this exact snapshot
        checksums.json           # leaf-file integrity inventory
        chunks.jsonl             # retrieval units + concept locators/provenance
        lexical/                 # exact selected lexical component; rebuildable
        dense/                   # exact selected dense component; rebuildable
        auxiliary/               # optional backend-private data
```

08-10 shipping 实现把旧提案名 `snapshots/` 收窄为 `.intatis-rag-snapshots/`，使普通
file/patch/Git/managed-terminal 的强制 WorkspaceLease deny floor 可以机械保护整个发布区。已有
`snapshots/` 只能由持有 read-write writer authority 的 build/update 在 store lock 内原子迁移；
只读打开不得创建或迁移任何 store 基础设施。

关键边界：

- `knowledge-store/` 是 Intatis 多版本 wrapper，本身不是 OKF bundle；每个
  `snap_*` 目录才是完整、可独立导出和由普通 OKF consumer 读取的 OKF bundle；
- Host 也可直接挂载一个只读 `snap_*`/standalone OKF bundle，视作 single-snapshot store；
- `concepts/` 和允许的 `references/` 内容是该 snapshot 的知识层；
- `chunks.jsonl` 是预处理后的 retrieval unit 清单；P0 exact slices 必须能从 concept
  bytes 和冻结规则重建，generated derivatives 则必须作为带完整 producer/support
  provenance 的 canonical derivative 保存，不能伪称可重新推断；
- `profile.json.retrieval_snapshot` 精确绑定 bundle revision、chunk manifest、
  dense/lexical component、reranker binding 和 retrieval policy；它是一次 hybrid
  query 的 composite identity；
- `dense/`、`lexical/` 和 `auxiliary/` 是可删除、可重建的派生索引；
- backend-private index 文件不进入通用文件格式承诺；
- 普通 OKF consumer 进入某个 `snap_*` 并忽略 `.intatis-rag/` 后，仍能读取完整知识；
- Intatis 查询工具只挂载已验证的完整 immutable snapshot；
- concepts、references、profile、chunks 和 index 必须一起版本化；不能只固定旧 index、
  却在旧查询运行时原地替换顶层 concept/chunk；
- 不允许查询工具直接修改 mounted snapshot；更新始终创建新的 `snap_*`；
- 实现可在 host-private content-addressed store 中去重相同文件，但不能改变上述
  snapshot 语义或让 reader 观察到跨版本拼接。
- validation receipt 保存在 bundle 外的 Intatis host-owned registry/cache 中，以
  store/root identity、snapshot revision 和 validator version 为 key；bundle
  内即使出现生产者自带 receipt，也只当不可信附件，不能据此跳过本机验证。

建议的 store pointer 最小 shape：

```json
{
  "schema": "intatis-rag-store/1",
  "store_id": "kb_<opaque-stable-id>",
  "revision": 7,
  "current_snapshot": "snap_<opaque-id>",
  "current_snapshot_revision": "sha256:<composite-retrieval-snapshot-digest>"
}
```

`current_snapshot` 只能是一个经过严格 ID grammar 校验的相对目录名，不能含 `/`、
`..`、symlink 或绝对路径。Pointer 在 store writer lease 内以 read-merge-atomic-write
方式更新；mount 仍须打开 snapshot、重算/核对 revision 并签发 handle，pointer 本身
不是权限或完整性证明。

### 5.3 为什么不标准化向量索引二进制

把 HNSW、sqlite-vec、USearch、SQLite/FTS5、Parquet 或某个 Swift 包的私有文件格式写死为知识标准，会带来不必要的耦合：

- index 可能依赖 CPU 架构、endianness、library version 或实现细节；
- dense index 和 lexical index 的升级周期不同；
- exact KNN、小型 HNSW 和远程 vector store 的最佳选择不同；
- 主存储一旦被某个第三方 index 接管，就会与 Intatis 的可恢复/可审计原则冲突。

因此 Profile 标准化的是 **index identity、输入 digest、兼容条件和 snapshot contract**，不是索引内部 bytes。Validator 只在对应 adapter 已注册时验证 backend-private 文件；未知 backend 明确 `KB_INDEX_BACKEND_UNSUPPORTED`，不能猜测打开。

### 5.4 `profile.json` 建议 shape

下面是设计合同，不是已发布 schema：

```json
{
  "schema": "intatis-okf-rag-profile/0.1",
  "profile": "org.vita.intatis.okf-rag",
  "profile_version": "0.1",
  "okf": {
    "version": "0.2",
    "spec_commit": "3fcbb9f828c2f23d109c855ee403c3a4c81f3a96"
  },
  "bundle": {
    "id": "kb_<opaque-stable-id>",
    "revision": "sha256:<canonical-bundle-digest>",
    "created_at": "2026-08-09T00:00:00Z"
  },
  "normalization": {
    "text_encoding": "utf-8",
    "line_endings": "lf",
    "unicode": "nfc",
    "version": "intatis-text-normalization/1"
  },
  "chunking": {
    "manifest": ".intatis-rag/chunks.jsonl",
    "algorithm": "<registered-chunker-id>",
    "version": "<immutable-version>",
    "parameters_digest": "sha256:<digest>"
  },
  "embedding_indexes": [
    {
      "id": "dense_primary",
      "component_revision": "sha256:<component-digest>",
      "backend": {
        "identity": "<registered-vector-backend-id>",
        "format_version": "<immutable-format-version>",
        "runtime_version": "<exact-adapter-version>"
      },
      "model": {
        "identity": "<provider-neutral-model-id>",
        "revision": "<immutable-revision-or-content-digest>",
        "tokenizer_revision": "<immutable-revision-or-content-digest>",
        "runtime_binding_kind": "local",
        "runtime_binding_digest": "sha256:<non-secret-exact-route-config-digest>",
        "dimensions": 1024,
        "scalar_type": "float32",
        "quantization": "none",
        "pooling": "<registered-pooling>",
        "normalization": "l2",
        "similarity": "cosine",
        "document_instruction": "<exact-or-empty>",
        "query_instruction": "<exact-or-empty>",
        "max_input_tokens": 8192,
        "truncation": "end"
      },
      "chunk_manifest_digest": "sha256:<digest>",
      "vector_count": 1234,
      "index_digest": "sha256:<digest>"
    }
  ],
  "lexical_indexes": [
    {
      "id": "lexical_primary",
      "component_revision": "sha256:<component-digest>",
      "backend": {
        "identity": "<registered-lexical-backend-id>",
        "format_version": "<immutable-format-version>",
        "runtime_version": "<exact-adapter-version>"
      },
      "tokenizer": "<registered-tokenizer-id>",
      "language_policy": "<registered-policy-id>",
      "chunk_manifest_digest": "sha256:<digest>",
      "document_count": 1234,
      "index_digest": "sha256:<digest>"
    }
  ],
  "retrieval": {
    "dense": "required",
    "lexical": "optional",
    "fusion": "rrf",
    "reranker": {
      "mode": "optional",
      "model": {
        "identity": "<provider-neutral-model-id>",
        "revision": "<immutable-revision-or-content-digest>",
        "tokenizer_revision": "<immutable-revision-or-content-digest>",
        "runtime_binding_kind": "local",
        "runtime_binding_digest": "sha256:<non-secret-exact-route-config-digest>",
        "template_digest": "sha256:<exact-query-document-template-digest>",
        "max_input_tokens": 8192,
        "truncation": "end",
        "score_semantics": "<registered-score-semantics>"
      }
    },
    "evidence_contract": "intatis-evidence/1"
  },
  "retrieval_snapshot": {
    "id": "snap_<opaque-id>",
    "revision": "sha256:<composite-retrieval-snapshot-digest>",
    "bundle_revision": "sha256:<canonical-bundle-digest>",
    "chunk_manifest_digest": "sha256:<digest>",
    "dense": {
      "id": "dense_primary",
      "component_revision": "sha256:<component-digest>"
    },
    "lexical": {
      "id": "lexical_primary",
      "component_revision": "sha256:<component-digest>"
    },
    "retrieval_policy_digest": "sha256:<digest>",
    "reranker_binding_digest": "sha256:<digest>"
  },
  "integrity": {
    "algorithm": "sha256",
    "inventory": ".intatis-rag/checksums.json"
  }
}
```

真正的 Profile JSON Schema 文档应在自身的 `$schema` 中声明 JSON Schema
2020-12；上面的 `profile.json` 是被验证的实例，因此只记录 Intatis schema
identity，不能把 draft 2020-12 元模式 URI误写成该实例的业务 schema。

### 5.5 Profile 字段的强弱语义

严格必需：

- profile identity/version；
- exact OKF version/spec pin；
- bundle ID/revision；
- normalization/chunker identity；
- chunk manifest identity/digest；
- 至少一个可执行检索路径；
- embedding index 使用的完整兼容 identity；
- dense/lexical component revision、backend format/runtime version、count/digest；
- composite retrieval snapshot identity/revision 及其 exact component/policy binding；
- integrity inventory。

可选或策略字段：

- lexical index；
- fusion strategy；
- reranker compatibility；
- trust/freshness filter；
- quality/evaluation metadata；
- source snapshot policy。

任何可选字段缺失都不能被 runtime 猜成某个默认值。如果缺失会影响向量语义，例如 normalization、metric、dimension、document/query instruction，则该 embedding index 不可用。

所有 digest 必须分层计算，不能把完整 `profile.json` 粗暴塞进
`bundle.revision`，否则 Profile 中的 component/snapshot digest 会形成间接循环：

1. `bundle.revision`：只覆盖 versioned canonicalization 后的 OKF knowledge files
   （`index.md`、`log.md`、concepts 和纳入 snapshot 的 references）；
2. `chunk_manifest_digest`：覆盖 normalization/chunker config projection 与
   `chunks.jsonl`，并绑定 `bundle.revision`；
3. dense/lexical `component_revision`：覆盖 exact backend/model/config identity、
   component manifest/index inventory，并绑定 chunk digest；
4. `retrieval_snapshot.revision`：覆盖 bundle/chunk revision、按顺序选择的 exact
   dense/lexical component revision、reranker binding 和 retrieval policy；
5. `checksums.json` 是 leaf-file inventory，不能包含自身；validation receipt、
   `.intatis-rag-store.json` active pointer 和 revision 字段自身都不进入其所声明的 digest。

每一层都必须固定 canonical projection/version。具体 byte canonicalization 仍是第 15
节的 `UNKNOWN`，但“无直接或间接自引用、输入域明确、算法带版本”是硬约束。

### 5.6 Embedding identity 必须完整

只保存字符串模型名不够。兼容 key 至少包含：

- model identity；
- exact revision、文件 hash 或服务方可证明的 immutable revision；
- tokenizer revision；
- local/remote runtime binding kind，以及由 Host 对非秘密 exact route/config 计算的 digest；
- index backend identity、format version 与 exact adapter/runtime version；
- output dimension；
- scalar type/quantization；
- pooling；
- L2 normalization 等后处理；
- cosine/dot/L2 等 similarity/distance；
- document instruction/prefix；
- query instruction/prefix；
- truncate/max-length policy；
- 输入文本 normalization/chunker version。

其中任何一项变化都可能让旧向量与新 query embedding 不可比较。

Profile 不保存 endpoint、header、credential 或 API key。Host 用
`runtime_binding_digest` 将非秘密的 exact resolved route/config 绑定到本地 registry，
真正凭据仍按现有 provider 规则懒加载。远程 embedding 服务未暴露 immutable
revision 时，只能证明“Host route/config identity 相同”，不能证明服务端权重没有
未声明漂移；必须保留为 `UNKNOWN`，不得伪造 model hash。

### 5.7 多 retrieval snapshot 可共存

为了换模型、A/B 或逐步迁移，一个 store 可以同时保留多个完整 snapshot，但一次
查询必须冻结一个 composite retrieval snapshot：

```text
snapshot S1 = bundle R + chunks C + dense D1 + lexical L1 + reranker/policy P1
snapshot S2 = bundle R + chunks C + dense D2 + lexical L1 + reranker/policy P2
```

默认 store handle 只允许 `.intatis-rag-store.json` 当前明确指向的 exact snapshot。
Host 在该 snapshot 内检查 runtime compatibility；不兼容就返回 typed failure，绝不
扫描 retained snapshots 寻找“还能跑”的旧版本。A/B 必须由 Host 显式 admission，
为每个 exact snapshot 签发独立 handle（或显式、有限的 active-set handle）；模型不能
选择 snapshot。因 reader drain/retention 保留的旧 snapshot 只供既有 pinned query
完成，或经用户/Host 明确 rollback 后重新激活，不能成为 compatibility fallback。

无论哪种 admission，都不得在查询时把 S1 的 dense、S2 的 lexical 和另一套
reranker 临时拼起来，也不得按相似模型名、相同维度或 endpoint 名称 fallback。
物理实现可以去重 R/C/L1，但逻辑 identity 必须完整。

### 5.8 `chunks.jsonl` 建议 shape

每行一个 retrieval unit：

```json
{
  "schema": "intatis-chunk/1",
  "chunk_id": "chk_<stable-opaque-id>",
  "concept_id": "concepts/policies/refund",
  "concept_revision": "sha256:<concept-bytes-digest>",
  "evidence_class": "exact_concept_slice",
  "text": "Exact text used for embedding and evidence.",
  "text_sha256": "sha256:<digest>",
  "concept_locator": {
    "kind": "utf8-byte-range",
    "start": 120,
    "end": 268
  },
  "source_ids": ["refund-policy"],
  "producer": {
    "identity": "<registered-chunker-id>",
    "version": "<immutable-version>",
    "at": "2026-08-09T00:00:00Z"
  }
}
```

硬规则：

- `chunk_id` 不从文件绝对路径直接泄露信息；
- `exact_concept_slice` 的 `text` 必须与 concept 中声明范围的规范化 bytes 精确一致；
- `generated_derivative` 必须使用不同的 `evidence_class`，记录
  `producer {identity, version, at}` 与至少一个 `supporting_concepts
  {concept_id, concept_revision, concept_locator}`；它不得携带伪造的 exact
  `concept_locator`；
- generated summary 不能伪装成 exact source slice；
- exact slice 与 generated derivative 使用不同的 locator/evidence contract；
- `source_ids` 必须解析到 concept `sources[].id`；
- concept revision、text digest、range 均由宿主计算，不能接受模型自报；
- offset 的单位必须固定，不能混用 Unicode scalar、UTF-16、grapheme、UTF-8 bytes；
- page/line/DOM/layout locator 如要支持，必须另定义 versioned kind。

`concept_locator` 只证明 evidence 在规范化 OKF concept 中的位置。它不是原始
PDF、网页或 Office 文件中的 locator。只有上游解析结果另带可重放且通过验证的
source locator 时，Profile 才能额外记录并返回原始来源定位；首版不得从 concept
字节范围伪造原始文档页码、DOM 节点或坐标。

P0 `source_locator` 必须绑定 immutable `source_revision`，并携带 exact registered
`adapter_identity`/`adapter_version`。没有固定 source bytes/revision、没有可重放
adapter，或只有无法解释的 opaque 字符串时，应完全省略 source locator，只保留
concept grounding 与 `source_id`；不得返回一个看似精确但无法复核的定位。Live
source locator 需要另行版本化合同，不在 P0 偷偷放宽。

P0 的 deterministic chunker 只生成 `exact_concept_slice`。Agent 生成的摘要只有在
作为 canonical derivative 连同完整 producer/support manifest 落盘并通过 Validator
后，才可使用 `generated_derivative`；它不是“运行时临时总结一下就当 evidence”。

### 5.9 原始来源、知识正文、chunk 和向量的权威顺序

```text
原始来源或其不可变 snapshot
  -> OKF concept（规范化知识正文和 provenance）
  -> chunk manifest（exact slices 可重建；generated derivatives 有 canonical provenance）
  -> embedding/lexical index（可重建加速结构）
```

向量永远不是知识事实。索引命中只能定位 evidence；回答必须引用 evidence/source，而不是引用“向量相似度 0.83”。

### 5.10 Reranker 的位置

Reranker 是查询策略，不是 bundle 的知识真值。Profile 只需要表达：

- `required`：缺 exact compatible reranker 就失败；
- `optional`：可不 rerank，但结果必须明确 `rerank_applied=false`；
- `disabled`：不允许 tool 私自调用 reranker。

`required` 或指定具体 optional reranker 时，compatibility key 至少包括 model
identity/revision、tokenizer revision、query-document template digest、最大输入与
截断策略、score semantics；Host 只能 exact resolve。若 mode 为 `disabled`，则
`model` 必须缺失。不能把不可比较的 score 当作跨模型公共标准；模型侧只需要最终
连续 `rank`。

上述三态继续作为 core/profile 兼容合同。08-10 主合同定义的完整产品模式只接受 required semantic
reranker：每次成功 search 必须 `rerank_applied=true`；optional/disabled 或当前 embedding-cosine seam
不能通过产品完成验收。

### 5.11 权限字段只可作为提示，不是 authority

Bundle 可带 classification、owner、visibility hint，但不得让外部文件自授予访问权。真实 authorization 始终来自 Intatis host 的 CapabilityLease、WorkspaceLease、PermissionEngine 和当前调用 identity。

## 6. 组件三：Deterministic Validator

### 6.1 定位

Validator 是普通确定性程序：

- 默认无 LLM；
- 默认无网络；
- read-only；
- bounded；
- no-follow；
- exact snapshot、policy 与 backend registry 相同时，semantic verdict、digest 和诊断顺序相同；
- 任一安全关键不确定性 fail closed；
- 不执行 bundle 中的脚本、Skill、attester 或模型指令；
- 不把 OKF 正文当作系统/开发者指令。

它应作为一个小 library/command seam，被建库 Agent、mount boundary 和 `search_knowledge` 复用，而不是三套不一致 validator。

### 6.2 Validator 的三种调用模式

同一个组件提供三个窄入口：

1. **Publish validation**：完整 staging snapshot 验证，通过后才可发布。
2. **Mount/query validation**：挂载时验证 receipt、store/snapshot identity；每次查询复核调用相关 identity/digest。
3. **Evidence/citation validation**：返回前验证 evidence；最终渲染前验证引用 ID 确实来自本 turn 的成功 tool result。

这不是三个产品组件，而是同一 deterministic validation contract 的三个时点。

### 6.3 验证层级

#### A. 文件系统与安全

- root 必须是 host 已授权的 canonical directory；
- 拒绝 `..`、越界绝对路径和 bundle 内 escape；
- no-follow 打开文件；
- 拒绝不允许的 symlink/hardlink/特殊文件；
- owner/mode/single-link 规则与使用场景一致；
- 文件数量、单文件大小、总字节、目录深度有上限；
- YAML 使用 safe loader；禁止可执行/自定义 tags；
- 在完整展开前限制 alias/anchor 数量、节点数、递归深度、标量长度和总展开量，防止 alias expansion DoS；
- 读取过程中 root identity 不得变化；
- validate 后不能按未经固定的路径重新打开另一份文件。

#### B. OKF v0.2 conformance

- UTF-8；
- frontmatter delimiter 与 YAML parse；
- 非空 `type`；
- reserved `index.md`/`log.md` 结构；
- root `okf_version` 存在时校验；OKF 基础 conformance 不要求它必须存在；
- v0.1 fallback 只读兼容；
- 未知 field/type 保留并容忍。

Safe-loader、tag/alias/资源上限属于 Intatis host/parser 的安全加严，不属于 OKF
v0.2 基础 conformance；因这些策略拒绝的文件不得误报为“OKF 标准不合规”，应使用
独立的 host safety/Profile diagnostic。

#### C. Intatis Profile schema

- JSON Schema/shape/type/required/additionalProperties；
- profile/OKF version 支持；
- Intatis RAG Profile 要求根 `index.md` 存在并声明 exact `okf_version: "0.2"`；这是 Profile 加严，不是 OKF 基础要求；
- ID、字符串、数组、嵌套深度和 safe integer bounds；
- 不允许 credential、Authorization、endpoint/header/query secret container；
- backend/model/chunker/tokenizer 只能来自注册表 exact ID。

#### D. Bundle integrity 与 provenance

- inventory 中每个文件存在且 size/hash 一致；
- 不允许未清单化的关键文件参与 snapshot；
- bundle revision 使用 canonical、versioned digest algorithm；
- concept ID/path 唯一；
- `sources[].id` 在 concept 内唯一；
- 每个被 evidence 使用的 source 有可解析 resource；
- footnote label 与 source ID 可机械对应；
- generated/verified/status/stale_after shape 合法；
- 模型生成内容不能自动获得 human-reviewed 身份。

#### E. Chunk grounding

- chunk ID 全局唯一；
- concept revision 匹配；
- exact concept slice 的 locator 可重放且 bytes/text/hash 一致；
- exact concept slice 与 generated derivative 执行不同 schema branch；
- generated derivative 必须携带 producer/version/time 和至少一个可重放的
  supporting concept locator，且不得伪造自己的 exact concept byte range；
- source IDs 全部存在；
- 可选 `source_locators[]` 的 `source_id` 必须属于同一 evidence 的 `source_ids`，
  `source_revision` 必须绑定 snapshot inventory，locator schema/kind 必须由 exact
  registered adapter identity/version 逐项重放；
- chunk 之间允许 overlap，但不能用 overlap 伪造 index count；
- chunk manifest digest 与 composite snapshot 记录一致。

#### F. Embedding/index compatibility

- backend identity/format version/adapter runtime version 完整且已注册；
- model identity/revision/tokenizer、runtime binding kind/digest、dimension、scalar、
  quantization、pooling、normalization、metric、document/query instructions、
  max-input/truncation policy 完整；
- query runtime 对上述完整 compatibility key 逐字段全等；
- vector count 与 eligible chunk count 一致；
- 每个 vector key 映射到一个有效 chunk ID；
- 无 orphan vector、duplicate key 或 deleted/tombstoned chunk；
- NaN/Inf/错误 dimension 被拒绝；
- index backend/version 已注册；
- backend-private index digest/metadata 一致。
- required/specified reranker 的 model/revision/tokenizer、runtime binding、template、
  max-input/truncation 与 score-semantics compatibility key 全等。

#### G. Lexical/retrieval completeness

- lexical document count；
- tokenizer/language policy identity；
- chunk manifest digest；
- fusion 所需 index 都可用；
- profile 声明 required 的路径缺失时 invalid，不得降级。

#### H. Lifecycle/trust/freshness

- `draft`、`deprecated`、`stale_after` 可按 host policy filter/warn/deny；
- 缺 `verified` 在 OKF 中仍 conformant，但 Intatis strict profile 可把它分类为 unverified；
- trust tier 只是检索/显示 policy input，不是授权；
- 当前日期和 source revision policy 必须明确。

#### I. Permission/scope

- validator receipt 不授予权限；
- mount handle 与 exact host scope 绑定；
- query 时重新授权；
- evidence 只返回 caller 可见内容；
- filter 由 host 注入，模型无参数可放宽。
- handle 若授权整个 immutable bundle，检索可直接在该 bundle 内运行；
- bundle 若混合多种 ACL，必须按 host-owned security partition/namespace 在候选召回前限制 corpus，并在返回前再次授权；不能先做全库 Top-K 再过滤未授权结果。

### 6.4 Validator 能证明与不能证明什么

能机械证明：

- 某文件符合已知 schema；
- 某段 evidence 确实来自某个已固定的 concept slice，并链接到该 concept 声明的 source ID；
- 若存在独立且可重放的 source locator，则该 locator 能解析到已固定的原始来源 snapshot；
- 某 hash、range、revision、dimension 和 index mapping 一致；
- 查询返回的 evidence ID 属于当前 validated snapshot；
- 最终 citation ID 确实来自当前 turn 的 tool result；
- 读取过程中没有发生可观测的 snapshot 偷换。

不能机械证明：

- 原始来源本身是否真实；
- Agent 的总结是否完整、公允；
- 自然语言 claim 是否被 evidence 语义蕴含；
- 某个远程 embedding service 内部模型没有未声明漂移；
- 高相似度结果一定与问题相关；
- LLM 一定不会写出 evidence 之外的断言。

因此确定性 Validator 是 hallucination 的必要防线，但不是“零幻觉证明器”。语义 faithfulness 仍需离线评测、reranker/NLI、人工抽检或未来独立质量门。

### 6.5 Validation receipt

建议成功 receipt：

```json
{
  "schema": "intatis-rag-validation/1",
  "status": "valid",
  "bundle_id": "kb_<id>",
  "bundle_revision": "sha256:<digest>",
  "retrieval_snapshot": "snap_<id>",
  "retrieval_snapshot_revision": "sha256:<digest>",
  "profile_version": "0.1",
  "okf_version": "0.2",
  "validated_at": "2026-08-09T00:00:00Z",
  "validator": {
    "identity": "intatis-rag-validator",
    "version": "<build-version>"
  },
  "counts": {
    "concepts": 100,
    "chunks": 1234,
    "vectors": 1234
  },
  "diagnostics": []
}
```

状态建议只有：

- `valid`：可发布/挂载；
- `valid_with_warnings`：只有明确非安全、policy 允许的 warning；
- `invalid`：不可发布/挂载。

Receipt 本身必须与 exact store/snapshot root identity、bundle revision 和 retrieval
snapshot revision 绑定；复制一份旧 receipt 到新目录不能让新内容通过。

Receipt 由 Intatis host 保存到 bundle 外的 owner-only registry/cache。它不是
canonical knowledge，也不进入 bundle/snapshot digest；查询时仍要复核 root
identity、bundle/snapshot revision 和当前 validator/backend registry compatibility，
不能把缓存命中当作永久授权或永久有效证明。

`validated_at` 是宿主加上的审计时间，不属于 deterministic semantic verdict。测试
比较时应忽略该非语义 envelope 字段，或者把 host-supplied timestamp 明确列为输入；
不得一边写入当前时钟，一边声称完整 receipt bytes 对同一输入永远相同。

### 6.6 发布与 TOCTOU 合同

```text
exclusive store writer lease
  -> create staging snap_<id>.tmp
  -> write complete OKF + profile + chunks + dense/lexical indexes
  -> fsync/atomic completion boundary for the whole snapshot
  -> deterministic validation
  -> atomic rename to immutable .intatis-rag-snapshots/snap_<id>
  -> atomic current-snapshot pointer/host registry update
```

- 查询开始时冻结 `{storeIdentity, snapshotID, snapshotRevision, bundleRevision}` 并持有
  reader lease/稳定目录句柄；
- 更新发布为完整新 snapshot，不原地修改旧 snapshot 的 concept、chunk 或 index；
- 已开始查询继续使用旧 snapshot；旧 snapshot 至少保留到 exact reader drain；
- 新查询才读取新的 current-snapshot pointer；
- 若 Host 无法证明 snapshot identity 稳定，或查询中发生意外替换，则返回
  `KB_REVISION_CHANGED`；
- 删除知识同样生成完整新 snapshot/tombstone，不在 active snapshot 中原地漏删。

### 6.7 诊断原则

- typed code + sanitized bounded message；
- 不输出秘密、raw provider response、embedding vector、私有绝对路径或 stack；
- 同一输入诊断顺序稳定；
- warning 和 error 分开；
- invalid 不自动修复；
- repair 建议可以指出“需要重新建库/重新 embedding/重新授权”，但不能自行执行。

## 7. 组件四：`search_knowledge` 工具

### 7.1 产品定位

`search_knowledge` 是模型唯一需要认识的 RAG 查询入口。它是 Intatis-native ToolRegistry 工具；descriptor 和 result 可以采用 MCP-compatible JSON Schema/structured-content 形状，但本报告**不新增 Intatis MCP Server**。

模型不应该分别看到：

- `embed_query`；
- `vector_search`；
- `bm25_search`；
- `rerank_chunks`；
- `open_index`；
- `read_vector_file`。

这些是一个查询工具的内部实现步骤。分开暴露会扩大 tool surface、增加错误组合、让模型选择不兼容模型/index，并使 citation/provenance 更难统一。

### 7.2 路径与 handle

> 下述 opaque-handle 流程是 2026-08-09 已实现 core/legacy path。08-10 主合同的 model-facing v2
> 允许用户提供的 `store_path`，包括 authorized external absolute path；内部仍可在
> `WorkspaceLease`/`KnowledgeLease` 授权后转换为 exact opaque mount。path 进入 schema 不等于 path
> 获得 authority。

知识库路径只出现在 host mount boundary：

```text
user/host supplies directory
  -> WorkspaceLease/未来 KnowledgeLease authorization
  -> validator
  -> mount registry
  -> opaque handle kb_<id>
  -> model sees handle or a handle-bound tool
```

Handle 是名称，不是 capability。每次调用仍要用 current session/agent/task/turn/capability/authorization 重新校验。

默认 handle 绑定 store 的 current-snapshot admission rule，不绑定“任意兼容历史
snapshot”；显式 A/B handle 则绑定一个 exact admitted snapshot。Pointer 更新后旧
snapshot-specific handle 必须撤销新 admission，只有更新前已经取得 reader lease 的
在途调用可以按普通更新策略完成。

授权只允许两种明确模式：

1. handle 绑定一个 caller 有权读取的完整 immutable bundle；
2. bundle 含混合权限时，host 先解析 caller 可见的 security partition/namespace，
   dense/lexical retrieval 只能在这些 partition 内运行，返回前再逐 evidence 复核。

禁止先在未授权全库上做 Top-K、再删除不可见 chunk。否则不可见内容会影响候选
截断和排名，也可能通过远程 backend、时间或结果形状形成 side channel。Bundle
自带的 classification 仍不是 authority；partition membership 必须来自 host state。

在 08-10 v2 合同下，模型可提供用户点名的 `store_path`，但仍不可提供或控制：

- 未经用户/host 精确授权的路径，或把任意绝对路径本身当作 capability；
- index backend；
- embedding/reranker provider/model；
- endpoint、API key 或 headers；
- permission filter；
- snapshot/component override；
- raw SQL/shell/ANN parameters。

### 7.3 最小 input schema

以下是已实现的 v1 opaque-handle schema。后续产品接线使用 08-10 主合同的 path-aware v2
`store_path/query/limit` schema，不能把本节 v1 当成最终 model-facing surface。

多知识库工具：

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false,
  "required": ["knowledge_base", "query"],
  "properties": {
    "knowledge_base": {
      "type": "string",
      "pattern": "^[A-Za-z0-9._-]{1,128}$"
    },
    "query": {
      "type": "string",
      "minLength": 1,
      "maxLength": 16384
    },
    "limit": {
      "type": "integer",
      "minimum": 1,
      "maximum": 20,
      "default": 8
    }
  }
}
```

单知识库 invocation 更小：host 将 handle 绑定到 tool registration，模型 schema 只有 `query` 和 `limit`。

领域、时间、tag、trust 等 filters 只有在它们能被严格 schema 化且不能放宽 host authority 时才加入。第一版不要接受任意 filter DSL。

### 7.4 内部查询流水线

```text
1. Resolve handle and re-authorize exact caller
2. Freeze validated full retrieval snapshot + bundle revision
3. Resolve the caller-authorized corpus/partitions
4. Resolve exact compatible query-embedding runtime
5. Normalize query with recorded policy
6. Generate query embedding
7. Dense candidate retrieval inside authorized partitions
8. Optional lexical/BM25 retrieval inside authorized partitions
9. Apply trust/freshness policy to authorized candidates
10. Fusion, normally RRF when both paths exist
11. Optional/required rerank of authorized candidates according to frozen policy
12. De-duplicate and apply source diversity/context budget
13. Resolve candidate IDs back through chunk manifest
14. Re-authorize and recompute exact evidence hashes/locators
15. Return bounded, ordered evidence
```

候选数和最终条数是 host policy。示例可以是 dense 40 + lexical 40 → rerank 20 → return 8，但这些不是规范常量，必须通过真实 corpus eval 决定。

### 7.5 Output contract

建议成功结果：

```json
{
  "status": "ok",
  "knowledge_base": "kb_<id>",
  "knowledge_base_revision": "sha256:<digest>",
  "retrieval_snapshot": "snap_<id>",
  "retrieval_snapshot_revision": "sha256:<digest>",
  "rerank_applied": true,
  "truncated": false,
  "evidence": [
    {
      "evidence_id": "ev_<stable-id>",
      "rank": 1,
      "text": "Exact bounded evidence text.",
      "text_sha256": "sha256:<digest>",
      "evidence_uri": "knowledge://kb_<id>/snap_<id>/ev_<id>",
      "concept_id": "concepts/policies/refund",
      "concept_revision": "sha256:<digest>",
      "source_ids": ["refund-policy"],
      "evidence_class": "exact_concept_slice",
      "concept_locator": {
        "kind": "utf8-byte-range",
        "start": 120,
        "end": 268
      },
      "trust": "human-reviewed",
      "status": "stable",
      "stale": false
    }
  ]
}
```

没有足够证据是正常业务结果：

```json
{
  "status": "insufficient_evidence",
  "knowledge_base": "kb_<id>",
  "knowledge_base_revision": "sha256:<digest>",
  "retrieval_snapshot": "snap_<id>",
  "retrieval_snapshot_revision": "sha256:<digest>",
  "rerank_applied": false,
  "truncated": false,
  "evidence": []
}
```

示例中的 `<...>` 是报告 metavariable，不是可直接拿去跑 schema 的 fixture 值；
真正 fixture 必须使用满足 pattern/长度约束的 ID、snapshot 和 64 位十六进制 digest。

上面两个对象只是可读示例。可执行实现必须发布真正的 `outputSchema`；建议的
第一版机械 shape 如下（长度上限仍可在冻结 schema 时收紧）：

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Intatis search_knowledge result v1",
  "$defs": {
    "digest": {
      "type": "string",
      "pattern": "^sha256:[0-9a-f]{64}$"
    },
    "conceptLocator": {
      "type": "object",
      "additionalProperties": false,
      "required": ["kind", "start", "end"],
      "properties": {
        "kind": { "const": "utf8-byte-range" },
        "start": { "type": "integer", "minimum": 0 },
        "end": { "type": "integer", "minimum": 1 }
      }
    },
    "sourceLocator": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "schema",
        "source_id",
        "source_revision",
        "adapter_identity",
        "adapter_version",
        "kind",
        "value"
      ],
      "properties": {
        "schema": { "const": "intatis-source-locator/1" },
        "source_id": { "type": "string", "minLength": 1, "maxLength": 256 },
        "source_revision": { "$ref": "#/$defs/digest" },
        "adapter_identity": { "type": "string", "minLength": 1, "maxLength": 256 },
        "adapter_version": { "type": "string", "minLength": 1, "maxLength": 256 },
        "kind": {
          "enum": ["utf8-byte-range", "line-range", "page", "dom-path", "layout-node"]
        },
        "value": { "type": "string", "minLength": 1, "maxLength": 2048 }
      }
    },
    "supportingConcept": {
      "type": "object",
      "additionalProperties": false,
      "required": ["concept_id", "concept_revision", "concept_locator"],
      "properties": {
        "concept_id": { "type": "string", "minLength": 1, "maxLength": 1024 },
        "concept_revision": { "$ref": "#/$defs/digest" },
        "concept_locator": { "$ref": "#/$defs/conceptLocator" }
      }
    },
    "producer": {
      "type": "object",
      "additionalProperties": false,
      "required": ["identity", "version", "at"],
      "properties": {
        "identity": { "type": "string", "minLength": 1, "maxLength": 256 },
        "version": { "type": "string", "minLength": 1, "maxLength": 256 },
        "at": { "type": "string", "format": "date-time" }
      }
    },
    "evidence": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "evidence_id",
        "rank",
        "text",
        "text_sha256",
        "evidence_uri",
        "evidence_class",
        "source_ids",
        "status",
        "stale"
      ],
      "properties": {
        "evidence_id": {
          "type": "string",
          "pattern": "^ev_[A-Za-z0-9._-]{1,128}$"
        },
        "rank": { "type": "integer", "minimum": 1, "maximum": 20 },
        "text": { "type": "string", "minLength": 1, "maxLength": 4096 },
        "text_sha256": { "$ref": "#/$defs/digest" },
        "evidence_uri": {
          "type": "string",
          "pattern": "^knowledge://[A-Za-z0-9._~!$&'()*+,;=:@%/-]+$",
          "maxLength": 2048
        },
        "concept_id": {
          "type": "string",
          "minLength": 1,
          "maxLength": 1024
        },
        "concept_revision": { "$ref": "#/$defs/digest" },
        "evidence_class": {
          "enum": ["exact_concept_slice", "generated_derivative"]
        },
        "concept_locator": { "$ref": "#/$defs/conceptLocator" },
        "supporting_concepts": {
          "type": "array",
          "minItems": 1,
          "maxItems": 64,
          "items": { "$ref": "#/$defs/supportingConcept" }
        },
        "producer": { "$ref": "#/$defs/producer" },
        "source_ids": {
          "type": "array",
          "minItems": 1,
          "maxItems": 64,
          "uniqueItems": true,
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 256
          }
        },
        "source_locators": {
          "type": "array",
          "minItems": 1,
          "maxItems": 64,
          "items": { "$ref": "#/$defs/sourceLocator" }
        },
        "trust": { "type": "string", "minLength": 1, "maxLength": 128 },
        "status": { "enum": ["draft", "stable", "deprecated"] },
        "stale": { "type": "boolean" }
      },
      "allOf": [
        {
          "if": {
            "properties": { "evidence_class": { "const": "exact_concept_slice" } }
          },
          "then": {
            "required": ["concept_id", "concept_revision", "concept_locator"],
            "not": {
              "anyOf": [
                { "required": ["producer"] },
                { "required": ["supporting_concepts"] }
              ]
            }
          }
        },
        {
          "if": {
            "properties": { "evidence_class": { "const": "generated_derivative" } }
          },
          "then": {
            "required": ["producer", "supporting_concepts"],
            "not": { "required": ["concept_locator"] }
          }
        }
      ]
    },
    "error": {
      "type": "object",
      "additionalProperties": false,
      "required": ["code", "retryable", "message"],
      "properties": {
        "code": {
          "enum": [
            "TOOL_INPUT_INVALID",
            "KB_UNKNOWN",
            "KB_ACCESS_DENIED",
            "KB_UNSAFE_STORAGE",
            "KB_OKF_INVALID",
            "KB_PROFILE_INVALID",
            "KB_VERSION_UNSUPPORTED",
            "KB_INTEGRITY_FAILED",
            "KB_INDEX_BACKEND_UNSUPPORTED",
            "KB_INDEX_NOT_READY",
            "KB_EMBEDDING_UNAVAILABLE",
            "KB_EMBEDDING_INCOMPATIBLE",
            "KB_REVISION_CHANGED",
            "RERANK_UNAVAILABLE",
            "SEARCH_BUDGET_EXCEEDED",
            "SEARCH_TIMEOUT",
            "SEARCH_CANCELLED",
            "INTERNAL_ERROR"
          ]
        },
        "retryable": { "type": "boolean" },
        "message": { "type": "string", "minLength": 1, "maxLength": 1024 }
      }
    }
  },
  "oneOf": [
    {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "status",
        "knowledge_base",
        "knowledge_base_revision",
        "retrieval_snapshot",
        "retrieval_snapshot_revision",
        "rerank_applied",
        "truncated",
        "evidence"
      ],
      "properties": {
        "status": { "const": "ok" },
        "knowledge_base": {
          "type": "string",
          "pattern": "^[A-Za-z0-9._-]{1,128}$"
        },
        "knowledge_base_revision": { "$ref": "#/$defs/digest" },
        "retrieval_snapshot": {
          "type": "string",
          "pattern": "^snap_[A-Za-z0-9._-]{1,128}$"
        },
        "retrieval_snapshot_revision": { "$ref": "#/$defs/digest" },
        "rerank_applied": { "type": "boolean" },
        "truncated": { "type": "boolean" },
        "evidence": {
          "type": "array",
          "minItems": 1,
          "maxItems": 20,
          "items": { "$ref": "#/$defs/evidence" }
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "status",
        "knowledge_base",
        "knowledge_base_revision",
        "retrieval_snapshot",
        "retrieval_snapshot_revision",
        "rerank_applied",
        "truncated",
        "evidence"
      ],
      "properties": {
        "status": { "const": "insufficient_evidence" },
        "knowledge_base": {
          "type": "string",
          "pattern": "^[A-Za-z0-9._-]{1,128}$"
        },
        "knowledge_base_revision": { "$ref": "#/$defs/digest" },
        "retrieval_snapshot": {
          "type": "string",
          "pattern": "^snap_[A-Za-z0-9._-]{1,128}$"
        },
        "retrieval_snapshot_revision": { "$ref": "#/$defs/digest" },
        "rerank_applied": { "type": "boolean" },
        "truncated": { "const": false },
        "evidence": { "type": "array", "maxItems": 0 }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["status", "error"],
      "properties": {
        "status": { "const": "error" },
        "knowledge_base": {
          "type": "string",
          "pattern": "^[A-Za-z0-9._-]{1,128}$"
        },
        "knowledge_base_revision": { "$ref": "#/$defs/digest" },
        "retrieval_snapshot": {
          "type": "string",
          "pattern": "^snap_[A-Za-z0-9._-]{1,128}$"
        },
        "retrieval_snapshot_revision": { "$ref": "#/$defs/digest" },
        "error": { "$ref": "#/$defs/error" }
      }
    }
  ]
}
```

JSON Schema 能检查 shape、required、上限和枚举，但不能单独证明 `rank` 连续、
`end > start`、hash 与 text 相符，或 source ID 真存在；这些仍由 Validator 的
evidence-return 模式执行。Schema 的 conditional branch 要求 exact slice 带
`concept_locator`；generated derivative 则必须带 `producer` 和
`supporting_concepts`，并禁止伪装成自己的 exact concept byte range。JSON Schema
2020-12 的 `format` 在部分实现中只是 annotation，Host 必须显式启用/实现
date-time 等 format assertion，不能仅因为 parser 接受字符串就算验证完成。

硬规则：

- `ok` 至少一个 evidence；
- `insufficient_evidence` 必须为空；
- 模型可见的 grounded evidence 至少一个有效 `source_id`；基础 OKF 虽允许无
  `sources` concept，但这种内容不能冒充本工具的 grounded result；
- rank 从 1 连续递增；
- evidence ID/URI 唯一；
- evidence ID 由 snapshot revision、chunk/derivative identity、最终 range/class
  确定性派生；同一 snapshot 的同一 bounded evidence 稳定，但 citation authority
  仍只在当前 turn registry 内有效；
- text/hash/source mapping 返回前重新验证；
- `concept_locator` 与可选的原始 `source_locators` 必须分开表达，后者不存在时不得猜测；
- 不要求公开 reranker score；不同模型 score 不可直接比较；
- tool result 不暴露向量；
- 默认不暴露私有绝对路径；
- evidence 正文作为 untrusted data，不得提升成 system/developer instruction。

第一版结果预算也属于硬合同：单条 evidence 最多 4,096 个 JSON Schema length
单位且最多 16 KiB UTF-8；全部 evidence text 最多 32 KiB UTF-8；完整序列化 tool
result 最多 64 KiB；注入模型前估算最多 12,000 tokens。Host 按最终 rank 顺序装入，
下一条超预算时停止并返回 `truncated=true`。若第一条都无法形成安全、有 provenance
的 bounded evidence，则返回 `SEARCH_BUDGET_EXCEEDED`，不得把超大结果塞进
EventLog/ModelHistory。对 exact slice 可生成更小、重新计算 ID/hash/locator 的
evidence window；generated derivative 必须在建库时已满足单条上限，查询时不得
随意截断后仍沿用原 provenance。

这里必须区分两类 budget：低排名 evidence 在 result packing 时撞到 aggregate、
serialized 或 token 上限，属于成功的 `ok + truncated=true`；candidate scan、内存、
backend response 等执行期 hard budget 在形成可信排序前耗尽，或者第一条 evidence
无法安全缩成单条上限，才返回 `SEARCH_BUDGET_EXCEEDED`。不得把普通 result
packing overflow 误报为整次检索失败。

`knowledge://` 只是本报告建议的 Intatis 内部、opaque evidence URI 形状，并非已经
注册的通用 URI scheme。若未来对外暴露 MCP resource，需另行冻结 URI scheme、
escaping、authority、revision 与授权语义；第一版也可完全不把该 URI 暴露给外部。

### 7.6 Grounding/citation contract

最终 LLM 只允许引用本 turn 的成功 `search_knowledge` 结果，例如：

```text
[[evidence:ev_01H...]]
```

渲染或导出前，host/Validator 必须确认：

1. evidence ID 来自当前 turn 的成功 tool result；
2. 与 exact knowledge-base revision/retrieval snapshot 绑定；
3. text/evidence hash 未变化；
4. concept locator 仍可重放；若结果还携带原始 source locator，则其 immutable
   source revision 必须匹配 snapshot inventory，且 exact adapter 仍可授权重放；
5. ID 没有跨知识库、跨 session 或跨旧 turn 复用；
6. 模型编造的 ID 不渲染为有效 citation。

该检查能防止“引用不存在”“串库引用”“引用已被替换”，但不能证明回答每句话都被 evidence 语义支持。第一版 model instruction 应明确：证据不足时返回不足，不得用模型常识补成知识库事实。

### 7.7 Prompt injection 边界

知识库内容可能包含恶意指令。工具必须：

- 将全部正文标记为不可信 evidence data；
- 不把内容拼进 system role；
- 不执行正文中的命令、Skill、URL 或工具请求；
- 不因 OKF `type`/`verified` 提升指令权威；
- 不自动打开 source URI；
- 对可疑内容可以附加 machine-readable warning，但不得改写 evidence bytes；
- 最终模型仍只能通过 authoritative tool list 和现有权限链执行动作。

### 7.8 权限和 durable execution

即使是只读工具，也必须进入：

```text
ToolRegistry registration
  -> strict schema validation
  -> exact CapabilityLease membership
  -> existing WorkspaceLease + PathConfinement
  -> DeterministicPolicyGate
  -> ModelPermissionReviewer (may only narrow a gate pass)
  -> PermissionEngine / current PermissionResponder
  -> durable permission request + first-terminal settlement when required
  -> ResolvedToolAuthorization exact snapshot
  -> durable tool_execution_prepared
  -> WorkspaceLease/PathConfinement/root/snapshot/runtime revalidation
  -> execution
  -> durable tool_result + settlement
```

当前已实现 P0 仍只支持现有 WorkspaceLease 内的 knowledge store。08-10 主合同已经决定支持
workspace 外路径；落地前必须先设计并测试独立 `KnowledgeLease`/bookmark/CLI exact authorization/
lifecycle。新合同不是跳过现有边界的理由。即使 deterministic gate 判定只读 pass，也不能省略
reviewer、PermissionEngine、authorization correlation 或 durable lifecycle。

若 embedding/reranker 走远程服务，则 query 或候选正文外发是 network/data-egress 行为，不能藏在“只读 search”名称下面绕过 provider/credential/permission/audit。Local-only 和 remote-backed route 必须有不同的 exact execution semantics。

第 8 节的 build/publish host seam 具有写文件、计算 embedding、可能联网和原子切换
snapshot 的副作用，同样必须走上述 lease、三层权限、durable ticket 和 settlement；
不能让 Agent 通过 raw file/terminal 操作绕过它。

当前源码只实现了该 host seam，并在执行入口复核 exact `ResolvedToolAuthorization`、
WorkspaceLease、capability、network risk 和 immutable snapshot；它不会自行伪造 durable ticket。
本轮没有注册 model-facing `build_knowledge`，也没有把外部 Agent producer caller 接进
AgentLoop。因此上段是未来实际 caller 的强制接线合同，不能从 build service 的单元测试外推为
“建库 Agent durable 生命周期已经接通”。

### 7.9 建议失败码

| Code | 含义 | 默认 retryable |
| --- | --- | ---: |
| `TOOL_INPUT_INVALID` | 合法 tool call 的 arguments 不符合 `search_knowledge` inputSchema | false |
| `KB_UNKNOWN` | handle 不存在、过期或未挂载 | false |
| `KB_ACCESS_DENIED` | current caller/lease 无权使用 | false |
| `KB_UNSAFE_STORAGE` | path/symlink/owner/mode/root identity 不安全 | false |
| `KB_OKF_INVALID` | OKF conformance 失败 | false |
| `KB_PROFILE_INVALID` | Profile schema/field 失败 | false |
| `KB_VERSION_UNSUPPORTED` | OKF/Profile version 不支持 | false |
| `KB_INTEGRITY_FAILED` | 文件/chunk/source/index hash 不一致 | false |
| `KB_INDEX_BACKEND_UNSUPPORTED` | 没有 exact backend adapter | false |
| `KB_INDEX_NOT_READY` | 建库未完成或 snapshot/index component 不完整 | true |
| `KB_EMBEDDING_UNAVAILABLE` | exact query embedding runtime 不可用 | true |
| `KB_EMBEDDING_INCOMPATIBLE` | revision/dimension/normalization/metric/instruction 不兼容 | false |
| `KB_REVISION_CHANGED` | 无法维持查询 snapshot | true |
| `RERANK_UNAVAILABLE` | policy 要求 rerank 但 exact runtime 不可用 | true |
| `SEARCH_BUDGET_EXCEEDED` | 执行期 candidate/memory/backend hard budget 耗尽，或第一条 evidence 无法安全装入 | false |
| `SEARCH_TIMEOUT` | 有界超时 | true |
| `SEARCH_CANCELLED` | caller/turn/task 取消 | false |
| `INTERNAL_ERROR` | 清洗后的内部错误 | 视具体 kind |

`insufficient_evidence` 不是 tool error。未知 tool、无效 JSON-RPC envelope，或不满足
外层 `CallToolRequest` 结构（包括该协议版本 required `_meta`）属于 protocol error。
一个结构合法的 CallToolRequest 若只是 `arguments` 不符合本工具 `inputSchema`，则是
`TOOL_INPUT_INVALID` typed tool result，不得与 outer protocol malformed 混为一类。
已进入工具后的知识库业务失败同样是 typed tool execution error。

对不可信调用面，Host 可把 `KB_UNKNOWN` 与 `KB_ACCESS_DENIED` 归一为同一个无细节
的 caller-visible 结果，避免用错误码探测 handle 是否存在；内部 durable settlement
仍保留准确 typed source，且两种情况都不得泄露路径、owner 或 snapshot metadata。

若将来映射为 MCP：`ok` / `insufficient_evidence` 使用符合上述 outputSchema 的
`structuredContent`，`isError` 省略或为 `false`；tool arguments invalid 与其它
domain failure 返回 `status: "error"`、符合相同 outputSchema，并设 `isError: true`。
只有前述 outer protocol/CallToolRequest 错误走 JSON-RPC protocol error（无效参数
通常是 `-32602`）。Intatis 内部工具即使不经过 MCP，也应保留相同 typed outcome。

### 7.10 MCP-compatible，但不是 MCP Server

MCP 2026-07-28 很适合借用为接口形状：

- Tools 是 model-controlled；
- `inputSchema` / `outputSchema` 默认 JSON Schema 2020-12；
- 完整 `CallToolResult` 必须包含 `resultType: "complete"` 与 `content:
  ContentBlock[]`；`structuredContent` 承载符合本报告 outputSchema 的 evidence；
- Resource link/embedded resource 可表示额外证据；
- server 有 outputSchema 时必须返回符合 schema 的结构化结果，client 应复核；
- stateless core 与安全指导适合显式 handle；MCP 将 handle 视为 name 而不是 capability，并建议逐次授权；
- Intatis 自身合同把“每次调用重新授权”提升为硬要求，这不是声称 MCP 协议层替 Intatis 强制执行。

未来 adapter 的 envelope 固定为：

```text
CallToolResult
  resultType: "complete"
  content: [bounded, sanitized ContentBlock ...]        # required transport field
  structuredContent: <exact outputSchema payload>
  isError: false | true
```

`content` 与 `structuredContent` 不得表达互相矛盾的结果；若为旧 client 提供
TextContent 兼容序列化，它与 structured payload 的重复 bytes 也计入 64 KiB 总预算，
Intatis 注入模型上下文时必须去重。Required request `_meta` 由 MCP adapter envelope
负责，不进入 `search_knowledge` 的业务 inputSchema。当前内部工具不依赖 MCP
envelope；这只是未来映射必须满足的完整合同。

但当前 Intatis 是 external MCP client-only。第一版 `search_knowledge` 应是内部 Intatis 工具，只保持 schema/result 易于未来映射。任何外部 MCP Server、hosting、server auth 和 resource service 都需要另行产品决策，不能由本报告隐式授权。

## 8. 建库 Agent 工作流合同

### 8.1 Agent 负责的语义工作

模型适合做：

- 识别知识概念和边界；
- 清理噪音、统一术语；
- 组织 Markdown；
- 生成 title/description/tags；
- 提议 sources 映射；
- 生成摘要和关键词；
- 通过标题、段落和列表组织影响自然语义边界；
- 可提出切片建议，但 P0 最终 chunk boundaries 由 deterministic host chunker 决定；
- 识别冲突、陈旧或待人工验证内容。

### 8.2 宿主必须负责的机械事实

模型不得自报并被直接信任：

- canonical source URI/path；
- source file revision/hash；
- byte/page/line locator；
- exact slice bytes；
- concept/chunk/evidence stable ID；
- profile/schema version；
- embedding/model/index component 与 retrieval snapshot identity；
- permission scope；
- index completeness；
- atomic publish 成功；
- human verification 身份。

### 8.3 Adapter 内必须有 host-owned build/publish seam

四个产品组件不等于“四个源文件”。第二个组件（薄 Profile/adapter）内部必须提供
一个窄的 host service seam，暂称 `KnowledgeBundleBuildService`，承担：

- 创建并持有 staging snapshot；
- 接收 Agent 生成的 OKF draft，但不信任其机械字段；
- canonicalize source/concept identity、concept locator 与 digest；当前 build request 不接收、chunker
  也不生成原始 source locator，因此该字段保持省略。standalone/prebuilt snapshot 的 mount/search/final
  路径已能验证和重放 locator；未来 producer/adapter extension 若提供该字段，只能接受已授权的
  versioned shape，并由 exact adapter 验证/重放，不从 source URI 或正文猜造；
- 用冻结的 deterministic chunker 生成 chunk manifest；
- exact resolve embedding/index adapter，构建派生组件；
- 调用同一个 Validator；
- 在 exclusive writer lease 下发布完整 immutable snapshot 并原子切换 pointer。

它属于“薄 adapter”的内部实现 seam，不是第五个独立 RAG 子系统。2026-08-09 实现没有把它注册为
模型工具；08-10 主合同已经决定在该 seam 外增加正式 model-facing `build_knowledge`
ToolRegistration。其 schema、配置、外部路径权限和完成门槛以主合同为准。该 seam 不得通过 raw
terminal/file edits 模拟，且必须遵守第 7.8 节的完整权限与 durable execution 链。

### 8.4 staging-first

建库 Agent 只能产出 staging draft；真正 snapshot 由 host service 写：

```text
build request
  -> KnowledgeBundleBuildService obtains writer/authorization lease
  -> staging snapshot directory
  -> Agent outputs OKF concept/profile drafts
  -> host canonicalizes IDs/concept locators/hashes
     (current build omits original source locators)
  -> future producer/adapter extension may supply locators for exact validation/replay
  -> deterministic host chunking
  -> exact embedding/index build
  -> deterministic validation
  -> publish exact immutable snapshot
```

Validator 未通过时：

- 不挂载；
- 不更新 active snapshot；
- 不把 partial index 当成功；
- 保留有界、无秘密的 diagnostics；
- Agent 可以根据 diagnostics 再修复 staging，但不能自己宣告 valid。

P0 的 chunker 必须是 deterministic host code（例如按 OKF heading/paragraph，再按
冻结 tokenizer/window/overlap 规则切分）。模型可以先把知识组织成更好的 concept
结构，但不能直接决定不可复算的 byte boundary。若未来允许模型语义切片，则完整
boundary manifest、模型/模板/输入 provenance 必须成为 canonical derivative；重建
只能重放该 manifest，不能声称仅靠 concept bytes 和普通 chunker config 可重算。

### 8.5 模型生成的总结如何处理

模型总结是 generated derivative，不是原始来源。正确 evidence record 必须同时保留：

- generated text；
- producer/version/time；
- 支撑它的 exact source IDs/locators；
- generated text hash；
- verification status。

没有 independent verification 时保持 unverified。不能为了检索效果把总结写成 `human-reviewed`，也不能删除原始 evidence mapping。

## 9. 生命周期、更新和删除

### 9.1 状态机

```text
draft
  -> staging
  -> validated
  -> published
  -> mounted
  -> queried
  -> deprecated/replaced
```

只有 `validated` snapshot 可进入 `published`。`mounted` 是运行时 host 状态，不写回知识真值。

### 9.2 增量更新

最小增量策略：

- 对 concept/chunk 做 content hash；
- 未变化 chunk 可在新 snapshot 中复用同 exact embedding compatibility key 的向量 bytes；
- 新增/修改 chunk 重新 embed；
- 删除 chunk 写入新 snapshot 的 absence/tombstone；
- 重建受影响 lexical/dense metadata；
- 新 snapshot 完整校验后一次发布。

即使物理层复用 content-addressed objects，validation 也必须证明最终 snapshot 完整，
不能只证明“变更的那几条成功”，更不能让新 snapshot 引用已被 GC 的旧 object。

### 9.3 何时必须全量重建

以下变化通常要求所有 affected chunks 重建：

- text normalization；
- chunker/version/parameters；
- embedding weights/revision；
- tokenizer；
- dimension/scalar/quantization；
- pooling/normalization/metric；
- document/query instruction；
- max-input/truncation policy；
- index backend 的不兼容格式升级。

### 9.4 删除语义

删除必须从：

- OKF concept/source references；
- chunk manifest；
- lexical index；
- dense index；
- active evidence mapping；

在同一新 snapshot 中一致消失。不能只删 Markdown 而让旧向量继续命中。

必须区分两种删除：

1. **普通逻辑删除/更新**：原子切换到不含该知识的新 snapshot；已有 reader 可以在
   lease 到期前完成旧查询。旧 handle 不再接受新调用，旧 snapshot 按明确 retention
   policy 等待 reader drain 后才进入 GC。
2. **敏感内容紧急清除**：先关闭该 store/snapshot 的新 admission，撤销相关 handle，
   取消并 drain 在途查询，清除 host-side receipt/cache，再在 exclusive writer lease
   下删除所有包含该内容的旧 snapshot/component/object。不能允许旧查询继续返回。

GC 必须持有 store writer lease，并确认 snapshot 没有 reader lease、不是 current、
不被其它 content-addressed snapshot 引用。APFS/SSD、备份、日志和远端 provider 的
物理擦除保证另有边界；若不能证明 secure erasure，产品只能声明“Intatis active
store 与受控缓存已删除”，不得宣称底层介质字节不可恢复。

现有 EventLog 是 append-only canonical truth，durable `tool_result` 可能保留曾返回给
模型的 bounded evidence。因此 P0 必须明确：删除 knowledge store **不自动删除既有
session history**；强清除还需要用户删除相关 session，或未来先实现“EventLog 只存
opaque encrypted artifact reference、按 snapshot key 销毁”的兼容设计。后者会改变
持久化合同，未经单独设计/迁移不得假装已经存在。最少代码版本以严格结果预算降低
暴露面，并在删除文案中清楚声明这一历史副本边界。

## 10. 最少代码原则

### 10.1 只保留四个产品 seam

```text
Pinned Standard
Thin Profile Adapter
Deterministic Validator
search_knowledge Tool
```

不先做：

- RAG 平台；
- plugin ABI；
- graph database；
- 多向量数据库自动路由；
- 多套静默 fallback；
- 独立 daemon/server；
- Chat/iOS/UI；
- 一组模型可见的底层 retrieval 工具。

### 10.2 最大化复用现有 Intatis 边界

后续实现应复用：

- Agent 作为 producer；
- ToolRegistry/strict schema；
- PermissionEngine 与 ResolvedToolAuthorization；
- CapabilityLease/WorkspaceLease/PathConfinement；
- durable tool execution ticket；
- provider exact connection/profile/revision 思想；
- owner-only/no-follow/atomic-write 经验；
- EventLog 记录调用生命周期；
- ArtifactStore/index 的“派生、可重建”原则；
- 现有 BM25 scorer/tokenizer 的适用部分，但必须先核对 provenance 和语料适配。

不要复用：

- MCP tool catalog 的索引文件作为知识库；
- Chat hosted search；
- UI transcript/ModelHistory 作为知识库；
- ArtifactStore `index.json` 作为 vector index；
- 外部 parser 的私有 IR 作为最终标准。

### 10.3 实现候选不是本报告依赖决策

只作为后续 spike 方向：

- [SwiftIndex](https://github.com/alexey1312/swift-index)：架构参考，尤其是 Swift-native protocol、SQLite/FTS、content hash、hybrid/RRF；项目仍年轻，不建议整包接管 Intatis state。
- [VecturaKit](https://github.com/rryam/VecturaKit)：模块化边界较干净，适合作为首个完整 RAG 集成试验候选；其 persistence 仍只能是可重建派生索引。
- [Wax](https://github.com/christopherkarani/Wax)：功能完整但带自有 `.wax`/WAL/存储生命周期，适合 isolated performance/recovery 对照，不能成为 canonical knowledge truth。
- [MLXEmbedders](https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXEmbedders)：Apple Silicon local embedding 候选；Intatis 同时发行 x86_64，在确定独立 Intel backend/route 前，不得成为 universal macOS 的唯一后端。
- 固定模型的 Core ML：正式发行候选，优点是模型/runtime 可控；但 tokenizer、pooling、模型转换来源和许可证必须另行固定与验证。
- [swift-embeddings](https://github.com/jkrukowski/swift-embeddings)：可做早期 spike；项目仍早期，已知并发 forward 风险意味着至少需要 actor/single-flight 隔离和压力测试。
- [llama.cpp](https://github.com/ggml-org/llama.cpp)：仅作为 GGUF、Intel macOS 或未来 Linux 兼容后端候选；大型 C/C++ runtime 必须 non-iOS、按平台隔离，macOS/CLI/Linux 分别固定并审计，不能隐式进入 iOS。
- SQLite/FTS5 + [sqlite-vec](https://github.com/asg017/sqlite-vec)：中小知识库的最小 exact KNN 候选；实验性 ANN alpha 不应直接成为 P0 release dependency。
- [USearch](https://github.com/unum-cloud/usearch)：更大规模 HNSW 候选；metadata、事务、证据仍须留在 Intatis/SQLite 侧。

任何采用都必须另做许可证、精确 commit、传递依赖、模型文件许可证、universal macOS、iOS linkage、NOTICE 和性能审查。

## 11. 安全与威胁模型

| 威胁 | 失败模式 | 必需缓解 |
| --- | --- | --- |
| 知识 prompt injection | evidence 指示模型忽略系统或执行工具 | 作为 untrusted data；不提升 role；动作仍走 authoritative tools/permissions |
| Poisoned knowledge | 恶意或错误内容被高排名返回 | provenance/trust/freshness；多源；评测；不伪称确定性真值 |
| Path traversal/symlink swap | bundle 引用逃出 root 或 validate 后换文件 | canonical root、no-follow、identity revalidation、immutable snapshot |
| Index poisoning | ANN key 指向错误 chunk | 结果 ID 回查 chunk manifest；重新计算 evidence hash/source mapping |
| Embedding mismatch | 新 query vector 与旧 index 不可比较 | exact compatibility key；任一字段不同 fail closed |
| Stale source | 已变更来源继续被旧 evidence 引用 | snapshot revision 或 live source revalidation；stale policy |
| Permission leakage | 一个 agent 查询另一个 scope 的知识 | handle 每次授权；host filter；模型不能放宽 |
| Secret leakage | source/tool error/index 包含 credential | SecretScanner；schema 禁 secret fields；diagnostic sanitizer；bounded result |
| Remote data exfiltration | embedding/reranker 隐式发送 query/evidence | exact remote route + network/data-egress permission；无隐藏 fallback |
| Oversized bundle/DoS | 巨量文件/chunk/candidates 消耗内存/CPU | 文件/深度/字节/候选/token/timeout bounds；streaming/bounded reads |
| Partial publish | 一半新 index 被查询 | staging + validation + immutable snapshot + atomic activation |
| Cross-turn fake citation | 模型引用旧/虚构 evidence ID | turn-bound evidence registry + final citation validation |

## 12. 验收标准与测试矩阵

### 12.1 OKF/Profile parser

- 最小合法 OKF concept；
- invalid YAML；
- custom tag/alias expansion 由 host safety policy 拒绝，但不误标为 OKF 基础 conformance error；
- missing/empty `type`；
- root `index.md` version；
- reserved file shape；
- unknown type/key 保留；
- v0.1 `timestamp`/Citations read fallback；
- new writer 只写 v0.2；
- broken ordinary cross-link 是 warning，但 grounding-required link 是 strict failure；
- duplicate source ID；
- bare verified mapping 归一为一项。

### 12.2 文件系统与完整性

- `..`、absolute escape、symlink/hardlink/special file；
- root identity replacement；
- unsafe owner/mode；
- missing/unlisted/extra critical file；
- wrong size/hash；
- oversized/deep/too-many-files；
- validate-then-reopen race；
- unsafe/escaping `.intatis-rag-store.json` pointer；
- snapshot 中 concept/chunk/profile/index 任一部分被原地替换；
- host-side receipt 复制、过期或 backend registry 改变；
- partial snapshot；
- atomic old/new snapshot query isolation；
- writer publish 与多个 reader drain/GC 竞争。

### 12.3 Chunk/provenance

- exact UTF-8 byte-range round trip；
- Unicode normalization/line ending fixture；
- invalid range/boundary；
- generated derivative 与 exact slice 不混淆；
- generated derivative 缺 producer/support、或伪造 exact concept locator 时拒绝；
- deterministic chunk manifest 重建一致；模型边界 manifest 不得伪称可重建；
- versioned source locator union、immutable source revision、exact adapter identity/version 重放与 source ID 对应；
- missing source ID；
- concept revision drift；
- duplicate chunk/evidence ID；
- overlapping chunks合法但 count 不重复；
- source deletion/tombstone 完整传播。

### 12.4 Embedding/index

- model revision mismatch；
- tokenizer mismatch；
- runtime binding/backend format/adapter version mismatch；
- dimension/scalar/quantization/pooling/normalization/metric mismatch；
- query/document instruction、max-input/truncation mismatch；
- NaN/Inf/wrong vector length；
- orphan/duplicate/missing vector key；
- count/digest mismatch；
- unsupported backend；
- multiple compatible/incompatible retrieval snapshots；
- current snapshot 不兼容时 typed fail，绝不扫描 retained snapshot fallback；
- A/B 只有 host 显式 exact-snapshot handle 才可查询；
- composite snapshot 不能混用不同 snapshot 的 dense/lexical/reranker；
- required lexical/dense/rerank unavailable；
- optional rerank 明确 `rerank_applied=false`；
- full rebuild gate after semantic config change。

### 12.5 Validator determinism

- 同 snapshot/policy/registry 两次产生相同 diagnostics/order/semantic verdict；审计时间等 envelope 字段单独比较；
- 无 LLM/network side effect；
- unknown profile version fail closed；
- receipt 复制到不同 root 无效；
- warning 不可升级安全关键 error；
- secret/URL/path 不进入 diagnostics；
- cancellation/timeout 不留下 valid receipt。

### 12.6 `search_knowledge`

- strict inputSchema/additionalProperties false；
- MCP adapter 区分 outer CallToolRequest protocol error 与 `TOOL_INPUT_INVALID`；
- MCP complete result 包含 required `resultType`、`content`、structuredContent/isError，且重复内容计入总预算；
- unknown/expired handle；
- current caller authorization；
- 完整 DeterministicPolicyGate → ModelPermissionReviewer → PermissionEngine → durable settlement 链；
- mixed-ACL corpus 在召回 partition 前过滤，不能全库 Top-K 后过滤；
- query normalization/embedding compatibility；
- dense-only、hybrid、rerank-required/optional；
- permission filter 在 rerank 前后均不泄漏；
- stable rank、dedupe/source diversity；
- result bytes/token/limit bounds；
- `ok` / `insufficient_evidence` / `error` 三个 outputSchema branch；
- per-evidence/aggregate/serialized/token budget 与 deterministic `truncated`；
- result packing overflow 返回 partial `ok + truncated`，执行期 hard budget/首条不可装入才返回 `SEARCH_BUDGET_EXCEEDED`；
- insufficient evidence；
- timeout/cancel cleanup；
- snapshot update during query；
- result ID 回查和 evidence hash；
- prompt injection content 保持 data；
- remote embedding/rerank 进入网络权限链；
- EventLog/durable execution settlement 关联完整。

### 12.7 Citation/grounding

- current-turn evidence ID 通过；
- fabricated ID 拒绝；
- old-turn/cross-session/cross-KB ID 拒绝；
- snapshot/hash drift 拒绝；
- private source path 不泄漏；
- evidence text/concept locator 精确；存在原始 source locator 时再单独验证它；
- semantic entailment 明确不由 mechanical validator 宣告通过。

### 12.8 质量评测

在选择 embedding/reranker 前建立真实中英文/代码/内部文档 corpus：

- Recall@K；
- MRR/nDCG；
- answerable vs unanswerable；
- stale/deprecated filtering；
- provenance precision；
- citation correctness；
- injection resistance；
- latency、memory、index size；
- incremental update/delete correctness；
- Apple Silicon 与 Intel macOS 的实际能力差异。

没有这套 eval，不能仅凭开源项目 README 或单个 demo 决定模型/索引。

### 12.9 Snapshot lifecycle / delete

- ordinary update 只让新 query 看见新 snapshot，旧 reader 可在 lease 内完成；
- old handle 不接受新调用；reader drain 后才能 retention GC；
- current snapshot、仍有 reader 或被 content-addressed 引用的 object 不可 GC；
- urgent purge 关闭 admission、撤销 handle、cancel/drain、清 host receipt/cache，再删除；
- crash 在 staging、rename、pointer update、GC 任一边界后都能恢复到一个完整状态；
- P0 删除测试明确证明 active store/cache 不再可查，并明确既有 EventLog/session
  history 是否仍含 bounded evidence；强清除若要求删除历史，必须联动 session 删除
  或经过另行设计的 encrypted-artifact indirection；
- 无法证明 APFS/SSD/backup secure erasure 时，产品文案不得声称物理不可恢复。

## 13. 分阶段落地顺序

### Phase 0：标准固定和合同冻结（完成）

1. 下载 fixed OKF spec/license；
2. 记录 upstream/provenance/hashes；
3. 完成许可证/NOTICE 决策；
4. 冻结 stable store + complete immutable snapshot layout 和分层 digest projection；
5. 冻结 P0 仅限现有 WorkspaceLease、reader/writer lease、atomic publish、retention/GC/urgent-purge 合同；
6. 冻结 `Intatis OKF RAG Profile 0.1` JSON Schema；
7. 冻结 chunk/evidence/validation/tool schemas；
8. 先建立最小真实中英文/代码 corpus、ground-truth queries 和 valid/invalid fixtures。

Gate：不写检索业务代码前，先让 schema 和 fixture 能回答“什么叫一个可用知识库”。

### Phase 1：薄 adapter + Validator + local backend 验证（core 已实现；Intel 真机 release gate 仍开放）

1. OKF reader；
2. profile/chunk reader；
3. deterministic validation；
4. validation receipt；
5. host-owned `KnowledgeBundleBuildService` skeleton；
6. complete snapshot staging/publish/reader-drain contract；
7. 在 Phase 0 corpus 上隔离试验候选 embedding/dense backend；
8. 验证 Apple Silicon、Intel macOS、许可证、模型来源、内存/延迟后只选一条 P0 route；
9. path/identity/hash/concurrency tests。

Gate status：手写 fixture 的 deterministic valid/invalid 与本机 local route 已通过，Validator 没有
模型参与；universal-macOS 的 Intel 真机、最低支持 macOS 与 release-device gate 仍为 `OPEN`。
当前仅继续实现 non-shipping local core，不能把 cross-build 或本机量化结果写成 universal gate 已过；
shipping 前若候选未通过，Phase 1 release 停止，不用未经验证的 backend 填空。

### Phase 2：建库 Agent producer workflow（host build/publish seam 完成；上游生产者工作流不在本报告接线）

1. 现有 Agent 写 staging OKF；
2. host service 生成 IDs、concept locators、hashes 和 deterministic chunks；当前 build seam 省略原始
   source locators。已实现的 locator schema/replay 用于 standalone/prebuilt snapshot；未来生产者/adapter
   extension 才可提供该可选字段，host 只做 exact schema/revision/replay 验证，绝不猜造；
3. 使用 Phase 1 选定的 exact embedding/index adapter；
4. validator feedback → Agent 修复；
5. validated complete-snapshot publish。

Gate status：`NOT RUN in current scope`。从原始材料开始的 Agent producer E2E 与 durable caller 由外部
解析/清洗工作流负责；本轮只验证 host build/publish seam 及其更新、删除、重开机械合同。

### Phase 3：`search_knowledge` 最小查询链（完成；host opt-in，默认不暴露）

1. host mount/opaque handle；
2. exact query embedding；
3. 一个确定的 dense backend；
4. evidence resolve/hash/source validation；
5. strict structured tool result；
6. Code/Cowork internal tool integration。

Gate：不接 Chat/UI；模型能用工具回答并只引用返回 evidence。

### Phase 4：hybrid + rerank + 扩展 eval（local 机制与冻结 corpus 已验证；设备/大规模/真实增益 gate 仍开放）

1. lexical/BM25；
2. RRF；
3. exact reranker route；
4. candidate/context policy；
5. 在既有 corpus/ground truth 上扩展 hybrid/reranker 对照 eval；
6. performance/memory/Intel/Apple Silicon gates。

Gate：只有量化结果证明收益才扩大 backend 或模型矩阵。

### Phase 5：产品化决策（历史 deferred；08-10 主合同已部分确定）

08-10 主合同已经确定：自然语言 workspace 内/外 path、独立 `KnowledgeLease`、无 Knowledge 管理 UI/
mount command、正式 `build_knowledge`、path-aware `search_knowledge`、canonical
`embedding_model`/`reranker_model`，以及 required semantic rerank。

仍然 deferred：外部 MCP、remote vector store、Chat/iOS、share/export/import、automated source
refresh。

## 14. 本报告内已冻结并由 core 实现的原则（product surface 例外见 08-10 主合同）

这里“冻结”表示后续设计不得无说明地偏离用户确认的四组件方向。Phase 0 的标准、schema、
依赖和 provenance，Phase 1/3 的本地 core、Phase 2 的 host build seam 以及 Phase 4 的本地机制已进入
当前源码；Agent producer durable caller、外部设备/规模 gate 和 Phase 5 surface 仍按下文边界保留。

- 四组件边界，不新增第五个 RAG 产品组件；
- OKF v0.2 是 canonical knowledge content baseline；
- Intatis Profile 必须薄且可被普通 OKF consumer 忽略；
- index 是派生、可删除、可重建，不是知识真值；
- heavy preprocessing 在建库阶段；
- query 阶段只做 query-specific retrieval/rerank/validation；
- current core 对查询只暴露一个 `search_knowledge`，不拆出 embed/vector/rerank 子工具；08-10 主合同
  另增加 `build_knowledge`；
- current v1 使用 opaque handle；08-10 v2 允许用户提供的 `store_path`，同时坚持 path 不是 authority；
- embedding/reranker/backend 由 host exact resolve，模型不能选择；
- Validator 不用 LLM、不执行 bundle 内容、fail closed；
- generated summary 与 exact evidence 分开；
- citation 只能引用 current-turn returned evidence；
- Knowledge 管理 UI、Chat/iOS/MCP Server 不在首版；现有权限/目录授权呈现不算 Knowledge UI；
- 无静默 fallback；
- 任何外部 runtime/依赖另做许可证与 provenance 审查。

## 15. 实现后收敛项、deferred 与 `UNKNOWN`

### 15.1 已从初始 `UNKNOWN` 收敛

- `ThirdPartyStandards/OpenKnowledgeFormat/0.2/` 已成为固定目录，spec/license/provenance/hash 和
  NOTICE 同步落地；Profile/chunk/evidence/store/checksum/validation/source-locator/search input/output
  共 9 份 schema 已冻结。
- digest 使用 Intatis canonical JSON/SHA-256 projection；bundle、chunk manifest、dense/lexical
  component、retrieval policy、reranker binding、composite snapshot 和 host content seal 分层绑定。
- YAML 选择 Yams 6.2.2 exact dependency；JSON Schema evaluator 为仓内 bounded subset，未引入第二个
  schema package。独立 public non-iOS `IntatisKnowledge` target 已落地，iOS 无 direct/transitive link。
- P0 dense route 选择 Apple NaturalLanguage sentence embedding + Swift `Float32` exact KNN；lexical
  使用多语言/代码 tokenizer + BM25，fusion 使用 RRF。没有引入 sqlite-vec/USearch/MLX 或向量数据库。
- reranker profile 支持 disabled/optional/required exact binding；当前随仓 local provider 是
  embedding-cosine seam，不是 cross-encoder，也不静默下载模型或切 remote。
- source locator 首版只注册 immutable UTF-8 byte range；mount/search/final grounding 使用同一
  executable adapter registry 和 digest。live URL/path 不会在 query 时被执行。
- reader/writer locks、staging、atomic pointer、content seal、reader drain、retention/GC、explicit A/B、
  validation receipt 与 urgent purge 协议已实现。`knowledge://` 当前保留为内部 evidence URI。

### 15.2 后续主合同已提升的实施项与继续 deferred 的边界

08-10 主合同已提升为必须补齐：workspace 外路径与 `KnowledgeLease`、model-facing
`build_knowledge`、path-aware `search_knowledge`、`embedding_model`/`reranker_model` provider
routes、required semantic reranker，以及 Mac Code/Cowork `@main`/CLI 产品接线。

继续 deferred：

- Chat/iOS RAG、外部 MCP Server/resource surface、remote vector store、share/import/export、自动 source refresh；
- 其它 source locator kind、其它 dense/ANN backend；
- HTTP(S) citation renderer/UI；`knowledge://` 不能直接进入现有 hosted-web URL citation surface；
- Agent 语义清洗/外部解析/连接器的具体产品工作流，它们只消费/产生本报告冻结的 bundle seam。

08-10 shipping caller 已将 strict `build_knowledge` 注册进既有 AgentLoop durable execution，service
继续只复核外层 exact authorization；这项旧 gap 已关闭，service 本身仍不得伪造 caller 或事件。

### 15.3 仍为 `UNKNOWN` / release-only 外部门

1. Intel 真机上 exact Apple NaturalLanguage language/revision/dimension 的 availability、检索质量、延迟和
   内存；x86_64 cross-build 已过，但不能替代真机。
2. 大 corpus 的 index size、build latency、query tail latency 与 memory ceiling；当前只有冻结小 corpus
   和 deterministic proxy。
3. shipping remote embedding/reranker adapter、exact route identity、timeout/cancel fixture 已有；真实
   credential/network、首发 model revision、成本与 usage smoke 仍未执行。
4. 当前 eval 能证明冻结 corpus 上的 retrieval/provenance 指标，不能证明任意答案的 semantic
   faithfulness；claim↔evidence 的自然语言蕴含仍不是 deterministic Validator 能力。
5. append-only EventLog 中已提交 bounded evidence 的 retention、跨 store/session 强删除与未来
   encrypted-artifact indirection；current purge 不等于 APFS/SSD/backup secure erase。
6. Developer ID 签名、公证和发行包中的完整 universal runtime closure；本轮只做 unsigned Debug 与
   SwiftPM arm64/x86_64 compile。
7. MCP 2026-07-28 外层 server envelope/resource mapping；内部 `search_knowledge` 不依赖 MCP Server，
   当前仓库仍是 external MCP client-only。
8. 最低支持 macOS 版本上 exact NaturalLanguage model/revision/dimension availability；当前只在本机
   macOS 27/Xcode 27 和 cross-compile 环境验证。
9. hybrid 相对 dense-only、当前 embedding-cosine reranker 相对无 rerank 的独立 comparative uplift；
   当前 aggregate corpus 指标证明冻结 route 达门，不证明每个附加阶段的因果收益。
10. Linux 没有 shipping local NaturalLanguage embedding/mount route；non-Apple buildability 不能写成
    Linux 本地 RAG runtime 已可用。
11. urgent purge 以 current-pointer removal 持久关闭 admission，并以 exact tombstone 阻止旧 receipt
    并发复活；它不是 pointer、receipt 和物理 snapshot 删除三者的跨组件 crash-atomic 事务。崩溃可留下
    不可查询的 orphan/receipt metadata，仍需 host reconciliation，且不构成 secure erasure。

## 16. 官方与一手参考

- [OKF v0.2 固定规范](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/3fcbb9f828c2f23d109c855ee403c3a4c81f3a96/okf/SPEC.md)
- [OKF 仓库 README](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/README.md)
- [OKF v0.2 官方发布说明](https://cloud.google.com/blog/products/data-analytics/okf-v0-2-adds-trust-signals/)
- [OKF Apache-2.0 许可证](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/374e0bc4c644310ff56cdf9c0fe81eccdec862b0/okf/LICENSE.md)
- [MCP 2026-07-28 Tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)
- [MCP 2026-07-28 Resources](https://modelcontextprotocol.io/specification/2026-07-28/server/resources)
- [MCP 2026-07-28 release / stateless core](https://blog.modelcontextprotocol.io/posts/2026-07-28/)
- [BagIt RFC 8493](https://www.rfc-editor.org/info/rfc8493/)
- [RO-Crate 1.3](https://www.researchobject.org/ro-crate/specification/1.3/index.html)
- [DoclingDocument](https://docling-project.github.io/docling/concepts/docling_document/)
- [SwiftIndex](https://github.com/alexey1312/swift-index)
- [VecturaKit](https://github.com/rryam/VecturaKit)
- [Wax](https://github.com/christopherkarani/Wax)
- [MLXEmbedders](https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXEmbedders)
- [swift-embeddings](https://github.com/jkrukowski/swift-embeddings)
- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [sqlite-vec](https://github.com/asg017/sqlite-vec)
- [USearch](https://github.com/unum-cloud/usearch)

## 17. 初始设计阶段项目核对记录（历史）

本节原样保留报告创建时的只读设计审计，时态和 `IMPLEMENTATION NOT STARTED` 结论不再代表
current working tree；实现后的记录见第 18 节。

> **历史提示：** 本节中的“不能写成已实现”和“下一步只做 Phase 0”是实现前的
> 当时结论，已由第 18 节和当前权威 `docs/` 取代，不是现在的执行指令。

### MODEL_CHECK_RESULT

当前模型属于 GPT-5 系列；无法从当前运行上下文确认更精确的公开模型标识。

### PATH_CHECK_RESULT

```text
pwd:      /Users/vita/Vitemis/Intatis
Git root: /Users/vita/Vitemis/Intatis
Result:   MATCH
```

### FILES_WRITTEN

```text
codex-report/08_09_26-13_33-okf-rag-knowledge-bundle-design.md
```

只新增本报告；不修改 Apps、Packages、Package.swift、project.yml、测试源码或当前权威 docs。

### PROJECT_AUDIT_SUMMARY

- 当前产品没有完整 RAG/Knowledge 闭环；
- `Capability.embedding` 仅是枚举，不代表 adapter/index 已实现；
- 当前 BM25 搜索的是 MCP tool metadata；
- 现有文档读取、hosted web search、EventLog/ArtifactStore/history compaction 都不能被称为知识库；
- 未来工具必须保留 ToolRegistry、CapabilityLease、WorkspaceLease、PermissionEngine、durable tool execution 和 EventLog 边界；
- Chat、iOS、MCP Server 明确排除在首版。

### DOCS_CONTENT_SUMMARY

本报告编写前按仓库要求核对了：

- `/Users/vita/Vitemis/AGENTS.md`
- `docs/VERSIONING.md`
- `docs/CURRENT_STATE.md`
- `docs/MACOS_DISTRIBUTION.md`
- `docs/PROJECT_MAP.md`
- `docs/ARCHITECTURE.md`
- `docs/DO_NOT_BREAK.md`
- `docs/OPEN_SOURCE_REUSE.md`
- `docs/TESTING.md`
- `docs/NEXT_TARGET.md`
- `docs/COWORK_PRINCIPLES.md`

采用的当前规则是：v0.40/build 40；Developer ID direct distribution；索引为派生可重建状态；外部复用先固定 commit/license/provenance；Agent 工具无权限旁路；iOS 是 Chat-only 真子集；dated report 不覆盖当前 docs/source。

### VALIDATION_RESULT

实际运行结果：

```text
git diff --check
  PASS (exit 0)

git diff --no-index --check /dev/null <this-report>
  PASS FOR WHITESPACE (exit 1 only because the new file differs; no diagnostics)

JSON fenced blocks parsed with Ruby JSON
  PASS (8 blocks)

Markdown fence count
  PASS (58, even)

trailing whitespace / merge-marker scan
  PASS (no matches)
```

最终 `git status --short` 中，本轮文件只有：

```text
?? codex-report/08_09_26-13_33-okf-rag-knowledge-bundle-design.md
```

同时观察到其它既有/并发改动：

```text
 M Apps/IntatisMac/Sources/ComposerAttachmentSurfaces.swift
 M codex-report/08_09_26-12_08-single-document-tool-open-source-plan.md
 M docs/PROJECT_MAP.md
?? codex-report/08_09_26-13_42-durable-multimodal-context-handoff.md
?? codex-report/08_09_26-13_52-chat-auto-title-design.md
```

本轮未修改或回退这些文件。曾尝试用 Python `jsonschema` 做 Draft 2020-12
meta-validation，但当前环境未安装该 module；因此不宣称运行了正式 schema
meta-validator。JSON 语法检查与三路独立合同复核已通过。

本报告不修改业务源码；未运行 build/test。

### UNCERTAINTIES

详见第 15 节。尤其不能把 OKF v0.2、Profile schema、embedding backend、reranker 或 `search_knowledge` 写成已经实现。

### NEXT_RECOMMENDED_ACTION

下一步只做 Phase 0：在用户明确授权实现后，下载并固定 OKF `3fcbb9f...` 的 `SPEC.md`/`LICENSE.md`，完成 provenance/NOTICE 决策，并先提交 Profile/Validator/tool schema 与 valid/invalid fixtures。不要先接模型、数据库、UI 或 Chat。

## 18. 2026-08-09 实现核对记录

### MODEL_CHECK_RESULT

当前运行模型属于 GPT-5 系列；运行上下文未提供更精确的公开 model ID。

### PATH_CHECK_RESULT

```text
pwd:      /Users/vita/Vitemis/Intatis
Git root: /Users/vita/Vitemis/Intatis
Result:   MATCH
```

### IMPLEMENTED_SCOPE

- Phase 0：OKF/provenance/NOTICE、9 schemas、fixture/corpus 与四组件合同完成；
- Phase 1：thin adapter、Validator/receipt、local embedding/index、immutable store 完成；Intel 真机 gate
  仍 UNKNOWN；
- Phase 2：host-owned build/chunk/embed/validate/atomic-publish seam 完成；外部解析与 Agent 语义生产者
  工作流及其 durable caller/wrapper由其它任务消费该 seam，本轮不新增 model-facing build tool，也不
  宣称 build prepared/result/settled 已接通；
- Phase 3：opaque mount、`search_knowledge`、Code/Cowork optional host injection、durable tool execution 与
  final citation revalidation 完成；默认不暴露；
- Phase 4：BM25/RRF、exact reranker seam、ACL/filter/budget/deadline 与 aggregate frozen-corpus eval
  完成；hybrid/reranker comparative uplift、大 corpus、Intel 真机和真实 remote provider 仍 UNKNOWN；
- Phase 5：UI/CLI mount surface、Chat/iOS、MCP Server、remote store 等按设计明确 deferred。

### VALIDATION_RESULT

以下是 08-09 local-core 收口时的历史直接证据；08-10 当前实现已增至 Knowledge 115/115、
Provider 7/7，并补齐 model-facing build/search、fresh-host 外部库恢复与 anti-bypass 回归，精确现状以
`docs/TESTING.md` 和 08-10 主实施合同为准：

```text
IntatisKnowledgeTests                        106 tests / 0 failures / 0 skips
TurnGroundingEvidenceRegistryTests             6 tests / 0 failures
Cowork durable search_knowledge AgentLoop probe 1 test / 0 failures
Cowork narrow-mailbox negative                  1 test / 0 failures
Knowledge host authority/mount/drain             1 test / 0 failures
final grounding + urgent purge                  1 test / 0 failures
IntatisMac unsigned Debug                    BUILD SUCCEEDED (arm64)
IntatisKnowledge / IntatisCLI arm64 build     PASS
IntatisKnowledge / IntatisCLI x86_64 cross-build PASS
```

冻结 retrieval corpus 当前 Apple NaturalLanguage 结果：Recall@5 `0.882`、MRR `0.681`、
nDCG@5 `0.698`、citation precision `1.000`；200 次 deterministic dense+BM25 proxy 平均
`1.625 ms`（200 次 proxy 总计 `324.994 ms`）。这些数字只描述当前小 corpus/arm64 host，不能外推
Intel、最低支持 macOS、大库、Linux local runtime 或真实 remote route；它们也不是 hybrid/reranker
相对 baseline 的独立增益证明。

### FILES_AND_DOCS

实现新增/修改集中在 `Packages/IntatisKnowledge/`、generic host/grounding seam、Code/Cowork optional
injection，以及 `Package.swift`/`project.yml` 已声明的 non-iOS linkage。当前权威说明同步回写
`docs/ARCHITECTURE.md`、`CURRENT_STATE.md`、`PROJECT_MAP.md`、`DO_NOT_BREAK.md`、
`OPEN_SOURCE_REUSE.md` 和 `TESTING.md`。工作树另有并发多模态/文档工具改动；本报告不归属、回退或
替它们宣称验收。

### REMAINING_UNCERTAINTIES_AND_NEXT_ACTION

剩余边界见第 15.2/15.3 节。面向 release 的下一步先补 Intel/最低支持 macOS、大 corpus、真实 route
和 comparative uplift gates；外部 producer 需要使用建库 seam 时，再由对应工作流接入 durable
caller。之后才单独选择 Phase 5 的 host-owned mount lifecycle/CLI 或 macOS UI；在这些决策前，不
默认向用户、Chat、iOS 或任意 task 暴露知识库工具。
