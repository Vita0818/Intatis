# TESTING

## 外部依赖与禁止兜底验证（Vitemis 强制规则）

本项目继承 `/Users/vita/Vitemis/docs/DEPENDENCY_POLICY.md`。涉及外部能力的变更必须验证：

- exact 外部依赖可用时只调用其官方 API/扩展点，不调用第一方重复实现。
- 依赖缺失、版本不兼容或构建/签名/许可证/平台/安全条件不成立时，产生明确、可诊断失败并停止该能力。
- 失败路径不会切换到 legacy、另一 provider/backend、adapter/shim、cache、mock、简化实现或不完整路径。
- 测试 double 只存在于测试 target，不进入 production selection 或 runtime fallback。
- Review 检查新增 wrapper/adapter/facade 是否仅为官方 API 必需的最薄接线；发现核心能力复制、第二实现或静默降级即判定失败。

文档状态：当前验证矩阵
最近核对：2026-08-21
产品基线：v0.55（build 55）

历史测试数量、性能数字和事故复验保留在 Git 历史及 dated reports；它们不能替代当前
working tree 的验证。这里只记录现行命令、release gate 和最近一次真实结果。

## 环境与产品边界

- 当前 Apple 构建环境：Xcode 27 / Swift 6.x / XcodeGen。
- macOS 默认只验证 Developer ID/direct-distribution `IntatisMac`。
- `xcodegen generate` 后必须确认 target/scheme 清单中不存在已删除的
  `IntatisMacAppStore`，源码/工程也不得恢复 `INTATIS_MAC_APP_STORE` 或专属 App Store
  entitlements；`.macAppStore` 仅可出现在共享协议解码/隔离测试兼容路径。
- iOS 验证只覆盖 Chat 子集，不得链接 Tools、Permission、AgentKernel、Cowork 或 MCP。
- SwiftPM 测试中的 sandbox、managed terminal Seatbelt、Linux bwrap/guard、权限与路径
  围栏仍是产品安全边界，不能因为不做 App Store 而跳过。

## 版本一致性

```sh
xcodegen generate
scripts/check-version-consistency.sh
# 或仅运行同一门槛：make version
```

必须同时满足：

- `project.yml`：`MARKETING_VERSION=0.55`，`CURRENT_PROJECT_VERSION=55`；
- macOS/iOS 参考 Info.plist：`0.55 (55)`；
- 生成的 `Intatis.xcodeproj`：相同版本；
- README、文档索引、CURRENT_STATE 和 PROJECT_MAP：相同当前基线；
- 最终 App bundle：`CFBundleShortVersionString=0.55`、`CFBundleVersion=55`。

旧设计文档、依赖版本、协议 schema 和 dated reports 中的其他 v0.x 不属于该一致性检查。

## SwiftPM 基线

```sh
swift build
swift test
```

外层 managed sandbox 若阻止 nested Seatbelt、process spawn 或 loopback bind，应在允许的真实
host 环境重跑，不能把 sandbox 环境失败直接改写成产品失败，也不能把跳过冒充通过。

高风险改动至少补充对应 focused suite：

```sh
swift test --filter IntatisProvidersTests
swift test --filter IntatisConversationTests
swift test --filter IntatisToolsTests
swift test --filter IntatisPermissionTests
swift test --filter IntatisAgentKernelTests
swift test --filter IntatisCoworkTests
swift test --filter IntatisSharedUITests
```

修改共享provider streaming runtime时，还必须覆盖默认initial + 5 reconnects及1/2/4/8/16秒退避、
status/heartbeat/尚未yield的tool-call fragment后可重连、text/完整tool call/usage/done任一交付后禁止重放、
取消不重连，以及hosted-search unsupported fallback仍使用独立typed acceptance fence。测试不得继续把
“收到任意raw byte”等同于“consumer已经收到语义输出”。

修改 Cowork automatic permission sidecar / reviewer 时，至少运行：

```sh
swift test --filter PermissionReviewProtocolTests
swift test --filter AuthorizationSidecarTests
swift test --filter IntatisPermissionReviewerTests
swift test --filter PermissionReviewControlPlaneTests
swift test --filter AutomaticPermissionReviewTests
swift test --filter DurableMultimodalAgentLoopTests
```

必须覆盖 provider-facing schema decoration（普通/strict/namespace/deferred/collision）：reserved sidecar 是
request-owned provider schema 中的 required string property；对任何 `strict:true` function，必须递归断言
`required == properties.keys` 且 `additionalProperties:false`，生产装饰器也必须在发网前递归 fail closed。
`tool_search` 本身保持不变；provider-bound `tool_search_output` 中的 deferred function/namespace children
必须装饰，同时断言原消息与 durable output 不变。原 business descriptor/schema 不变，只有
deterministic gate 到达 automatic ask 时宿主才消费并验证 sidecar。还要覆盖
sidecar 拆包与 canonical business args、同文案变化不改变 digest/intent/path/retry identity、executor 永不看到
保留字段、同 batch 多 call 独立绑定、valid sidecar 出现在同 turn 下一次 acting request 但不进入 EventLog/durable
model history、reviewer transient exact-args 不进入 permission lifecycle、stripped business call 仍服从既有
bounded/secret-safe history/audit 规则、permission-request receipt round-trip、legacy optional decode，以及图片/PDF
history 不触发 blanket deny 或 full-context resend。missing/malformed/secret-bearing sidecar 必须只写
failed/runtimeFailed `tool_result`，产生 0 个 permission/review event、0 次 reviewer dispatch、0 次 denial-fuse
消耗；必须有同 business args 的 missing → missing → valid 回归。binding mismatch 则单列为 typed fail closed。
另须证明 hard deny、deterministic allow 与 manual flow 不调用 reviewer/不接收 transient input；reviewer prompt
得到 complete safe args + complete string sidecar + mechanical host facts，并负断言 objective/role/deliverable/
userGoal/raw user/assistant history/PDF marker 不存在；gate/lease/authorization 仍为 host authority；plain-text
verdict 对旧 JSON、tool call、无 completion、非成功 finish、多/缺 marker、timeout/cancel/provider/persistence
failure 全部 fail closed。还必须覆盖 manual/nonautomatic 保留字段在 business execution 前拒绝；automatic
responder 缺 bound overload、active/cached duplicate 缺失或更换 invocation、recovered allow 再交付均拒绝；
invocation-free host
`agent.attach` 只能经 dedicated entry + exact prior durable events；live reviewer reason/provider diagnostic 不会
回显 transient input 到 durable state；误注入 in-engine reviewer 的结果不能获得执行权。

得到用户明确的真实网络与计费授权后，还应对当前 exact Agent route 运行：

```sh
INTATIS_REAL_TOOL_SHAPE_DIAGNOSTIC=1 swift test --filter RealProviderSmokeTests/testRealAgentAuthorizationSidecarShapeWhenEnabled
```

该 smoke 使用 `strict:true`，只验证当前 exact Agent route 接受 required string sidecar property，并在 prompt 明示需要时返回
可拆分的 valid sidecar + business arguments；ask-only host enforcement、binding、secret scan、durable isolation 与 fail-closed
语义仍必须由上述离线测试覆盖。本轮尚未运行该真实 provider smoke，不能从 scripted provider 测试外推
线上 route 的 sidecar compliance、token 或 latency。

MCP、browser、managed terminal、OAuth、real provider 和设备测试中明确标为 opt-in 的项目，
必须在具备相应 runtime/credential/网络的环境单独执行。

### OKF / RAG knowledge bundle 专项

修改 OKF/Profile 合同、Validator、build/publish、embedding/index、snapshot store、mount、
`search_knowledge`、final grounding 或 Code/Cowork augmenter 时，至少运行：

```sh
swift build --target IntatisKnowledge --disable-automatic-resolution
swift test --filter IntatisKnowledgeTests
swift test --filter KnowledgeModelProviderTests
swift test --filter CLIProviderAdapterTests
swift test --filter ModelDrivenKnowledgeAgentLoopTests
swift test --filter TurnGroundingEvidenceRegistryTests
swift test --filter ToolRegistryLeaseTests
```

其中 Knowledge suite 必须覆盖：

- 9 份 strict JSON Schema、bounded OKF YAML、alias/custom-tag safety classification；任意层非保留
  `.md` concept 与任意层 `index.md` / `log.md` reserved shape；host-owned canonical v0.2
  writer 对 legacy `timestamp` / `# Citations`、strict `generated.by/at`、footnote claim/definition/source-ID
  join、multi-source per-chunk attribution、bundle-local path、scope descriptor和私有路径的迁移/拒绝；
  source locator exact adapter/revision replay 与 custom registry digest
  continuity；
- WorkspaceLease/root identity、no-follow/owner-only/single-link、path/byte/count/depth bounds、checksum
  inventory/completeness、content-seal/TOCTOU、staging/atomic pointer、reader isolation、retention/GC、
  explicit A/B admission、receipt invalidation、exact purge tombstone 的 concurrent writer race 和
  current/non-current urgent purge；staging、snapshot rename、
  pointer replace 与 GC 四个 crash boundary 均只恢复为完整 old/new/no-current 状态；
- embedding identity 任一支持的语义字段变化都全量 re-embed；不支持的 scalar/quantization/
  normalization/similarity/truncation 明确拒绝。dense zero/non-unit/NaN/Inf/dimension/missing/orphan/
  duplicate 和 lexical tokenizer/count/digest/missing/orphan/duplicate 都有负向验证；
- canonical `chunks.jsonl` 与 manifest digest 在不同运行时钟下 bit-stable；Validator 对同一
  snapshot/policy/registry 双跑报告一致且不调用 embedding/network；build cancel/timeout
  不发布 pointer、不留 validation receipt；
- frozen dense-only/lexical-disabled/optional-unbound/hybrid-required route 精确执行；dense exact +
  BM25 + RRF、status/trust/OKF date-only `stale_after` 和 host ACL 在 Top-K 前过滤、
  optional/required exact reranker、unanswerable、增量修改/删除、prompt-injection data-only、
  secret fail-before-embedding、bounded/truncated result packing、hard deadline cancel+join；
- dynamic bound/unbound inputSchema、typed `TOOL_INPUT_INVALID`、MCP-compatible complete envelope、
  stable evidence ID、真实 direct success，以及 final 前 exact snapshot reopen/hash/locator revalidation；
- Code/Cowork opt-in 走真实 AgentLoop 的 capability/permission/prepared/tool_result/settled 链，mailbox
  窄 capability 时工具完全缺席，close/shutdown 会 cancel/drain mount；snapshot-bound dynamic
  registration 必须保留 instance-owned local/remote intent，本地 `search_knowledge` 复用现有只读
  deterministic allow 且不产生 permission/reviewer lifecycle，network-backed instance 仍进入审查。
- canonical `embedding_model` / `reranker_model` decode 与 exact independent route；Knowledge-only provider
  可以没有普通 inference models。任一 role/dialect 不可用时，secret、network、store 与 bookmark
  副作用前 fail closed；credential 必须在真实 embedding/rerank dispatch 内才解析；official-shaped
  embedding/rerank fixtures 必须证明 endpoint、payload、result index/permutation 与 bounded candidates。
- path-aware `build_knowledge` / `search_knowledge` 的 closed input/output schema 与 host strict validation、
  provider strict 仅在所有 properties 都 required 时启用、existing-store 双 ID CAS、
  workspace/external authority 分流、read-only/broad/sensitive/root-swap/父目录替代/撤权，以及 raw bookmark
  与 safe projection 分离；bookmark sidecar lock 必须拒绝 symlink/hardlink 等 unsafe inode。至少一个
  真实 AgentLoop turn 应查询两个 exact store，并证明每个成功结果
  `rerank_applied=true`、current-turn citations 不串 snapshot、scope 在 grounding 后 drain。
- `.intatis-rag-store.json` / `.intatis-rag-snapshots` / `.intatis-rag-host` 必须由普通 file/patch/
  Git/process 与实际 managed-terminal anti-bypass 回归覆盖；legacy `snapshots/` 只能由 writer 原子迁移，
  read-only open 不得创建基础设施，dual layout 必须拒绝。pointer/layout rename 的 post-commit
  uncertainty 必须返回 non-retryable typed failure；checked augmentation close 必须证明 false drain 不会
  结算为成功且 repeated close 仍 single-flight。

质量测试必须冻结 corpus 与阈值，至少记录 Recall@5、MRR、nDCG@5、unanswerable、citation
coverage/precision、index bytes、memory proxy 和 deterministic latency proxy。Apple NaturalLanguage
不可用时只能 `XCTSkip`；开发机 arm64 结果不能外推 Intel 真机。x86_64 编译、Intel 上 exact
language/revision/dimension availability 和质量、真实 remote embedding/reranker credential/network smoke
必须分开记录，缺一项就标 `UNKNOWN`，不得静默换模型或宣称 universal runtime 已验证。

真实 Knowledge route 是显式付费 opt-in：

运行前先在 `INTATIS_CONFIG` 指向的 Intatis JSON/JSONC（或默认 Intatis-owned 配置）中确认顶层
`embedding_model`、`reranker_model` 均为完整 `<provider>/<model-id>`，且两个 provider 的
`options.baseURL`、`options.apiKey` 引用和 `npm` adapter 与实际服务一致。可复制的无 secret 配置 shape
见根目录 `README.md` 和
`codex-report/08_10_26-16_57-model-driven-knowledge-tools-design.md` §4.1。CLI 的 `/config` 必须显示
`knowledge ready`；该状态必须来自与真实 provider 构造共用 configuration builder 的同步预检。字段缺失、
endpoint 不存在、embedding 维度不明或 adapter 不受支持时应在解析/组装阶段失败，不得先解析 credential、
发网、取得 bookmark 或触碰 store。

```sh
INTATIS_REAL_KNOWLEDGE_SMOKE=1 swift test \
  --filter RealProviderSmokeTests.testRealKnowledgeEmbeddingAndRerankerWhenEnabled

INTATIS_REAL_KNOWLEDGE_QUALITY=1 swift test \
  --filter RealProviderSmokeTests.testRealKnowledgeRerankQualityWhenEnabled

INTATIS_REAL_KNOWLEDGE_AGENT_E2E=1 swift test \
  --filter RealProviderSmokeTests.testRealModelBuildsSearchesAndCitesExternalKnowledgeWhenEnabled

INTATIS_REAL_KNOWLEDGE_PDF_E2E=1 \
INTATIS_REAL_KNOWLEDGE_PDF_SOURCE=/absolute/path/to/pdf-directory \
swift test \
  --filter RealProviderSmokeTests.testRealModelBuildsSearchesAndCitesPDFKnowledgeWhenEnabled
```

第一条使用当前高级配置的 exact `embedding_model` / `reranker_model` 各发一个最小请求；第二条在冻结
的中英/代码 corpus 与 ground-truth queries 上分别报告 embedding-cosine baseline 和 configured semantic
reranker 的 MRR/nDCG@5/Recall@5；两个入口同时汇总 provider 实际返回的 token/billable units，未返回
时打印 `unreported`，不按可变价目表推算金额。第三条让当前配置的真实 Agent、embedding 与 reranker
执行“读取资料 → 整理 draft → 外部建库 → 检索 → 引用”；第四条先把指定目录中三个冻结 PDF 复制到
隔离临时 workspace，再要求 Agent 用 `read_pdf` 读取冻结页段、建立三主题库并回答。原始 PDF 不得修改。
后两条会产生多次可计费请求。执行任一入口前必须由用户提供或确认配置、credential、网络、费用与所需
资料外发授权；默认 `XCTSkip` 不能记为通过。这四条仍不能替代 macOS NSOpenPanel/bookmark 跨重启
restore 交互验收。

macOS external bookmark 手动验收必须使用 Developer ID/Debug `IntatisMac`（不使用 legacy App Store
target）：在 Code 中用自然语言给出一个 workspace 外的精确 `store_path`，批准 tool permission 后在
NSOpenPanel 只选择该目录；核对当前 session 的 `knowledge-access.plist` 是 binary、owner-only `0600`，
且只含 exact normalized path、opaque bookmark、revision 与 digest。随后退出 App、重新启动、恢复同一
Code session 并再次调用同一路径：不得再次出现授权面板。换 session、不同路径、root identity 漂移或
撤权后仍必须重新授权；测试时不得打印 raw bookmark bytes。

### 按格式拆分的文档链专项

修改文档合同、固定 backend、staging/commit、registry、permission 或 lease 时，至少运行：

```sh
swift build --target IntatisTools --disable-automatic-resolution
swift build --target IntatisToolsTests --disable-automatic-resolution
swift test --filter DocumentReadToolSplitTests
swift test --filter DocumentToolContractTests
swift test --filter DocumentInfrastructureTests
swift test --filter PDFNativeDocumentServiceTests
swift test --filter DocumentPythonWriteBackendTests
swift test --filter DocumentFixedBackendsTests
swift test --filter DocumentToolsIntegrationTests
swift test --filter CapabilityLeaseTests
swift test --filter ToolRegistryLeaseTests
swift test --filter AgentLoopPolicyTests
```

外层 managed sandbox 若阻止测试内的 Seatbelt/process spawn，可直接运行已构建的 XCTest bundle
做聚焦验证，并在真实 host 环境补跑完整 suite；必须记录采用的方式，不能把环境性失败冒充通过。
本机已安装 runtime 的 opt-in smoke 使用精确 test product，避免 `--skip-build` 误跑旧 bundle：

```sh
swift build --target IntatisToolsTests-product --disable-automatic-resolution
INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 xcrun xctest \
  -XCTest IntatisToolsTests.DocumentToolsIntegrationTests/testInstalledDocumentRuntimeEPUBWriteWhenEnabled \
  .build/out/Products/Debug/IntatisToolsTests.xctest
INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 xcrun xctest \
  -XCTest IntatisToolsTests.DocumentToolsIntegrationTests/testInstalledDocumentRuntimePDFCPUAndOCRWhenEnabled \
  .build/out/Products/Debug/IntatisToolsTests.xctest
INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 xcrun xctest \
  -XCTest IntatisToolsTests.DocumentToolsIntegrationTests/testInstalledDocumentRuntimeCoreToolChainWhenEnabled \
  .build/out/Products/Debug/IntatisToolsTests.xctest
```

普通 reader 还必须对用户提供的外部 corpus 做 opt-in 验证；测试只把候选文档复制到临时
workspace，不得修改源目录，也不得把个人绝对路径写进仓库：

```sh
INTATIS_REAL_DOCUMENT_CORPUS_ROOT=<external-corpus-root> \
  swift test --filter DocumentToolsIntegrationTests/testInstalledDocumentRuntimeReadsUserCorpusWhenConfigured
```

第三个 runtime smoke 包含 DOCX write/read、LibreOffice PDF preview/export、PDF read/render，PPTX
write/read/preview/export/PDF read，以及 XLSX write/Calc round-trip/formula-cache/preview/export；
任一中途失败都不得把前面的 Python write 或直接无沙箱 LibreOffice 基准记为整条文档链通过。
专项至少证明：

- production registry 暴露 `read_pdf`、`read_docx`、`read_pptx`、`read_xlsx`、`read_html`、
  `read_epub`、`document_ocr`、`document_render`、`document_export_pdf`、`document_write`；
  `document_read` 与旧自动读取/PDF mutation/reconstruct 工具不可见，standard/Cowork registry
  分别为 v3；
- 五个格式 reader 的 schema 只有 `path` 与可选 `maxCharacters`，格式由工具名固定；它们通过
  exact one-format Docling high-level converter 返回有界 Markdown，不接受 `format`、`options`、
  sheet/range/xpath/backend，不返回 raw Docling dict 或嵌入图片 data URI；
- image-only PDF 返回 typed `ocr_required`；PDF 页面 PNG 的尺寸、SHA-256、字节数和 manifest
  一致，真实渲染页经视觉检查；
- source/destination/辅助资产 CAS、默认 no-clobber、precommit cancellation、backend/validator failure
  均不改原目标；辅助资产 symlink/hardlink/授权后替换 fail closed，目标父目录身份在 terminal commit
  前后固定，目录 bundle 不暴露 partial pages 或 staging 文件；
- 缺失/版本不符 backend 明确返回 `backend_missing` / `backend_version_mismatch`，不触发 fallback；
- DOCX/PPTX/XLSX/HTML 每个公开 operation 都有真实 runtime corpus；write 后重新打开并按声明
  postcondition 验证。XLSX 的此项必须发生在 LibreOffice Calc round-trip/save 之后，并同时用
  formula 与 data-only 两种视图证明目标公式文本保留且存在可读非公式缓存；不能只断言转换成功；
- 生成 PDF 经 strict pdfcpu validation 和 PDFKit reopen/render smoke；validator 不能被描述为视觉保真、
  任意无损往返或 secure redaction 证明；
- EPUB write 的 Rust helper 必须通过 `cargo fmt -- --check`、`cargo check --locked`、
  `cargo test --locked` 与 `cargo clippy --locked --all-targets -- -D warnings`；普通 EPUB read 走与
  其他格式一致的 Docling reader，不再经过 rbook。生产 write 成功还要求正式 EPUBCheck artifact
  与 round-trip corpus。EPUB render/export 在 full-spine gate 前必须从 schema 删除；
- stdout/stderr 限制不得误作生成文件限制；单文件、聚合生成字节与 entry 数预算必须在进程运行期及
  退出后都生效，不能只在 backend 完成后检查 staging；
- read-only worker 只拿 `read_pdf`、五个 exact reader capability 与 `document_ocr`；五个普通 reader
  只能通过 exact `structured_read_only + safeToReplay` 权限形状执行，并由 deterministic gate 默认
  放行而不产生 permission request 或 reviewer dispatch。首个 reader 解析失败必须写
  failed/unknown settlement、允许同批后续 reader 继续并允许模型给出最终回答；其他 executor error
  同样必须把 failed/unknown observation 返回模型，不得升级成通用整轮终止。read-write
  worker/coordinator 才拿 render/export/write。
  iOS target 依赖图仍不含 Tools/Permission/AgentKernel/Cowork/文档 runtime。

2026-08-11 的本地回归中，外部 corpus opt-in 用例将 1 份稀疏 XLSX 与 3 份 PPTX 复制到临时
workspace 后全部读取成功；完整 `IntatisToolsTests` 为 223 tests、0 failures、19 skipped，真实 core
runtime 与 EPUB write/read smoke 各 1/1 通过。该结果证明当前开发机固定 runtime 上的读取链，不替代
发行 runtime closure 或未来新增格式/文件变体的 corpus。相关 `AgentLoopPolicyTests` 36/36、
capability/registry/mailbox 42/42、rbook fmt/check/test/clippy、SwiftPM build、macOS/iOS Debug unsigned
build 与版本一致性门均通过。一次整仓 `swift test --disable-automatic-resolution` 在既有 SharedUI
async waiter 中无进展并被人工中断为 130，因此不得把上述 focused 结果改写成当前整仓全绿。

真实 runtime 验证报告必须记录 executable/package/model 的 exact version、artifact hash（若可用）、
平台/架构与缺失项。开发机存在用户自建 runtime 只证明本机 smoke，不替代发行 closure、许可证/
NOTICE、Developer ID 签名、公证或双架构验证。

### Chat 自动命名专项

涉及 Chat 自动命名、session set-if-absent 或 ChatViewModel 自动标题接线时，至少运行：

```sh
swift test --filter ChatSessionAutoTitleTests
swift test --filter ChatAutoTitleViewModelTests
swift test
```

专项必须覆盖成功回合才触发、主回合失败/取消不触发、同一 exact provider/model 的隐藏两消息请求、
无 tools/web search/citation/附件、冻结 completed seq 前缀且旧 route 不读取后续轮次、最早三个可证明
completed segment、歧义 fail closed、user/assistant 正文字段合计 6,000 个 Swift
`Character` 上下文预算（JSON 编码开销不计入）、前三次 attempt/`NO_TITLE`、single-flight/pending/timeout、官方 provider 在首个
response byte 前至多一次 transport retry 且不额外消耗逻辑 attempt、收到 byte 后不 retry、严格
done/EOF（usage 可位于唯一 done 前或后；done 后正文/citation/重复 done 拒绝）与格式/敏感内容
validator、Chat-only EventLog set-if-absent、手工 Rename 竞争、跨 runtime
attempt ledger、pre-stream cancel 不计次、ineligible 后消费较新 pending、recent 排序不变、Chat
消息/error/busy 隔离、官方 provider request-owned stream termination，以及 shutdown cancel+await。

macOS/iOS host 另须确认 verified commit 发布时 EventLog 与读回 projection 已存在；重复/迟到
revision+seq 被丢弃；iOS 在 A→B 后收到 A commit 只更新 A row/header，不改变 B；目标依赖图仍是
7-product Chat 子集。真实 provider smoke 要另外记录 provider/model、是否首轮命名、15 秒可见性与
失败静默；单元测试和编译不能替代该联网产品验收。

2026-08-13 Chat/iOS 自动标题尾随 usage 修复与 Code/Cowork 首轮 prompt-only rename 的直接证据：

- `ChatSessionAutoTitleTests` 24/24、`ChatAutoTitleViewModelTests` 3/3、
  `ContextProjectionTests` 23/23，均为 0 failures；
- `swift build --disable-automatic-resolution`、`IntatisMac` macOS Debug unsigned build 与
  `IntatisiOS` generic Simulator Debug unsigned build 均退出 0；iOS 增量复核明确输出
  `BUILD SUCCEEDED`，首次构建仅出现仓库既有 warning 与一条 exit-code-0 Swift driver 噪声诊断；
- 一次完整 `swift test --disable-automatic-resolution` 已完成 `IntatisToolsTests` 227/227
  （19 个显式 opt-in smoke skipped）、`IntatisSkillsTests` 29/29，并在 SharedUI 中再次完成本次
  `ChatAutoTitleViewModelTests` 3/3；随后 SharedUI 后续用例连续约 90 秒无输出，人工中止为 130，
  因此不得记为整仓全绿；
- 未运行真实 provider、credential/network 或 GUI/iOS 手动 smoke；prompt-only rename 的线上模型
  遵循度仍须用真实 Code/Cowork 首轮分别验收，且本次没有增加 host 自动触发器。

2026-08-13 Code/Cowork 会话错误统一右置的直接证据：`ThreadLayoutTests` 21/21、0 failures。
测试复现失败 submission 与 `.error` 同时携带 `Task timed out after 600 seconds.` 的截图场景，
确认只生成一项右栏错误、runtime title 优先且 exact Retry ID 保留；另覆盖失败 execution row、
partial reply recovery、全部 host error strings、空来源不生成卡片、中央 transcript 仍保留用户原文与
partial agent 正文。`swift build --disable-automatic-resolution`、`IntatisMac` macOS Debug unsigned
build 与 `IntatisiOS` generic Simulator Debug unsigned build 均退出 0。未启动 App 或 fixture，卡片
实际字高、长错误滚动、窄宽与 Light/Dark 像素仍需手动观察。

2026-08-13 用户消息原生 Liquid Glass 气泡的直接证据：`ThreadLayoutTests` 18/18、0 failures；
新增 source-shape 回归覆盖 macOS Chat、共享 iOS Chat 与 Code/Cowork，确认仅 user branch 使用
`intatisLiquidGlass`，旧 `userSelectionStroke` / `bubbleStroke` / accent 蓝色 stroke 不再存在，
failure 不参与气泡 admission。`swift build --disable-automatic-resolution`、`IntatisMac` macOS
Debug unsigned build 与 `IntatisiOS` generic Simulator Debug unsigned build 均退出 0；构建只报告
既有 `onChange(of:perform:)` deprecated warning。未启动 App 或 fixture，实际折射强度、长用户消息、
Light/Dark、Reduce Transparency 与 Increase Contrast 仍需手动观察。

## Apple App 构建

```sh
xcodegen generate

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Release -destination 'platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
```

构建后读取最终 bundle，而不是静态源码 plist：

```sh
plutil -extract CFBundleShortVersionString raw -o - <App>/Contents/Info.plist
plutil -extract CFBundleVersion raw -o - <App>/Contents/Info.plist
lipo -archs <App>/Contents/MacOS/IntatisMac
```

macOS Release 必须同时包含 `arm64` 和 `x86_64`；iOS 仍须通过 target dependency/link
inventory 证明没有本地 workspace stack。

## Developer ID 直接分发

预检：

```sh
zsh -n scripts/package-macos-release.sh
security find-identity -v -p codesigning
xcrun notarytool --version
```

正式执行：

```sh
INTATIS_NOTARY_PROFILE=<profile> scripts/package-macos-release.sh
```

如果访问 GitHub 必须开启代理/VPN，而 Apple notarization 必须关闭它，则运行：

```sh
INTATIS_PAUSE_BEFORE_NOTARIZATION=1 \
INTATIS_NOTARY_PROFILE=<profile> \
  scripts/package-macos-release.sh
```

保持代理/VPN 开启直到脚本完成依赖解析、构建和 App 签名并显示切换网络提示；随后保持
终端和脚本运行，关闭代理/VPN，再按 Return。脚本在原地循环验证 `notarytool history`，
成功后才提交 App；失败不会丢弃已签名的 staged App，也不要求重新下载依赖。该模式要求
交互式终端，非交互 release job 不得设置 `INTATIS_PAUSE_BEFORE_NOTARIZATION=1`。

上传后终端必须显示 Apple submission ID 和实时状态。默认 wait deadline 是 30 分钟；仍为
`In Progress` 时脚本必须保留 owner-only recovery 目录并打印 exact resume 命令，不能再次
提交同一 App。可用 `INTATIS_NOTARY_TIMEOUT=<正整数>[s|m|h]` 修改单次等待时长。恢复命令为：

```sh
INTATIS_NOTARY_PROFILE=<profile> \
INTATIS_RESUME_RELEASE_DIR=<脚本打印的绝对路径> \
  scripts/package-macos-release.sh
```

恢复测试必须确认：App/DMG submission ID 复用、无第二次 `submit`；repository version 和
recovery App metadata/architecture/signature/entitlements 重新验证；超时、Control-C、TERM、
网络失败和 Invalid 保留 recovery；最终 ZIP/DMG/manifest 全部落盘后才清理 recovery。当前
真实旧运行发生在这套持久恢复机制加入前，不能用它冒充已完成 recovery E2E。

发行脚本必须在输出 `dist/` 前完成：

1. v0.55/build 55 一致性检查；
2. `IntatisMac` universal Release；
3. Developer ID Application + secure timestamp + Hardened Runtime；
4. signed entitlements 不含 App Sandbox；
5. App notarization Accepted、staple/validate、strict codesign、Gatekeeper assessment；
6. 带 `/Applications` 拖放入口的 Developer ID signed DMG；
7. DMG notarization、staple/validate、codesign、Gatekeeper assessment；
8. ZIP/DMG SHA-256 清单。

任一门槛失败都不得发布 ad-hoc、unsigned、未公证或未通过 Gatekeeper 的包。

## 数据、权限与恢复回归

涉及 EventLog、session projection、权限、Cowork、terminal 或生命周期时，必须覆盖：

- 旧 JSONL 仍可解码，`seq` 单调，append/batch first-write/first-terminal 语义不变；
- permission RequestID/FIFO/correlation、manual decline 与 cancel-turn 语义不混淆；
- tool authorization、durable ticket、executor result 和 turn outcome 关联完整；
- current-run close 只向 exact `@main` root 暴露，模型不得提供 identity；in-flight tombstone 必须先挡住
  重入 admission/authorization，RunID first-write claim 必须早于旧 admission wait 与 cleanup/drain 落盘，
  只 drain 同 run、保留 typed source，恢复不得复活 closed run，普通 final 不伪造 claim；
- mailbox ordinary message 不 ACK；information request 只接受一个 exact `inReplyTo` terminal reply；
  information reply receipt 只能用 fresh RequestID + `based_on` 延续同 conversation，不能形成 ACK 环；
- path escape、symlink/hardlink、secret、credential path、workspace lease fail closed；
- 只有持有 coordinator lease 的 Cowork prompt 才主动建立 execution objective、检查并激活明确相关的
  exact Skills、为非简单工作维护最小 WorkTask DAG、在收益成立时尽早委派并继续自己的关键路径，
  最终验证 child report 与结果；普通请求不自动创建 durable Goal，一步两步工作不仪式化 spawn，
  worker、authoritative tool list、lease 与 PermissionEngine 边界不变；
- Cowork coordinator prompt 在 `spawn_agent` 可用时把预知的根外目录或 out-of-workspace denial
  路由为 exact-directory child + `delegate_task`，默认只读、写入显式；Code/worker prompt 不宣称
  coordinator 能力，工具缺失/扩展拒绝只报告 blocker，直接越界仍 fail closed；
- Code system prompt 与 Cowork coordinator/exact `@main` prompt 只在 session 第一轮用户任务完成验证或
  确认真实 blocker 后、且 authoritative list 含 `rename_session` 时要求调用一次具体标题；不得新增宿主
  自动 trigger。worker 与共享 Cowork runtime prompt 不得出现该要求，后续轮次只响应用户明确改名。
  Cowork 提示必须保持 `rename_session` 最后一个非 run-control call，再进入既有 `finish_run` / `stop_run`；
- runtime stop 先 drain provider/tool/process，再释放 waiter/subscription/scope；
- Cowork worker 默认无 coordinator tools，reviewer/verifier 不进入普通 scheduler；
- ordinary worker 的 `task_update` closed business schema 只含当前任务的 ID/revision、进度、允许状态、
  结果与证据，manager 的完整 schema 不受影响；两者仍保留同一稳定工具名，worker 管理字段在权限/执行前
  拒绝，automatic request-owned authorization sidecar 装饰仍独立保留；
- iOS target closure 不出现 Tools/Permission/AgentKernel/Cowork/MCP。

精确不变量见 `docs/DO_NOT_BREAK.md`。

## UI 与可访问性回归

当前至少检查：

- macOS/iOS Light 与 Dark；
- Chat/Code/Cowork session 切换、16-row paging、Earlier/Newer/Latest；
- macOS/iOS 新建未命名 Chat：首个有主题成功回合后标题在 15 秒内出现；简单问候可先保留默认名，
  后续有主题回合再命名；标题生成期间可立即继续 Send，Stop 只控制当前主回合；手工 Rename 在生成
  前/中/后均不得被自动标题覆盖；iOS 快速 A→B 时 A 的迟到标题只更新 A；
- Cowork 默认查看 `@main`；右侧 ordinary agent 点击后只出现该 agent 内容；
  detach 当前 agent 后它仍留在同一列表、状态图标变为 detached、选择和历史页不跳回 main，
  且所有运行时操作禁用；`@permission-reviewer` 为 status-only；两个窗口选择互不覆盖；切走再
  返回仍恢复各 agent 自己的 Earlier/Newer/Latest boundary；查看 worker 时 composer 仍路由 `@main`；
- long rich response、Markdown/table/code/math 和 plain-safe fallback；
- macOS rich assistant/agent message 直接左键拖拽可在同一 rendered document 内正向/反向跨 heading、
  paragraph、list item、block quote、table cell 与 code body；拖动期间 ranges 连续，mouse-up 后所有
  leaf 使用同一系统 `selectedTextAttributes` 强调。首个 leaf 只能保留不重复绘制的 native selected range
  维护 responder/Copy；active/inactive window 均不得出现首段浅蓝、后续深蓝的双重样式。普通 click、
  stream replacement、mode/session/page change 与 dismantle
  必须恢复 exact attributed projection；Intatis 不显示 `Select more text` menu/sheet，也不构造第二
  SelectionOverlay/plain renderer。Command-C 按 document order 复制 displayed plain text，block 间换行、
  同 table row 用 tab、inline math 恢复 literal；message footer whole-copy 仍复制 canonical raw text。
  code 必须保持 horizontal unwrapped，table 不等高 cell 仍 row-major/非零布局；iOS/plain-safe 行为不变；
- macOS 每条已完成 assistant/agent 回复在正文下方只有一个最左 icon-only copy action，右侧按
  Input/Cached/Output/Time 顺序显示该 exact `responseMessageID` 的可证明字段；没有文字版 Copy、
  点赞/点踩、card/glass 或旧 global latest usage。复制结果必须逐字等于 raw message text；旧 unbound
  `turn_stats` 不得贴到相邻消息。Chat message-first 与 Agent stats-first 两种事件顺序都必须覆盖；
- macOS Chat、iOS Chat、Code、Cowork 仅用户消息显示 trailing 原生 regular Liquid Glass 气泡，
  不出现旧 accent 蓝色描边；assistant/agent/system（包括失败/中断回复）直接位于 canvas，
  正常 tool/permission/task 等专用结构化卡片仍保留各自容器；
- composer 单行/多行、model menu、usage、Send/Stop；macOS 第一排只保留 Context，iOS Chat 继续完整
  latest-turn usage；
- iOS composer 获得焦点后，Send 按钮与键盘提交都应立即收起键盘；重新聚焦后在消息区上下拖动应
  交互式收起键盘，stream completion、输入框重新启用和自动滚动不得再次弹出；macOS focus 不变；
- Cowork wide rail、narrow permission fallback、Goal/Tasks/Agents；
- Code/Cowork 当前 page 的 `.error`、失败 execution row、recovery advice、失败 submission 与全部
  host 页面级错误只在右栏最底部同一张“错误信息”圆角卡片内显示；相同文案去重，Cowork Retry
  仍可用。无错误时无卡片、无占位；主 thread/composer 不得再显示 `Needs attention`、timeout、
  recovery advice、中央红框或另一张 `Recent Failures`；用户消息和 partial agent 正文必须保留；
- wide rail 连续切换 agent、应用失焦/回焦、窗口移动与进入/退出全屏；系统日志中不得出现
  `IntatisThreadViewportFramesPreferenceKey tried to update multiple times per frame`，源码不得恢复
  viewport GeometryReader/PreferenceKey 坐标回写；
- Settings disclosure、provider test、本地诊断 ZIP；
- Dynamic Type、Reduce Transparency、Increase Contrast、VoiceOver 和 clipboard/selection。

截图或 Computer Use 只能证明对应 viewport/appearance 的视觉行为，不能替代 EventLog、
权限、bundle、签名或长时性能验证。

### Cowork agent-thread 性能门禁

Debug-only `CoworkAgentConversationFixtureView` 通过启动参数
`-IntatisCoworkAgentConversationFixture` 使用真实 `CoworkShell`，但不打开 EventLog、provider、
workspace、permission runtime 或 credential。Computer Use 无法传入启动参数时，DEBUG 构建也可用
以 `.CoworkAgentConversationFixture` 结尾的独立 bundle identifier 启动同一 fixture；该入口不进入
Release。固定负载为 8 个 selectable agent × 每个 1,000 rows、4-agent 合计 500 canonical
delta/s（50 ms projection coalescing）、最多 16 visible rows。

专项验收至少执行：

1. `Run 1,000 switches`，确认最终 selection/内容一致且 warning/incident 均为 0；
2. `Run 180s soak`，nominal 10 selected-agent changes/s；记录实际 timed switches；
3. 结束后保持窗口打开并静置到 rich document 恢复，再记录 RSS、`vmmap -summary` 与
   `heap` 中 `NSTextViewSharedData` / `Gestures.GestureNode<()>` 数量；
4. 再手动验证一个 streaming agent、一个静态 agent、Earlier 页，以及切走再返回的 per-agent
   boundary；确认 reviewer 没有 conversation button。

通过条件：全过程 UI 可访问，main-thread warning/incident 为 0；可见 page 始终 ≤16；RSS/physical
footprint 和 native text/gesture objects 不随切换次数线性增长；停止后 rich view 数量回到一个
bounded visible page 的量级。`heap`/`vmmap` 会短暂停顿目标进程，只在自动 soak 完成后采样，
避免把外部采样暂停误计为产品 heartbeat incident。该 offline fixture 只证明 presentation
pipeline，不替代真实 EventLog I/O、provider、VoiceOver、最低支持设备或多小时运行。

## Chat 与 Agent 托管搜索验收矩阵

`docs/CHAT_HOSTED_SEARCH.md` 是当前产品合同。相关业务源码修改至少必须用离线 request fixture
和 Chat integration tests 证明：

- OpenAI Responses request fixture 只生成该 dialect 的 `web_search` + `tool_choice: auto`；
  OpenRouter exact route 明确声明 `hosted_web_search` 时只生成
  `openrouter:web_search` + `tool_choice: auto`，两者不得共用硬编码 tool type。
- `@ai-sdk/openai` 普通 Chat adapter 尚未实现期间，registry 必须在网络前维持既有 config error，
  不能仅凭已有 OpenAI search encoder 跳过普通 adapter gate。
- 当前 Chat route 不支持、未知、adapter 尚未实现，或只有 `responsesEndpoint`/URL/名称 heuristic
  时，发送同一 Chat route 的普通 request，body 不含 hosted-search 字段，且不会先发送失败请求。
- 配置包含任意有效、无效或未知 `web_search_model` / `webSearchModel` 时，runtime 都不得解析或
  调用该 route，不得覆盖当前模型，也不得新增 UI 警告；新生成配置 fixture 不再写入该字段。
- 用户切换 provider/model/variant 后，下一次 Send 只按新的 exact selection 重新规划；不得沿用
  上一 route 的 capability，也不得产生不同 provider/model 的请求。
- 普通与搜索分支都保留 exact model/variant options；`provider.only`、`allow_fallbacks`、
  `require_parameters` 不得被删除或放宽。搜索不支持时只移除搜索字段。
- 模型拥有搜索能力但未调用时正常完成且 citations 为空；实际返回结构化 annotation 时才写
  additive citations，非法 URL、正文猜测来源和空 Sources UI 继续被拒绝。
- typed provider-specific “hosted search unsupported” 在任何有效 payload 前只允许在同一
  provider/model/variant 上一次普通 Chat 重发。任意 404、自由文本匹配、不同 provider/model
  fallback、partial payload 后重放必须被测试拒绝。
- Chat unsupported/unknown 分支不产生 toast、banner、错误卡、状态、提示词或 Settings 项，也不
  注册/调用 Agent `hosted_web_search`、`web_fetch`、`browser_search`、MCP、shell 或本地浏览器。
- macOS/iOS 共用相同 planner 语义；iOS target closure 仍没有 Tools、Permission、AgentKernel、
  Cowork 或 MCP。Chat cancellation、TurnID、EventLog 与旧 citation decode 不因分支改变。

真实 provider smoke 只能作为 adapter fixture 之外的补充，不能用单一厂商成功替代上述 exact
adapter/capability 矩阵。2026-08-05 已新增并通过 provider focused tests，覆盖独立 capability、
当前 route/legacy route ignore、compatible 静默普通 Chat、OpenAI/OpenRouter tool shape、strict
routing options、结构化 unsupported 同路由一次降级、裸 404 拒绝降级、partial payload 后禁止重放
及 citation 安全解析。macOS/iOS app build 与完整回归结果以本文件“最近一次真实结果”为准。

Code/Cowork/CLI 的显式 `hosted_web_search` 包装至少追加验证：

- `HostedWebSearchToolTests`：descriptor 只有 required `query`，`strict:true`、
  `additionalProperties:false`、network/model-cost intent、`doNotReplay`；空白/超长输入在
  provider 前失败，service 收到 trim 后 query，standard registry 无 service 时不广告工具。
- `ProviderHostedWebSearchToolServiceTests`：专用请求使用 route 中 exact model/provider/options、
  `tool_choice:required` 与 unsupported fail-closed；文本/citation 去重与 output bound 正确，缺 completion
  marker 或 cancellation 不返回成功 ToolObservation。
- Provider route/request fixtures：OpenAI `web_search` 与 OpenRouter `openrouter:web_search` 仍分 dialect；
  exact agent metadata 缺 capability、compatible/legacy/unknown adapter 时 route 不携带 search service；
  exact profile revision 能原子携带同 provider/model 的 optional search route。工具模式明确拒绝
  ordinary-model fallback，而 Chat 模式继续保持受限的一次 fallback。
- `CapabilityLeaseTests` / `ToolRegistryLeaseTests`：fresh read-write lease 有独立
  `ToolCapability.hostedWebSearch`，read-only/reviewer/旧 lease 无；concrete tool 必须同时有 lease 与
  bound service，且不得因此出现 `browser_search` / `web_fetch`。registry identity 固定为
  `intatis.standard.v4` / `intatis.cowork.v4`。
- 至少构建 SwiftPM 全图，并编译 macOS Code/Cowork 与 CLI composition root；iOS 继续不链接
  Tools/Permission/AgentKernel/Cowork。真实 provider smoke 必须显式 opt in 并记录 exact
  provider/model/dialect、tool choice、是否返回 citation、usage/cost 与失败形状，不得隐式读取凭据或
  消费额度。

2026-08-13 本地已通过 `swift build`、`swift test --filter HostedWebSearch`、
`swift test --filter HostedSearch`、`swift test --filter CapabilityLeaseTests` 与
`swift test --filter ToolRegistryLeaseTests`，以及 `IntatisMac` macOS Debug unsigned build 与
`IntatisiOS` generic Simulator Debug unsigned build。另尝试完整 `swift test`：
`IntatisToolsTests` 227/227（19 个显式 opt-in smoke skipped）与 `IntatisSkillsTests` 29/29 通过，随后
在 SharedUI `testSelectedAgentUpdateRestartsRichRenderingDwell` 连续约两分钟无输出并以 130 中止；同一
exact test 单独重跑 1/1 通过。不得把该运行记为完整 suite 通过。未运行真实 provider/key smoke。

## macOS Chat/Cowork composer 图片附件验收矩阵

涉及 macOS Chat 或 Cowork composer 附件时，至少验证：

- 两者实际组合同一个 paperclip accessory 与 file-import/drop modifier；按钮、导入进度、附件数量
  菜单、逐项移除和 accessibility 文案只允许产品面名称不同，不复制两套交互实现；macOS Chat 不再
  出现独立的提示词生图 action；
- 系统文件选择和 URL drop 支持多选；security-scoped access 成对开启/关闭，文件先保存到当前
  session ArtifactStore，再按 ID、MIME、字节读回一致后才进入 draft；导入失败不污染已有草稿；
- Send 在按钮边界冻结文本和附件 ID；纯附件消息可发送。导入/读回或 durable admission 前失败必须
  保留草稿；对应 user intent 已 durable accepted 后才清除同一份冻结草稿，随后 AgentLoop 的
  resolver/capability typed failure 保留 accepted intent，不把它恢复成未发送草稿；
- `UserMessagePayload.attachments` 只保存 ArtifactID；EventLog、projection、错误和 UI 不得保存或
  显示 base64、bookmark、文件路径。当前轮与后续历史轮都从同一 session ArtifactStore 解析图片，
  不能只在第一次 provider request 传图；
- provider 输入只接受 `image/*`。缺失、不可读或不支持的 artifact 必须在网络前产生 typed、可行动且
  不泄密的错误；若 user intent 已 durable accepted，错误不得回滚或复制该 intent。非图片文件仍可
  durable 保存和移除，但不能被静默当作图片发送；
- Chat 投影和 macOS/shared user bubble 至少显示附件数量；旧 artifact event、旧缺少 `attachments`
  字段的 JSONL 和纯文本消息继续解码/回放；
- Code 的新增 durable attachment accessory 必须继续复用共享导入/ArtifactStore 边界；Agent
  `generate_image` / `edit_image` 权限链不得被改写，iOS 不得因共享 VM 或 ArtifactStore 注入而出现
  本地文件/照片附件入口；
- 至少运行共享附件 store/resolver tests、ChatLoop 当前轮+历史轮 rehydration test、完整 SwiftPM
  tests、`IntatisMac` macOS Debug 与 `IntatisiOS` generic Simulator Debug unsigned build。文件选择、
  拖放和真实视觉命中仍需 macOS 手动 smoke 单独记录，不能从单元测试或编译外推。

## Agent durable 图片上下文专项

涉及 Code/Cowork 用户图片、structured-result 图片、model history、provider FCO 或 compaction 时，
至少运行：

```sh
swift test --filter ArtifactImageResolverTests
swift test --filter IntatisProvidersToolCallingTests
swift test --filter ModelHistory
swift test --filter DurableMultimodalAgentLoopTests
swift test --filter CLIAttachmentTests
swift build --target IntatisCLI
```

具备用户明确授权的真实OpenAI凭据、网络和额度时，再显式运行一次同时携带user image与原call
function-output image的付费smoke：

```sh
INTATIS_REAL_MULTIMODAL_SMOKE=1 swift test \
  --filter RealProviderSmokeTests.testRealOpenAIMultimodalUserAndFunctionOutputWhenEnabled
```

该测试只发一个provider请求；不开启环境变量时必须skip，不得隐式消费凭据或额度。

专项必须证明：

- 用户图先进入 exact-session ArtifactStore；`AgentLoop.send`拒绝调用方直接传provider-ready
  `images`/data URL，task-scoped current、stable current/next/restart与legacy ID路径都使用同一bounded
  resolver；
- PNG/JPEG MIME/magic、完整解码、byte/aggregate/count/dimension/pixel、SHA-256 与 no-follow/owner-only
  失败矩阵均 fail closed；缺少可信 decoder 的平台不列入正向图片矩阵；
- MCP structured image以原call ID进入Responses function output，text/JSON只canonicalize一次，live与
  replay使用同一append-return binding；含图completion batch必须绑定同turn/call的唯一`tool_result`与
  同`{callID, agent, taskID, attempt}`的唯一settlement；不支持FCO图片的route在网络前typed失败但不
  改写工具settlement；
- 图片正向route必须是effective `.openAI` request adapter与exact model `.visionInput`的合取；user/FCO
  capability分别验证，compatible/legacy/OpenRouter/unknown adapter保持false，图片Responses transport
  不得误触发tool-search capability错误；
- projector image sidecar与messages严格等长，v2 direct/checkpoint不能降级为v1；compaction
  summarizer看见完整active window，成功checkpoint不保留任何旧图片ref，resume不偷回checkpoint前图片；
- automatic Cowork 不得因 acting request 含 user 或 FCO 图片而 blanket deny；端到端回归必须分别覆盖
  当前 user image 与历史 FCO image，证明 same-call sidecar 可摘要媒体证据、reviewer 仍只接收文本摘要而
  不重发完整像素/PDF，并且 valid allow 后只执行 exact reviewed business call；
- Cowork Retry planner矩阵必须证明outbox canonicalization保持attempt 1、restored queued exact resume
  不递增、restored running durable requeue只对齐下一exact attempt；无Run的failed/cancelled task仍在原
  submission/task上有界递增，而terminal Run上的failed root必须创建fresh可见continuation
  submission/root/Run、复用原冻结main binding且不复制one-shot external context，并证明旧Run/旧失败
  事实不变、旧按钮在新submitted intent出现后消失；
- macOS Code/Cowork GUI与CLI产品接线编译；iOS仍不链接AgentKernel/Tools/Cowork。fake provider只能证明
  request shape与事件顺序，真实OpenAI Responses user/FCO image smoke必须另列且需要凭据/网络。

## 图片工具与 `image_model` 配置验收矩阵

涉及 macOS/modern CLI 图片路由时，至少验证：

- 顶层 canonical `image_model` 的 `<provider>/<model-id>` 精确解析到
  `ResolvedModels.imageGen`，不改变当前 Chat/Code/Cowork inference selection；
- 专用图片 provider 可使用空 `models`，连接仍保留，但不生成 inference profile 或进入模型菜单；
- 图片 model ID 不需要作为推理 model 重复登记；model-facing `generate_image` 与
  `edit_image` schema 都不包含 provider/model 字段；
- 缺少 `image_model` 时 `models.imageGen == nil`，两个工具执行都明确报未配置，不能出现
  `dall-e-3` 或其他 hidden fallback；
- provider wire 继续只接受合法 HTTP(S) Base URL；生成调用 OpenAI-compatible
  `/images/generations`，编辑调用 multipart `/images/edits`，两者都验证
  `data[].b64_json`；
- `edit_image` 必须在任何网络请求前验证输入/输出均位于 workspace、输入是受支持且魔数匹配的
  PNG/JPEG/WebP 普通文件、输入不超过 50 MiB、输入输出不相同且输出扩展名是 `.png`；
- 两个工具的文件写入都经过 permission、workspace lease 与 `PathConfinement`；Cowork
  read-only worker 与 reviewer 不得看到 `edit_image`。当前首版只支持单张输入图，不支持 mask、
  多参考图或原地覆盖。

## 输入栏语音与 `transcription_model` 配置验收矩阵

涉及 macOS Chat/Code/Cowork 或 iOS Chat 语音输入时，至少验证：

- 顶层 canonical `transcription_model` 的 `<provider>/<model-id>` 精确解析到
  `ResolvedModels.transcription`，不改变 Chat/Code/Cowork inference selection；缺字段时为 `nil`，
  不得使用当前 Chat model、`whisper-1` 或其他 hidden fallback；
- 显式 transcription-only provider 可使用空 `models`，连接和 credential reference 仍保留，但不
  进入模型菜单；macOS 高级 JSON/JSONC 和 iOS Files import 均保留同一个 exact route，不新增设置页；
- Chat/Code/Cowork/iOS Chat 的 mic 位于唯一 Send/Stop 左侧：第一次点击开始录音，第二次点击停止
  并转写；其 compact control 必须以显式 40pt 外层 frame + 圆形 `contentShape` 命中屏幕上完整
  圆形按钮，不能退化成只有内部字形可点；结果追加而不是覆盖完成时的当前草稿，空结果不改变
  草稿且永不自动 Send；
- 录音开始前验证 recorded-file runtime 并冻结 registry/route，credential 只在转写边界懒加载；
  compatible/legacy/OpenAI adapter 使用 disk-backed multipart `/audio/transcriptions`，exact OpenRouter
  adapter 使用 JSON-base64 `input_audio` 同 endpoint；不得按 provider 名称或 URL 猜测方言；
- 默认录音必须是 WAV/16 kHz/mono；WAV 为 16-bit little-endian PCM，M4A 兼容设置也不得包含
  `AVEncoderBitRateKey`。临时音频与 upload body 均为 owner-only 随机文件，最多录制 120 秒，读取/
  上传前限制为 25 MiB；空文件、symlink、非普通文件、非法扩展与超限内容在请求前拒绝；
- 成功、失败、取消、VM/runtime shutdown 后均停止 recorder、释放 process-wide microphone lease 并
  删除音频/body；取消或迟到的 TCC callback 不得复活旧 generation；
- 用户 Send 前不得产生 EventLog、ArtifactStore 或 projection 写入；macOS/iOS bundle 均包含
  `NSMicrophoneUsageDescription`，English/简体中文说明可用；
- 不迁入多模型对比、第二设置页、全局快捷键、review/clipboard 或输入法 target；至少运行 draft
  merge、recorder settings、multipart/OpenRouter JSON/config route focused tests、完整 SwiftPM tests、
  `IntatisMac` macOS Debug 与 `IntatisiOS` generic Simulator Debug unsigned build。真实麦克风权限与
  线上 provider smoke 必须单独记录，不能从离线测试或编译外推。

## 最近一次真实结果

### 2026-08-21 固定只读工具默认放行

- 生产行为只在 `DeterministicPolicyGate` 的两个既有分支中从 `pass` 改为 `allow`：
  `structured_read_only` 固定 reader/OCR 与 local-only `search_knowledge`。没有修改协议、sidecar、
  EventLog、PermissionResponder、reviewer/control plane、工具 descriptor、CapabilityLease 或
  WorkspaceLease；network-backed Knowledge 和其他网络/写入/通用 exec/destructive 工具仍按原路径审查。
- 聚焦 suites 共 169 tests、0 failures：`IntatisPermissionTests.xctest` 56、
  `SearchKnowledgeToolTests` 4、`ToolRegistryLeaseTests` 27、`AgentLoopPolicyTests` 37、
  `DocumentReadToolSplitTests` 4、`AutomaticPermissionReviewTests` 39、
  `ModelDrivenKnowledgeAgentLoopTests` 2。它们覆盖 direct gate、六个固定结构化只读工具的 existing intent、
  local Knowledge 无 `permission_request`、authorization/capability/durable ticket 仍存在、automatic
  reviewer 其他路径不回归，以及 model-driven network/build 路径仍受原权限边界。
- 首次在受管沙箱中运行时，SwiftPM manifest 在源码编译前因
  `sandbox-exec: sandbox_apply: Operation not permitted` 失败；同一聚焦命令在允许 SwiftPM 自身
  sandbox 的宿主环境退出 0。未运行完整 `swift test`、macOS/iOS App build、真实文档 runtime、
  credential/network 或真实 reviewer provider smoke。

### 2026-08-21 `IntatisMacAppStore` target 删除

- `project.yml` 不再声明 `IntatisMacAppStore` target 或 scheme，唯一专属文件
  `Apps/IntatisMac/IntatisMac.AppStore.entitlements` 已删除；所有 Mac App 源码中的
  `INTATIS_MAC_APP_STORE` 条件编译分支已删除并保留唯一 `.macDeveloperID`/workspace+global/
  Knowledge/managed-stdio 路径。`.macAppStore` 共享 profile 只保留协议解码与隔离测试兼容。
- `xcodegen generate` 退出 0。随后 `xcodebuild -project Intatis.xcodeproj -list` 的 App targets 精确为
  `IntatisMac`、`IntatisiOS`；`Intatis.xcodeproj/xcshareddata/xcschemes` 精确含
  `IntatisMac.xcscheme` 与 `IntatisiOS.xcscheme`，生成工程、Mac sources 和 entitlements 目录均不含
  `IntatisMacAppStore`、`INTATIS_MAC_APP_STORE` 或 `IntatisMac.AppStore.entitlements`。
- `SDKClientOnlySurfaceTests` 3/3、0 failures；新断言验证单一 Mac App、Developer ID target 继续链接
  `IntatisMCP` + `IntatisMCPStdio`、iOS 两者都不链接，并验证 target/macro/entitlements 文件不存在。
  保留的 `.macAppStore` 协议/remote-only 兼容由 `IntatisCoreTests.testProfilePresets` 1/1 与
  `MCPPreparedConfigurationTests` 5/5 覆盖，合计 6/6、0 failures。
  `scripts/check-version-consistency.sh` 输出 `Intatis version is consistent: 0.55 (build 55)`。
- `IntatisMac` macOS Debug unsigned build（`-disableAutomaticPackageResolution`、
  `ENABLE_DEBUG_DYLIB=NO`）退出 0；`IntatisiOS` generic Simulator Debug unsigned build也退出 0。
  输出只有仓库既有 unused-result/`onChange` deprecation，以及旧临时 build output 引发的 stale-file
  warnings；没有 target/link/source 编译失败。本轮未运行整仓 `swift test`、universal Release、Developer
  ID 签名、公证、staple、Gatekeeper 或重新安装 `/Applications/Intatis.app`。

### 2026-08-21 macOS 跨 block 选区单一外观 corrective

- 用户提供的真实 Chat 截图暴露旧 mouse-up 路径仍有两套绘制：首个 leaf 保留 `NSTextView` native
  selection，后续 leaf 把 `controlAccentColor` / alternate selected foreground 写入 disposable
  `textStorage`；窗口或截图工具改变 focus 后，native selection 自动变浅而 projection 保持深蓝。
- 当前 `ParagraphNSView` 让 native selection 与 distributed projection 共用一份系统
  `selectedTextAttributes`。coordinator 在 mouse-up 后让所有 leaf 只显示这一个 projection；首个 leaf
  仍保留真实 selected range 以维持 AppKit responder、Edit → Copy 与 Command-C，但临时把 native
  selection attributes 置空，清除 selection 时恢复。没有新 overlay、renderer、依赖或 canonical 文本写入。
- `MarkdownDocumentSelectionCoordinatorTests` 14/14，新增断言逐 leaf background/foreground 与系统
  selection attributes 完全一致、只有 primary 保留真实 range、清除后 native attributes 与原 attributed
  projection 均恢复。完整 vendor 为 79 XCTest + 25 Swift Testing、0 failures；SharedUI
  `MessageRenderingTests` 42/42、`ThreadLayoutTests` 25/25，合计 67/67、0 failures。初次 strict Release
  test 暴露 test-only coordinator observation 被错误包在 `#if DEBUG`；改为 module-internal read-only 后，
  `-strict-concurrency=complete -warn-concurrency -warnings-as-errors` 的完整 Release suite 也以相同
  79 XCTest + 25 Swift Testing、0 failures 通过。
- normal `IntatisMac` Debug（`ENABLE_DEBUG_DYLIB=NO`）和 unique-bundle code-selection fixture 均构建并以
  ad-hoc Hardened Runtime 签名通过。Computer Use 在 fixture 中真实拖拽正文→代码，并在 active/切换应用
  focus 后都看到一套浅蓝选区；Command-C 后以宿主 `pbpaste` 读回正文与 code prefix，换行、空行和缩进
  完整。随后在更新后的 `/Applications/Intatis.app` 中直接复现用户截图的“经常遇到这几个词”→
  Stride/Padding/Channel 场景，首段和三项列表已显示同一种选区颜色；验证后已清除临时选区。
- 最终安装仍为 `0.55 (55)` arm64 Debug、ad-hoc Hardened Runtime，main executable SHA-256
  `1fdc9785519fd41449431695849a029fc330b7f9ff3b898416f221fe913116c7`；staging/installed bundle
  `diff -qr` 无差异，strict codesign、audio-input=true、allow-jit=false、disable-library-validation=false、
  无 Debug dylib/quarantine 均通过。strict Release test observation 修正前的中间包保留在
  `~/.Trash/Intatis-selection-appearance-intermediate-20260821-121114.app`，executable SHA-256 为
  `65d0a80dff1ac904db31e077703a17c6dda122487a98540ab6a8f7a7560d3130`；实际带双重选区样式的旧包保留在
  `~/.Trash/Intatis-before-selection-appearance-20260821-120049.app`，其 executable SHA-256 仍为
  `659683ef665e8591bdfdfc5257179afba4548c6049c6e377c75ecd3671fc12e9`。本轮未重跑 iOS build（改动
  仅位于 `#if canImport(AppKit)`）、整仓 `swift test`、VoiceOver、Dark、
  Increase Contrast、modifier/double-click、跨消息、拖出 viewport autoscroll 或长 soak。

### 2026-08-20 macOS 单消息直接跨 block 选择

- `DocumentView` 现在在 macOS 为自己的 native TextKit leaves 注入一个
  `MarkdownDocumentSelectionCoordinator`。AppKit pan 只接普通无 modifier 的 primary-button drag；
  ordinary click、double/triple click、modifier selection、right-click 与 link 继续由 native AppKit
  处理。range order 使用稳定 registration，geometry 只负责命中 current leaf；table/code 的 macOS
  plain leaves 改用现有 `ParagraphView`，code 采用 unwrapped natural measurement，iOS 仍用原 SwiftUI
  leaf selection。Intatis macOS render config 的 `textSelectionConfig.isEnabled=false`，不再注入
  `Select more text` menu/modal。
- coordinator 专项 14/14、0 failures：覆盖 forward/reverse、多 paragraph、window point target、
  unequal-height table order、真实 DocumentView table row-major/list participation、same-row tab、combined
  pasteboard、TextKit 2 coordinator injection、unwrapped code、pan recognizer、transient system-accent
  emphasis、ordinary-click exact attributed restore、stream replacement cancel。
- vendor 完整 suite 为 79 XCTest + 25 Swift Testing、0 failures；vendor Release
  `-warnings-as-errors` build 通过。Intatis `MessageRenderingTests` 42/42 与 `ThreadLayoutTests` 25/25，
  合计 67/67；SwiftPM 全图 build、`IntatisMac` normal Debug（`ENABLE_DEBUG_DYLIB=NO`）和
  `IntatisiOS` generic Simulator Debug 均退出 0，仅有仓库既有 warnings。
- Computer Use 在 ad-hoc Hardened Runtime、unique bundle ID 的 code-selection fixture 中完成 heading →
  paragraph → code 正向拖拽和 code → heading 反向拖拽；mouse-up 截图中全部参与 leaf 为系统蓝色选区，
  无临时诊断标记。Command-C 后在宿主环境读取 general pasteboard，得到按文档顺序的 heading、paragraph
  与 code prefix，保留代码空行、换行与缩进。table fixture 先暴露 plain native leaf 的 unspecified
  measurement 零宽问题并在修复后实窗确认内容/网格完整；不等高 table 的 frame-order 漏 cell 问题随后
  改为 registration-order，并由真实 DocumentView host test 冻结。full-static fixture 实窗确认 heading、
  paragraph、quote、ordered/unordered/task lists 与 table 均使用正常 production layout；Computer Use
  对该独立窗口出现 `noWindowsAvailable`，未把 full-static 自动 drag 伪报为通过。
- 最终 `/Applications/Intatis.app` 为 `0.55 (55)` arm64 Debug、ad-hoc Hardened Runtime，main executable
  SHA-256 `659683ef665e8591bdfdfc5257179afba4548c6049c6e377c75ecd3671fc12e9`；strict codesign、
  audio-input=true、allow-jit=false、disable-library-validation=false、无 quarantine/Debug dylib均通过。
  更新前 footer build 保留在 `~/.Trash/Intatis-before-selection-20260820-231513.app`。安装后的真实 Chat
  自动 drag 因 Computer Use 只保留 process、连续返回 `noWindowsAvailable` 而未形成新证据；没有新增
  crash report。未运行整仓 `swift test`、跨消息选择、拖出 viewport autoscroll、modifier/double-click
  实际操作、VoiceOver、Light/Dark、Reduce Transparency/Increase Contrast 或 >160 秒 soak。

### 2026-08-20 macOS 逐回复复制与统计 footer

- `TurnStatsPayload` 以 optional `turnID` / `responseMessageID` 追加精确关联，旧 JSON 缺字段仍解码为
  nil；`ConversationProjection` / `CodeProjection` 支持 message-first 与 stats-first，并让 legacy unbound
  stats 只保留 latest session context。pending stats 是 presentation-only，最多保留 64 个未兑现 identity。
- `InferenceProfileProtocolTests` 4/4；组合 focused run 中 `ThreadLayoutTests` 25/25、
  `IntatisConversationCodeTests` + Chat stats + `SessionProjectionPumpTests` 32/32、Agent 多轮 usage 1/1，
  合计本轮直接相关 62 tests、
  0 failures。clipboard 测试使用 unique pasteboard，验证中文、Markdown、代码围栏、公式源文本与换行
  exact 保真；layout source-shape 冻结 icon-only copy、四项指标、三个 Mac composer Context-only 与 iOS
  full-usage 不变，并冻结 Chat/Code/Cowork 最后一行 stats identity 会进入 scroll signature。
- 完整受影响 target：`IntatisProtocolTests` 107/107、`IntatisConversationTests` 209/209、
  `IntatisAgentKernelTests` 221/221、`IntatisCoworkTests` 363/363，合计 900/900、0 failures。
  `IntatisSharedUITests` 本轮只运行直接相关 `ThreadLayoutTests` 25/25；未把仓库已知可能静默停滞的
  SharedUI async 全量 target 或整仓 suite 伪报为通过。
- SwiftPM 首次 focused run 完成完整受影响图 Debug 编译，随后独立 `swift build` 也退出 0。
  `IntatisMac` macOS Debug unsigned build 在
  `-disableAutomaticPackageResolution` 与既有 resolved package cache 下退出 0；只有仓库既有 warning。
  一次全新 DerivedData 尝试在任何源码编译前因 GitHub EventSource clone 的 LibreSSL
  `SSL_ERROR_SYSCALL` 失败，不能记为产品源码失败。
- Computer Use 只读观察确认当前构建的 assistant footer 暴露 `Copy message` icon action，Mac composer
  只剩 Context。为了显示 synthetic 四项指标另构建了 Debug-only unique bundle fixture；Computer Use
  对该临时 bundle ID 无法可靠取得窗口并与已安装同名 App 混淆，因此四项 footer 的真实像素、窄宽、
  Light/Dark 与 VoiceOver 仍为 `UNKNOWN`，不能由 AX source-shape 或单元测试冒充通过。
- `IntatisiOS` generic Simulator Debug unsigned build 也退出 0，证明 shared optional stats/projection 类型
  没有扩大 iOS linkage，且 iOS 继续使用完整 composer usage。未运行完整 `swift test`、真实
  provider/credential/network、正式签名、公证或发行打包；该 footer pass 当时未修改跨 block 选择，
  后续同日的上一节已单独实现并验证该能力。
- 本机安装 smoke 先暴露了 Xcode 27 Debug 产物的签名边界：默认 build 生成 launcher、
  `IntatisMac.debug.dylib` 与 `__preview.dylib`；整个 bundle 以 ad-hoc Hardened Runtime 重新签名并通过
  `codesign --verify --deep --strict` 后，真实启动仍由 dyld 以 `Library not loaded` / non-platform
  Team ID mismatch 拒绝。没有把 `com.apple.security.cs.disable-library-validation` 改为 true；该中间
  App 已移到 `~/.Trash/Intatis-failed-debug-dylib-20260820-211318.app`。
- 随后运行同一 `IntatisMac` Debug build，并显式设置 `ENABLE_DEBUG_DYLIB=NO`、
  `CODE_SIGNING_ALLOWED=NO` 与临时 `CONFIGURATION_BUILD_DIR`；`xcodebuild` 退出 0，最终 bundle 的
  `Contents/MacOS` 只含主可执行文件，`otool -L` 不再引用 `@rpath/IntatisMac.debug.dylib`。该 bundle
  再以 `Apps/IntatisMac/IntatisMac.DeveloperID.entitlements` 做 ad-hoc `--options runtime` 签名，
  strict codesign 通过，runtime flag 为 `0x10002(adhoc,runtime)`，audio input=true、allow-jit=false、
  disable-library-validation=false，且无 quarantine xattr。
- 已验证 staging 与最终 `/Applications/Intatis.app` 的 bundle identifier 均为
  `com.Vita0818.IntatisMac`、版本为 `0.55 (55)`、架构为 arm64、Debug dylib 不存在；最终主可执行文件
  SHA-256 为 `6e97d059e4c00b3662b35025a2e5396ba694100017d833e585cd883f0116b8a0`，CDHash 为
  `09baccf2552cabf1a08b3a1019572abd85eef804`。Computer Use 先从临时 bundle、再从 exact
  `/Applications/Intatis.app` 启动成功；最终 App 保持运行，accessibility state 可见 `Copy message`
  action 与 Context 控件。旧 `0.48 (48)` 安装位于
  `~/.Trash/Intatis-before-install-20260820-210656.app`，可恢复。该 smoke 是本机 arm64 Debug
  安装证据，不替代 universal Release、Developer ID、notarization、staple、Gatekeeper 或干净机器验收。

### JetBrains Mono 全局英文字体发布门槛

JetBrains Mono 是 macOS/iOS 第一方统一英文字体。Debug、Release 与发行构建都必须在普通、无参数
启动时使用同一条正式路径，不得存在 system-font opt-out 或实验参数。至少验证：

```sh
swift test --filter IntatisTypographyTests
swift test --filter 'MessageRenderingTests|ThreadLayoutTests|CoworkInferencePresentationTests'
swift test --package-path Vendor/SwiftStreamingMarkdown \
  --filter FirstReleaseContractTests
xcodegen generate
xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac \
  -configuration Debug -destination 'platform=macOS' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
```

还必须逐字节核对两端最终 App 中两个 TTF 和 OFL 的 SHA-256；无参数启动至少一个 macOS
fixture 与一个隔离 iOS Simulator，确认正式字体可见且进程不会因 registration/resource mismatch
退出。Core Text
probe 应分别观察英文使用 JetBrains Mono、中文使用系统 CJK fallback。source scan 必须证明第一方
production SwiftUI 的 direct `.font(.system/semantic...)` 已进入 product typography seam；vendor code block
只能读取现有 `MarkdownRenderConfig`，默认配置行为不变。

正式 release 须核对 exact dependency closure；Simulator/fixture 不能替代 Dark、超大 Dynamic Type、VoiceOver、
真实长中英混排、系统 sheet/menu/control、真机和正式签名/公证验证。

2026-08-19 当前直接证据：

- 官方 v2.304 两份 TTF、OFL 与仓库/两端 Debug App bundle 的 SHA-256 分别一致为
  `662a196d...cac016`、`f115aaa1...63f2`、`30f0c136...ac4ad`；最终两个 bundle 均为 `0.55 (55)`；
- 两份 TTF 已收口到 `IntatisSharedUI` 的 `Bundle.module`；四个 App 各自只含一个
  `Intatis_IntatisSharedUI.bundle` 和 exactly 2 个 JetBrains TTF，没有残留 App-root duplicate；
- `IntatisTypographyTests` 在 Debug 与 Release 配置各 2/2；测试冻结 JetBrains Mono 为每个共享
  typography role 的正式 design；
  Debug 下与 `MessageRenderingTests` 41、`ThreadLayoutTests` 22、
  `CoworkInferencePresentationTests` 8 合计 73/73、0 failures；vendored Markdown 完整 suite 为
  79 XCTest + 11 Swift Testing、0 failures；
- macOS/iOS Debug 与 Release unsigned build 均退出 0，只报告仓库既有 warnings；Release macOS
  executable 为 `x86_64 arm64`，四个最终 App 均为 `0.55 (55)`，Release bundles 的两份 TTF/OFL
  hash 也与仓库一致；四个 build 已在正式字体接线后重新执行；
- 当前 iPhone 17 Pro 隔离 Simulator 已在**没有任何字体参数**时启动成功，`New chat`、model label 与
  composer placeholder 均显示 JetBrains Mono；macOS Renderer Fixture 也在没有字体参数时启动并
  稳定存活；
- Core Text run probe 报告英文为 `JetBrainsMono-Regular`、中文为 `PingFangSC-Regular`；
- 尚未完成 Dark、超大 Dynamic Type、VoiceOver、真实长中英混排、系统 sheet/menu/control、真机、
  正式签名/公证；因此本条是字体接线证据，不是整个 v0.55 release GO。

2026-08-19 iOS large title 收窄的直接证据：

- `IOSRootView` 的当前 session 与 Settings 标题继续使用 JetBrains Mono large-title role 和
  `@ScaledMetric(relativeTo: .largeTitle)`，但 iOS-only nominal size 从共享 30pt 收窄为 22pt；
  抽屉品牌字号、共享 `IntatisTypography` 事实源和 macOS 标题均未修改；
- `IntatisTypographyTests` 1/1、0 failures，确认共享 `.largeTitle` 仍为 30pt；
- `IntatisiOS` generic Simulator Debug unsigned build 退出 0，最终 bundle 为 `0.55 (55)`，只出现
  仓库既有 unused-result / deprecated `onChange` warnings；
- 新构建已安装并启动于 iPhone 17 Pro Simulator。Light 主界面截图确认 `New chat` 标题在 64pt
  header 内保持居中、无截断且未挤压两侧 sidebar/New 按钮，底部 composer 几何未变化；Settings
  使用同一 22pt override。未运行完整 SwiftPM suite、Dark、超大 Dynamic Type、VoiceOver 或真机矩阵。

2026-08-19 iOS Chat 键盘 dismissal 修复的直接证据：

- `IntatisThreadComposer` 的 Send 按钮与键盘提交改为共用同一个 guarded `submit()`；iOS 在调用
  `ChatViewModel.send()` 前先把本地 FocusState 设为 `false`，macOS 条件分支不改变既有焦点行为；
- shared Chat 消息 `ScrollView` 只在 iOS 增加 `.scrollDismissesKeyboard(.interactively)`，模型输出、
  自动滚动与输入重新启用不再拥有重新聚焦入口；
- `ThreadLayoutTests` 22/22、0 failures，新增 source-shape 回归同时冻结 Send/Return 两条提交路径、
  iOS-only FocusState 清理和 interactive scroll dismissal；
- `IntatisiOS` generic Simulator Debug unsigned build 退出 0，最终 bundle 为 `0.55 (55)`，只出现仓库
  既有 unused-result / deprecated `onChange` warnings；隔离的临时 iPhone 17 Pro Simulator 已成功启动
  当前 App，且未读取或使用真实 provider 配置；
- 当前 Computer Use 服务不能识别 Xcode Simulator，已安装的 `simctl io` 也不提供 touch/HID 注入，
  因此没有把真实 Send 后键盘动画或消息区下拉手势伪报为自动化通过；这两项仍需人工点按确认。

2026-08-11 本机 LibreOffice 26.8 替换与真实链路证据：

- 官方 `LibreOfficeDev_26.8.0.0.beta1_MacOS_aarch64.dmg` 为 298,129,546 bytes，SHA-256
  `a56a5af102c78c294b3da48154958ecd9fa52d357589305c54e6e215ce611900`；`hdiutil verify` 和官方
  detached PGP signature 均通过。CLI exact 输出为 `LibreOfficeDev 26.8.0.0.beta1`，固定后端只解析
  `~/Library/Application Support/Intatis/document-runtime/libreoffice/26.8.0.0.beta1/LibreOffice.app`；
- 在不受 Codex 外层 sandbox 干扰的宿主环境，DMG 原件、替换前 staging 和最终固定路径均通过
  `codesign --verify --deep --strict`；签名者为 The Document Foundation Developer ID（Team ID
  `7P5S3ZLCN7`），`spctl --assess --type execute --verbose=4` 返回 `accepted` / `Notarized Developer ID`。
  早先在外层受限环境得到的 Code Signing subsystem internal error 不能作为宿主签名失败证据；
- 一次无 Intatis Seatbelt 的诊断运行确实让内置 Python 改写了签名包内的 `__pycache__/*.pyc`，随后
  `codesign` 正确报告 sealed resource modified。该副本已移入废纸篓，并从仍为只读、已验签的官方
  DMG 重新复制；这与前述外层 sandbox 假阴性是两个不同事件；
- 根因最终收敛为 LibreOffice SingleOffice IPC。`OSL_SOCKET_PATH` 是 LibreOffice bootstrap 值，
  必须以 `-env:OSL_SOCKET_PATH=...` 传入；旧实现只设置普通 process environment，因此无效。长 Darwin
  temp root 还会在 LibreOffice 追加 `OSL_PIPE_*` 后超过 `sockaddr_un.sun_path`，在 `socket()` 前就返回
  `BE_PATHINFO_MISSING`；
- fixed runner 现为每次调用创建 `/private/tmp/intatis-lo-<12 hex>`，创建后以 `lstat` 证明它是
  current-UID、非 symlink、`0700` 目录。Seatbelt 只允许该 root 的文件读写、本地 `OSL_PIPE_*`
  Unix socket bind/connect，并继续拒绝 IP 网络和其他 Unix socket；调用结束清理 exact root。对应
  profile 单元测试 1/1、`DocumentFixedBackendsTests` 4/4；
- `INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 swift test --filter DocumentToolsIntegrationTests/testInstalledDocumentRuntimeCoreToolChainWhenEnabled`
  在干净副本上 1/1：
  DOCX write/read/preview/export/PDF read/render；PPTX write/read/preview/export/PDF read；XLSX write、
  LibreOffice Calc round-trip、公式文本保留、data-only cache 值 `4`、preview/export。真实测试后再次
  `codesign --verify --deep --strict` 与 `spctl`，结果仍为 valid/accepted，证明 Intatis 路径没有修改
  App 签名资源。旧 26.2.4 runtime 已按用户授权移入废纸篓；
- 当前用户 runtime 的真实 smoke 仍只证明这台开发机，不代表 App bundle、双架构、NOTICE、许可证或
  clean-machine distribution closure 已完成。真实 EPUB write/EPUBCheck 和 strict pdfcpu +
  Docling/Tesseract OCR 的既有 1/1 证据继续有效。

2026-08-11 model-driven Knowledge 实现与 live acceptance 证据：

- `IntatisKnowledgeTests.xctest` 118 tests / 0 failures；当前宿主 local-core corpus 指标为
  Recall@1 0.529、Recall@5 0.882、MRR 0.681、nDCG@5 0.698、citation coverage 0.882、citation
  precision 1.000，最近一次离线 Knowledge run 的 deterministic search proxy 200 次平均 1.640 ms；
  这些不是 semantic reranker uplift 报告；
- `KnowledgeModelProviderTests` 11/11、`ToolSpecMetadataTests` 5/5、`CLIProviderAdapterTests` 9/9、
  `ModelDrivenKnowledgeAgentLoopTests` 2/2、`TurnGroundingEvidenceRegistryTests` 7/7、
  `ToolRegistryLeaseTests` 25/25、SecretScanner 精确回归 1/1、checked drain 1/1。
  AgentLoop 用两个 exact external store 跑通 2 build + 2 search，4 个
  prepared/settled correlation 一致，两次 search 均为 `rerank_applied=true`，两个 citation 通过
  current-turn revalidation；随后 fresh host generation 重新打开其中一个 durable external store 并完成
  第三次 query embedding/semantic rerank/citation，最终 query/reranker 各调用 3 次、external scope
  acquire/release 5/5；
- 普通 file mutation 与实际 Seatbelt managed terminal anti-bypass 定向通过；legacy snapshot layout
  writer-only atomic migration、read-only no-mutation、pointer `commitUncertain`、provider route identity/
  redirect/malformed/timeout/cancel/credential failure 均通过；official-shaped provider fixture 还验证了
  embedding token 与 reranker token/billable-search-unit 解析，build descriptor 保持 `.write` 且
  network/model-cost 风险独立存在；
- `INTATIS_REAL_KNOWLEDGE_SMOKE=1` 已使用 OpenRouter exact routes 运行 1/1、0 failures（3.447 秒）：
  `google/gemini-embedding-2` 返回并通过 1536 维校验，provider usage 为 input/total token 7；
  `cohere/rerank-4-pro` 返回完整两候选 permutation、有限 score，provider usage 为 search unit 1；
- `INTATIS_REAL_KNOWLEDGE_QUALITY=1` 运行 1/1、0 failures：冻结 8-query 中英/代码集合的 dense
  embedding baseline 为 MRR 1.000、nDCG@5 1.000、Recall@5 1.000；configured semantic reranker 为
  MRR 1.000、nDCG@5 0.990、Recall@5 1.000。embedding usage 为 343 token，reranker usage 为 8
  search units。该结果证明 100% configured-rerank 调用和独立指标报告，但没有证明 uplift，nDCG@5
  回退 0.010，不能改写成推荐模型优于 baseline；
- `INTATIS_REAL_KNOWLEDGE_AGENT_E2E=1` 运行 1/1、0 failures（32.686 秒）：真实 Agent 调用了
  `list_files` / `read_file` / `write_file` / `build_knowledge` / `search_knowledge`，在隔离外部 store
  完成 read-organize-build-search-cite，最终回答含通过 current-turn revalidation 的 exact evidence ID；
- `INTATIS_REAL_KNOWLEDGE_PDF_E2E=1` 以项目根目录 `test-DS-Algorithm` 为 source 运行 1/1、0 failures
  （110.980 秒）。harness 只复制并读取 `DPV-chap2.pdf` 6–7 页、`DPV-chap4.pdf` 5–7 页、
  `DPV-chap6.pdf` 1–5 页；Agent 实际调用三次 `read_pdf`，写出 3 个 grounded concept，build 生成
  22 chunks，再用 configured query embedding 与 required reranker 搜索并在覆盖 mergesort、Dijkstra、
  LIS 的最终答案中引用 exact evidence。原始 PDF 未修改；
- macOS Debug App 通过 Computer Use 执行真实 Code 交互：用户自然语言给出 workspace 外 exact path 后，
  首次 `search_knowledge` 显示 NSOpenPanel 并只授权该目录，保存 session-owned binary
  `knowledge-access.plist`（mode `0600`、schema 1、revision 1）。退出应用、重新启动、恢复同一 Code
  session 后再次搜索没有出现授权面板，证明 bookmark restore；测试目录为空，因此两次均按设计返回
  typed `KB_INDEX_NOT_READY` 且未写文件；
- 工作区沙箱外精确运行
  `TerminalToolsTests.testManagedTerminalCannotMutateKnowledgePublicationWithEmptyDenyList` 1/1、0 failures，
  证明实际 Seatbelt managed terminal 不能绕过 Knowledge publication deny floor。默认 skipped 的其它
  real provider/browser/Git/document/Keychain 用例不计为真实环境通过；
- `IntatisMac` macOS Debug 与 `IntatisiOS` generic Simulator Debug unsigned build均退出 0；Mac 只出现
  仓内既有 warning，未构建 legacy `IntatisMacAppStore`。本轮整仓 `swift test` 已完成 Tools 与 Skills，
  随后 `IntatisSharedUITests.xctest` 进程持续约 7 分钟 0% CPU 且无新输出，复现既有 async scheduler
  挂起后人工中断，命令退出 130；不得记为整仓全绿，也没有观察到本任务相关 failure。本段所列
  Knowledge/Provider/Agent/Cowork/Permission/terminal 定向 suites 均独立退出 0。账单金额因 provider
  未返回 versioned monetary amount 而不推算。

2026-08-09 OKF / RAG knowledge bundle 本地 core 的直接证据：

- 最终 root run 的 `IntatisKnowledgeTests.xctest`：106 tests / 0 failures / 0 unexpected / 0 skips，
  7.224 秒（wall 7.230 秒）；其中 focused Build/Search/SourceLocator 为 52/52，新增 diagnostic
  init/decode 脱敏回归 1/1；
- 冻结 corpus：Recall@1 0.529、Recall@5 0.882、MRR 0.681、nDCG@5 0.698、citation coverage
  0.882、citation precision 1.000、unanswerable lexical TNR 3/3；deterministic dense+BM25 proxy
  200 次总计 324.994 ms、平均 1.625 ms，serialized index 30,941 B、memory proxy 103,230 B；
- `TurnGroundingEvidenceRegistryTests` 6/6；Cowork local `search_knowledge` durable probe 1/1，证明
  permission request/resolved → prepared → bounded structured tool result → settled → current-turn final
  citation revalidation → close/drain；narrow-mailbox negative 1/1；
- host exact authority/current snapshot/cancel-drain 1/1，concrete search + source-locator + final-grounding
  purge 1/1；本地 dynamic registration intent、DeterministicPolicyGate reviewer boundary 和
  date-only stale UTC boundary各自定向通过；
- `IntatisMac` unsigned Debug arm64 build 通过；`IntatisKnowledge` / `IntatisCLI` arm64 与 x86_64
  cross-build 通过。x86_64 只证明编译；Intel 真机、最低支持 macOS、large corpus、真实 remote
  embedding/reranker、hybrid/reranker comparative uplift、签名/公证仍为 `UNKNOWN`；
- urgent purge 的 current-pointer removal 是持久 admission boundary，receipt tombstone 阻止旧回执并发
  复活；它不是 pointer/receipt/physical delete 的跨组件 crash-atomic 事务，也不等于 secure erase。

2026-08-10 Agent durable多模态上下文最小闭环的直接证据：

- `DurableOwnerOnlyFileTests` 2 tests、`ArtifactImageResolverTests` 10 tests、
  `IntatisProvidersToolCallingTests` 36 tests、`AgentToolOutputLoweringTests` 6 tests、
  `DurableMultimodalAgentLoopTests` 9 tests、`CLIAttachmentTests` 4 tests，均为0 failures；
- `ModelHistoryMediaBatchEventLogTests` 7 tests、`SubmittedIntentStoreTests` 13 tests，均为0 failures；前者
  覆盖same-turn/call result与完整settlement identity，后者覆盖Retry planner和outbox payload保真；
- `swift test --filter ModelHistory`覆盖Protocol 14、Conversation 17、AgentKernel 49，共80 tests / 0
  failures；验证v2 direct/checkpoint、append-return binding、原call FCO、active-window summarizer与
  summary-only checkpoint；
- `ComposerAttachmentTests` 2 tests / 0 failures；验证PNG/JPEG扩展到canonical MIME的确定性映射、
  exact bytes读回与非图片typed拒绝。`testChatLoopPersistsAndRehydratesImageAttachmentsAcrossTurns`
  1 test / 0 failures，验证既有Chat跨轮图片持久化未回归；
- 从`v0.41` exact commit `e5f64ed`归档源码并临时编译旧reader fixture：3 tests / 0 failures；旧
  projector拒绝schema-v2 direct item及v1 checkpoint后的schema-v2 direct suffix，旧protocol拒绝
  schema-v2 checkpoint；
- `swift build --disable-sandbox --target IntatisCLI`退出0；`IntatisMac` macOS Debug和`IntatisiOS`
  generic Simulator Debug unsigned build均退出0，只有仓库既有unused-result/deprecation warning；
- 真实端点smoke的opt-in测试壳已编入当前`IntatisCLITests`；未设置开关时必须skip且不发请求，真实
  credential/network调用仍未执行；
- 当前完整`swift test --disable-sandbox`已成功构建全部targets，并先完成Tools 209 tests（15 skipped）
  与Skills 29 tests、均0 failures；随后在既有SharedUI
  `MarkdownSchedulerTests.testCancelAllDoesNotReleaseSynchronousWorkBeforeFinish`等待超过3分钟。采样显示
  XCTest停在async expectation且无继续工作的worker，因此人工中断，命令退出130。没有观察到多模态
  failure，但完整suite不能据此宣称全绿；本轮未越界修改该无关hang；
- `CLIAttachmentTests`除2个附件loader用例外，还直接覆盖CLI Code复用同一session log/ArtifactStore的
  next-turn，以及CLI Cowork销毁并重建shipping `Orchestrator.runtime`、EventLog与ArtifactStore后的exact
  `@main`图片replay；当前工作树直接运行4 tests / 0 failures；
- 未执行真实OpenAI credential/network smoke；线上多模态FCO仍是release-only外部门，不能从scripted
  provider外推。未重放当时实际分发的旧App制品，但已用exact旧源码编译fixture覆盖reader语义；
  `git diff --check`通过。

2026-08-11 `v0.48 (48)` 版本推进、shipping target 构建与本机开发安装的直接证据：

- `xcodegen generate` 通过；`scripts/check-version-consistency.sh` 通过并输出
  `Intatis version is consistent: 0.48 (build 48)`；
- `IntatisMac` unsigned universal Release 构建退出 0，最终 bundle 为 `0.48 (48)`，bundle
  identifier 为 `com.Vita0818.IntatisMac`，可执行文件包含 `x86_64 arm64`；
- `IntatisiOS` generic Simulator Debug unsigned 构建退出 0，最终 bundle 为 `0.48 (48)`；
  两个构建只报告仓库既有 unused-result / deprecated API warnings；
- staging App 使用 `IntatisMac.DeveloperID.entitlements` 完成 ad-hoc Hardened Runtime 签名；
  embedded entitlements 为 audio input=true、JIT=false、library validation 未关闭，
  `codesign --verify --deep --strict` 通过；
- `/Applications/Intatis.app` 已原子替换为上述 `0.48 (48)` 构建，版本、bundle identifier、
  双架构、entitlements 和可执行文件 SHA-256 均与 staging 副本一致，且无 quarantine
  xattr。安装前的 `0.40 (40)` 保留在
  `~/.Trash/Intatis-before-install-20260811-201644.app` 作为可恢复备份；
- 本轮版本/安装没有再跑 SwiftPM 测试；同一业务工作树在版本变更前已有 focused
  154/154、完整 SwiftPM 退出 0、Cowork 362/362 和 AgentKernel 210/210 证据。本轮未运行
  Developer ID 正式签名、公证、staple、Gatekeeper、DMG/ZIP 打包或启动后 UI/真实 provider
  smoke，因此这是本机开发安装证据，不是正式 release 证据。

2026-08-08 `v0.40 (40)` 版本推进、shipping target 构建与本机开发安装的直接证据：

- `xcodegen generate` 通过；`scripts/check-version-consistency.sh` 通过并输出
  `Intatis version is consistent: 0.40 (build 40)`；
- `IntatisMac` unsigned universal Release 构建退出 0，最终 bundle 为 `0.40 (40)`，bundle
  identifier 为 `com.Vita0818.IntatisMac`，可执行文件包含 `x86_64 arm64`；
- `IntatisiOS` generic Simulator Debug unsigned build 退出 0，最终 bundle 为 `0.40 (40)`；
  两个构建只报告仓库既有的 unused-result / deprecated `onChange` warning；
- 安装前使用 `IntatisMac.DeveloperID.entitlements` 对 staging App 完成 ad-hoc Hardened Runtime
  签名；读回 microphone input=true、JIT=false、library validation 未关闭且无 App Sandbox，
  `codesign --verify --deep --strict` 通过；
- `/Applications/Intatis.app` 已安装上述 `0.40 (40)` 开发构建，无 quarantine xattr；安装后
  可执行文件与 staging 副本的 SHA-256 均为
  `617c5b50a5e20e580c0a5a7d2059bc2337b19e92de66dd0779f8ada2d5a44cbe`。安装前的
  `0.36 (36)` 曾移至
  `/Users/vita/.Trash/Intatis-before-install-20260808-163949.app`，随后已按用户要求永久删除；
  精确路径检查为 absent，Finder 复核废纸篓中名称含 `Intatis` 的项目数为 0；
- 本轮没有重跑 SwiftPM 单元测试，也没有启动 App 做 UI/真实 provider smoke；紧随其后的
  Cowork permission authorization context 完整测试证据覆盖同一业务源码。未运行 Developer ID
  正式签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包，因此这是本机开发安装证据，不是正式
  release 证据。

> 以下 2026-08-08 与“authorization reporter 结构化交接”条目仅是 v0.47 历史验证记录；
> Reporter 测试/真实 output-function smoke 已被 2026-08-11 same-call sidecar 流程替代，不能作为
> 当前可运行 gate。当前 gate 见本文件顶部命令和后续 2026-08-11 sidecar 验证条目。

2026-08-12 Cowork same-call permission sidecar corrective focused 直接证据：

- `PermissionReviewControlPlaneTests`：47/47；覆盖完整 transient args/string sidecar + mechanical host facts、
  objective/role/deliverable/userGoal/user/assistant/history/PDF marker 不进入 live prompt、delimiter injection、
  secret input、live/cache/recovery invocation 复验、recovered allow 拒绝、dedicated host admission、伪造
  agentAdmission kind 拒绝、固定 reviewer reason/provider diagnostic 与 durable non-echo；
- `AgentLoopPolicyTests`：37/37；覆盖 ask-only sidecar enforcement、manual reserved-key 拒绝、safe structured
  read failure 继续 batch、fresh-review fuse、in-engine reviewer 误配 fail closed，以及 automatic Cowork
  `tool_search` output 只在下一轮 provider request copy 中装饰；
- `AutomaticPermissionReviewTests`：35/35；覆盖 production Orchestrator/control-plane 接线、provider-required string schema、
  missing → missing → valid 的相同 business args 不触发 permission lifecycle/reviewer fuse、valid sidecar 只留
  current-turn live history、automatic attach 专用入口、allow/deny/cancel/failure 和 Reporter 不再 dispatch；
- `DurableMultimodalAgentLoopTests`：9/9；覆盖 user/FCO image 不再 blanket deny、sidecar 摘要媒体证据、
  raw sidecar 不进入 durable history，以及 missing sidecar 不伪造可跨重启恢复的权限拒绝；
- `AuthorizationSidecarTests`：12/12；`IntatisPermissionReviewerTests`：10/10；
  `PermissionReviewProtocolTests`：12/12；分别覆盖 schema decoration/extraction/binding、strict 发网前
  recursive fail-fast、deferred tool request-copy/durable isolation、plain-text verdict 与
  legacy/additive receipt wire；
- 以上合计 162 tests / 0 failures。strict-schema correction 还单独通过 `SearchKnowledgeToolTests` 4/4，
  并在 `AuthorizationSidecarTests` 中抓取 OpenRouter 与 OpenAI-compatible 最终 HTTP body 验证 wire invariant。
  `ModelHistoryCompactionAgentLoopTests` 另覆盖 deferred schema 对压缩阈值、compactor request 与 durable raw output
  的影响。`swift build --disable-automatic-resolution` 通过；受影响目标完整结果为 `IntatisAgentKernelTests` 217/217、
  `IntatisKnowledgeTests` 118/118、`IntatisCoworkTests` 364/364、`IntatisCLITests` 45/45（8 skipped）。
  `IntatisMac` macOS Debug、`CODE_SIGNING_ALLOWED=NO` 构建通过，只出现仓库既有 warnings。完整
  `swift test --disable-automatic-resolution` 完成 Tools 223/223（19 skipped）后挂于仓库既有 SharedUI async
  waiter，连续两分钟无输出后人工中断为 130，不能记为本次全量通过。opt-in 真实 provider sidecar smoke
  成功编译但因未设置计费开关而按设计跳过；本次未运行 UI/manual switch smoke，因此线上 route
  compliance、token、latency 与交互仍未证明；route-derived input ceiling 与
  `review_input_too_large` 仍未实现。

2026-08-08 Cowork automatic permission authorization context 修复的历史直接证据：

- `PermissionReviewProtocolTests`：11 tests / 0 failures；验证 additive optional wrapper、旧事件
  缺字段解码，以及协议没有增加 model-supplied author/latest-user/digest；
- `PermissionAuthorizationContextReporterTests`：7 tests / 0 failures；覆盖 `continue` 语义、同一
  acting provider/model 的 exact request prefix、`tools: []`、canonical evidence closure、worker
  scope 隔离、unknown handle、secret-bearing output、completion marker、timeout、caller cancel 与
  request-owned stream termination；
- `AutomaticPermissionReviewTests`：31 tests / 0 failures；`PermissionReviewControlPlaneTests`：
  40 tests / 0 failures；覆盖合法 report 与 canonical EventLog 原文分栏、缺失/malformed context、
  omitted intervening revocation、unknown future event、每个 tool call 独立 report、hard deny 不调用
  reporter，以及 reviewer provider 前的 typed durable deny；
- `testCancelAllDrainsDataPlaneBeforeShuttingDownPermissionReviewer`：1 test / 0 failures；确认 session
  cancel 会 drain 原始 inference、request-owned report 与 reviewer，不会释放 denial 后继续第三次
  inference 或执行文件写入；完整 `IntatisCoworkTests`：346 tests / 0 failures；
- managed sandbox 中第一次完整 `swift test --disable-sandbox` 因外层 Seatbelt 拒绝既有 browser/
  LaTeX/Git/process 子进程启动而失败；在允许真实子进程边界的宿主环境用同一 working tree 重跑后，
  14 个 XCTest target 合计 1727 tests / 19 conditional skips / 0 failures。`swift build
  --disable-sandbox` 与 `git diff --check` 均通过；
- 本次未修改 App/UI、Xcode 工程或平台 target，因此未另跑 macOS/iOS App build；未执行真实
  provider/credential/network smoke，不能从 scripted provider 测试外推线上模型质量。

2026-08-11 authorization reporter 结构化交接修补的历史直接证据：

- `PermissionAuthorizationContextReporterTests`：7 tests / 0 failures；验证唯一 output-only function
  schema、单 call/无 prose、strict host parse、canonical evidence closure，以及异常输出 fail closed；
- `PermissionReviewProtocolTests`：11 tests / 0 failures；`PermissionReviewControlPlaneTests`：
  40 tests / 0 failures；`AutomaticPermissionReviewTests`：32 tests / 0 failures；新增同一 assistant batch
  两个 ask-class 写操作分别报告、分别审查并分别执行的集成覆盖；
- 在用户明确允许真实网络、计费及向 OpenRouter 发送测试内容后，当前 exact Agent route 运行
  `testRealAgentOutputFunctionShapeWhenEnabled`：1 test / 0 failures，普通单 function request 成功返回
  一个同名结构化 call。探索过程中 forced `tool_choice` 与 `response_format` 均被该 exact route 的上游
  参数兼容性检查拒绝，因此生产合同不依赖这两个可选参数；
- `IntatisMac` Debug、`CODE_SIGNING_ALLOWED=NO` 构建通过；仅出现既有 unused-result 与 SwiftUI
  deprecation warnings；
- 本节是对 2026-08-08 `tools: []` 报告器测试证据的后续修正，不改变 reviewer 自身无工具判决请求。

2026-08-08 Cowork current-run 终态控制与 correlation-scoped mailbox 修复的直接证据：

- 新增 `finish_run` / `stop_run`、host-bound RunController、`continuation_run_close_requested`
  first-write claim、in-flight admission/authorization tombstone、restore/drain fence，以及 information
  request/reply 的 `conversationID` / `basedOn` 协议和 authority-class 窄租约；普通 message/reply
  receipt 均不 ACK，实质追问使用 fresh RequestID；
- run control、mailbox correlation、协议 round-trip、EventLog CAS/projection、tool registry/legacy lease
  migration、prompt、bundled Skill、permission 与 non-replayable mailbox side-effect focused tests 均通过；
  完整 `IntatisCoworkTests` 为 341 tests / 0 failures；完整 `swift test` 退出 0，其中
  `IntatisAgentKernelTests` 175 tests、`IntatisSharedUITests` 141 tests，所有已运行 target 均为
  0 failures；
- `cowork-agent-orchestration` 通过仓内 `quick_validate.py`；`xcodegen generate` 通过；
  `scripts/check-version-consistency.sh` 输出 `Intatis version is consistent: 0.38 (build 38)`；
- `IntatisMac` macOS Debug unsigned build 与 `IntatisiOS` generic Simulator Debug unsigned build
  均退出 0；读回两个最终 bundle 均为 `0.38 (38)`。构建只报告仓库既有的 unused-result /
  deprecated `onChange` warning；
- 按 `computer-use` Skill 通过 Sky 分别尝试按刚构建 App 的绝对路径、bundle ID 启动，并尝试列举
  apps；所有调用都在服务启动层返回 `Sky Computer Use service startup request failed`，因此本轮没有把 UI 启动、真实 provider
  自主调用工具或长时多 agent 会话标为已验证。未安装 App，未运行 Developer ID 正式签名、
  公证、staple、Gatekeeper 或 DMG/ZIP 打包。

2026-08-07 `v0.38 (38)` 版本推进的直接证据：

- `xcodegen generate` 通过；`scripts/check-version-consistency.sh` 通过并输出
  `Intatis version is consistent: 0.38 (build 38)`；
- `IntatisMac` unsigned universal Release 构建退出码为 0，最终 bundle 为 `0.38 (38)`，
  可执行文件包含 `x86_64 arm64`；
- `IntatisiOS` generic Simulator Debug unsigned build 退出码为 0，最终 bundle 为
  `0.38 (38)`；两个构建只报告仓库既有的 unused-result / deprecated `onChange` warning；
- 本轮是版本元数据与当前文档变更，未运行 SwiftPM 单元测试；未安装 v0.38 App，
  `/Applications/Intatis.app` 读回仍为 `0.36 (36)`。也未运行 Developer ID 正式签名、
  公证、staple、Gatekeeper 或 DMG/ZIP 打包。

2026-08-07 Cowork terminal/mailbox reconciliation 修复的直接证据：

- 报告要求的 TaskContract、AgentLoop policy、model history、context projection、CodeProjection、
  MessageBus/delegation、orchestration reliability、WorkTask runtime 与 permission reviewer focused
  tests 均通过；完整 `swift test --skip-build` 最终退出 0，其中 `IntatisCoworkTests` 327 tests、
  `IntatisSharedUITests` 141 tests、`IntatisAgentKernelTests` 175 tests，均为 0 failures。真实
  Git/browser/Keychain 等显式 opt-in host smoke 仍按设计 skipped；
- `xcodegen generate` 与 `scripts/check-version-consistency.sh` 通过，版本一致为 `0.36 (36)`；
  `IntatisMac` macOS Debug、`IntatisiOS` generic Simulator Debug unsigned build 均退出 0；
- `IntatisMac` unsigned universal Release 通过；最终 bundle identifier 为
  `com.Vita0818.IntatisMac`，可执行文件包含 `x86_64 arm64`。临时 staging App 使用仓库
  Developer ID entitlements 完成 ad-hoc Hardened Runtime 签名，embedded entitlements 为
  audio input=true、JIT=false、library validation 未关闭，`codesign --verify --deep --strict`
  通过；
- `/Applications/Intatis.app` 已替换为该构建，版本、bundle identifier、架构和可执行文件
  SHA-256 均与 staging 产物一致，且没有 `com.apple.quarantine` xattr。旧安装保存在废纸篓
  `Intatis-before-install-20260807-1627.app`，可恢复；新进程的实际可执行路径已核对为
  `/Applications/Intatis.app/Contents/MacOS/IntatisMac`；
- 对截图对应的 `cowork_rqx6cgvb` 事故日志做了只读回放审计：仍为连续 `seq 0...4564`
  （4565 行），冷启动后 mtime 仍为 `2026-08-07 13:09:04 +0800`，没有自动 provider 重跑或
  追加事件。事故链保留 `seq 2873 message_completed`、`2874 model_history_item`、
  `2878 failed turn_outcome`、`2879 task_failed`；新增 projection/history 回归证明前两项会被
  后续 authoritative failure 分别标为未完成和从 provider history 排除；
- 推荐的 Computer Use 已按 skill 通过 `node_repl + @oai/sky` 多次尝试（含 kernel reset 和
  app path/bundle ID 两种目标），均在 Computer Use service startup 阶段失败。fallback
  `screencapture` 被 Screen Recording 拒绝，System Events 也被 Apple Events 权限拒绝，因此本轮
  **没有把失败卡片的真实窗口像素/AX 文本冒充为已验证**；只确认安装包成功启动、进程路径正确、
  冷启动未改写事故日志。此限制不影响上述单元、全量、构建、签名与持久化证据，但运行时视觉
  卡片仍需在具备 Computer Use/Screen Recording 权限的环境补做。

本轮没有运行 Developer ID 正式签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包；以上是本机
开发安装证据，不是正式 release 证据。遗留 `IntatisMacAppStore` 未构建。

2026-08-07 v0.36 阶段未提交工作树 macOS 本机开发安装的直接证据：

- `xcodegen generate` 与 `scripts/check-version-consistency.sh`：通过，版本一致为 `0.36 (36)`；
- `IntatisMac` unsigned universal Release：通过；最终 bundle identifier 为
  `com.Vita0818.IntatisMac`，可执行文件包含 `x86_64 arm64`；
- 使用仓库 Developer ID entitlements 对临时 App 完成 ad-hoc Hardened Runtime 签名；embedded
  entitlements 已读回 microphone input=true、JIT=false、library validation 未关闭，
  `codesign --verify --deep --strict` 通过；
- `/Applications/Intatis.app` 已替换为上述当前工作树构建，版本仍为 `0.36 (36)`，无 quarantine
  xattr；安装后可执行文件与临时验证产物的 SHA-256 一致。旧的同版本 App 已以 timestamped
  `Intatis-before-install-*.app` 移入废纸篓作为可恢复备份；
- 本轮没有运行 Developer ID 正式签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包，也没有自动启动
  App；因此这是本机开发安装证据，不是正式 release 或运行时 UI smoke 证据。

2026-08-07 macOS Chat/Cowork composer 图片附件复用的直接证据：

- `ComposerAttachmentTests`：2 tests / 0 failures；覆盖 security-scoped URL reader、ArtifactStore
  保存/精确 bytes 读回、image provider input 解析，以及非图片文件“本地保留但发送前 typed 拒绝”；
- `testChatLoopPersistsAndRehydratesImageAttachmentsAcrossTurns`：1 test / 0 failures；验证
  `UserMessagePayload.attachments` 只持久化 ArtifactID，并在下一轮把历史图片和当前图片分别恢复到
  provider request；
- 完整 `swift test`：通过（exit 0）；真实 Git/browser/Keychain 等显式 opt-in host smoke 仍按设计
  skipped，构建只报告仓库既有的 unused-result / deprecated `onChange` warning；
- `xcodegen generate`：通过；`IntatisMac` macOS Debug unsigned build：通过；`IntatisiOS` generic
  Simulator Debug unsigned build：通过；
- 未执行 macOS 文件选择/拖放/视觉命中手动 smoke，也未执行真实 provider/credential/network 图片
  对话，因此这里只证明共享 UI/runtime 编译、durable attachment/replay 单元回归与 iOS linkage 边界，
  不外推真实 provider 对全部 image MIME 的线上支持。

2026-08-05 `v0.36 (36)` 版本、shipping target 构建与本机安装的直接证据：

- `xcodegen generate`：通过；`scripts/check-version-consistency.sh`：通过并输出
  `Intatis version is consistent: 0.36 (build 36)`；
- `IntatisMac` unsigned universal Release：通过；最终 bundle 为 `0.36 (36)`，可执行文件包含
  `x86_64 arm64`。安装前以仓库 Developer ID entitlements 完成 ad-hoc Hardened Runtime 签名，
  `codesign --verify --deep --strict` 通过；
- `/Applications/Intatis.app` 已替换为上述 `0.36 (36)` 开发构建，bundle identifier 为
  `com.Vita0818.IntatisMac` 且无 quarantine xattr；旧 `0.35 (35)` 已移入废纸篓作为可恢复备份；
- `IntatisiOS` generic Simulator Debug unsigned build：通过；最终 bundle 为 `0.36 (36)`；
- 本轮没有运行 Developer ID 签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包，因此这只是本机
  开发安装证据，不是正式 release 证据。完整离线图片工具测试仍见紧随其后的专项结果。

2026-08-05 `image_model` / `generate_image` / `edit_image` 配置路由的直接证据：

- `CLIProviderAdapterTests`：4 tests / 0 failures；新增用例验证 image-only provider 的空
  `models` 不影响 Chat selection、`image_model` 精确映射到独立 opaque endpoint/model，以及字段
  缺失时无隐藏 fallback；
- `IntatisProvidersMultimodalTests`：17 tests / 0 failures；覆盖 image provider registry、
  `images/generations` JSON、`images/edits` multipart reference、DALL-E 2 的显式 base64 response、
  `b64_json` decode、非法 URL、provider payload error、timeout/retry 与 no-image-model nil route；
- `IntatisToolsTests`：144 tests / 15 skipped / 0 failures；覆盖 `edit_image` schema/registry、单图
  preflight、输入/输出权限资源分离、无副作用拒绝与宿主 service 注入；
- `IntatisAgentKernelTests`：171 tests / 0 failures；其中 provider image service 用例验证编辑调用使用
  configured image model 而非 Chat model，并把结果写回 workspace；
- `CoworkEndToEndTests`、`MessageDelegationSplitTests`、`ToolRegistryLeaseTests`：合计 28 tests /
  0 failures；覆盖 coordinator/read-write worker 的 `generateMedia` 暴露以及 read-only worker 的
  `edit_image` 抑制；
- `IntatisMac` macOS Debug unsigned build：通过；构建和上述离线测试均不需要 API Key；
- 当前尚未执行真实 provider/credential/network 图片生成或编辑 smoke，因此不声称任何具体线上
  模型、provider 方言、size/count/quality 组合或计费路径已通过。首版编辑只支持单张输入图；mask、
  多参考图和原地覆盖仍未实现。

2026-08-05 Flotis 单模型 recorded-file runtime 迁移后的 composer voice /
`transcription_model` 直接证据：

- `ComposerVoiceInputTests`：6 tests / 0 failures；除空草稿、已有草稿、尾部空白和空转写 no-op
  外，精确验证默认 WAV 为 16-bit little-endian PCM，且 WAV/M4A 设置都不注入
  `AVEncoderBitRateKey`；
- `IntatisProvidersMultimodalTests`：22 tests / 0 failures；覆盖 owner-only disk-backed multipart
  WAV、exact OpenRouter JSON-base64 `input_audio`、25 MiB recorded-file runtime、严格 JSON
  `Content-Type`、timeout/retry 与安全错误 payload；原有 modern/iOS importer focused tests 继续验证
  `transcription_model` 精确保留、transcription-only provider 空 `models`、exact route 与无 hidden
  fallback；
- 完整 `swift test`：退出码 0；真实 provider、credential、browser、Keychain 等显式 opt-in 用例仍
  按各自声明跳过，不将其记为真实环境通过；
- `xcodegen generate` 与 `scripts/check-version-consistency.sh` 通过，后者输出
  `Intatis version is consistent: 0.36 (build 36)`；`IntatisMac` macOS Debug unsigned build 与
  `IntatisiOS` generic Simulator Debug unsigned build 均通过，两端只有既有 deprecated `onChange` /
  unused-result 等 warning；
- 最终 macOS/iOS App bundle 都含 `NSMicrophoneUsageDescription` 与 English/简体中文
  `InfoPlist.strings`。macOS Developer ID target 的说明为“turn voice into editable message drafts”；
  shipping entitlements 另含最小 `com.apple.security.device.audio-input=true`，App Sandbox 仍关闭；
  本地 ad-hoc Debug 签名包的 embedded entitlements 已读回该值且
  `codesign --verify --deep --strict` 通过。ad-hoc 不证明正式 Developer ID/Hardened Runtime 或公证；
  遗留 `IntatisMacAppStore` target 未修改、未构建；
- 当前未启动 App、未授予真实麦克风权限，也未以真实 credential/network 调用线上
  `audio/transcriptions`，因此录音设备、具体 provider 方言、模型可用性、计费与运行态像素仍为
  `UNKNOWN`，需要下一步手动 smoke；本轮未执行签名、公证、staple、Gatekeeper 或发行打包。

2026-08-14 provider streaming reconnect 与 Cowork terminal-Run Retry 最小修复的直接证据：

- `IntatisMac` macOS Debug unsigned build 通过：
  `xcodebuild -quiet -project Intatis.xcodeproj -scheme IntatisMac -configuration Debug
  -destination platform=macOS -derivedDataPath /tmp/IntatisDerivedData-retryfix
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build`，仅有多架构 destination 选择 warning；
- `IntatisProvidersToolCallingTests` 36/36、0 failures；覆盖错误型 SSE 后重连、首次语义输出前重连，
  以及 text/完整 tool call/usage/done 已交付后不盲重放。完整 `IntatisProvidersTests` 为
  203/204：唯一失败是旧断言
  `testOpenAIStreamingDoesNotRetryAfterResponseBytes`，其 fixture 只有尚未组成完整 SSE event 的 raw
  fragment，仍把“收到任意 byte”当成 replay fence，与当前批准的 consumer semantic-yield 合同冲突；
  本轮按仓库修改边界未改测试源码，也未把生产实现退回旧合同；
- `ThreadLayoutTests` 21/21、0 failures；完整 `IntatisSharedUITests` filter 在约 70 秒无输出后
  人工中止（exit 130），不记为通过；
- `git diff --check` 通过。未运行真实 provider/credential/network、网络断线注入、GUI 点击、iOS、
  签名、公证或发行打包 smoke。

2026-08-13 Permission Reviewer plain-text verdict 格式修复的直接证据：

- `PermissionReviewTextVerdictParser` 对 241/500/1000 Character 的非敏感 reason 不因长度改判，仍要求
  非空 plain text 与唯一 final-line ASCII `ALLOW` / `DENY`；system/user prompt 都引用同一份合同；
- 完整长 reason 在任何摘要截断前先经过敏感信息检查，尾部 token fixture 会 fail closed 且不进入
  EventLog；live bound settlement 仍使用固定宿主文案；
- 缺 marker、多个 marker、marker 后有文本、空 reason、JSON/code fence、无 completion marker 与
  非成功 finish reason 分别验证 secret-free typed diagnosis；旧 `malformed_verdict` 与
  `provider_still_stopping` 仍可解码；
- 聚焦命令
  `swift test --disable-automatic-resolution --filter 'IntatisPermissionReviewerTests|PermissionReviewProtocolTests|PermissionReviewControlPlaneTests'`
  通过：`PermissionReviewProtocolTests` 13/13、`IntatisPermissionReviewerTests` 14/14、
  `PermissionReviewControlPlaneTests` 51/51，合计 78/78、0 failures；完成相关 package Debug 编译。
  未运行全量 test、macOS/iOS app build、真实 reviewer provider、credential/network 或 GUI smoke。

2026-08-13 Cowork Session 内独立 WorkTask / Run 中断 / 原子委派重构的直接证据：

- `TaskGoalProtocolTests` 12/12 与 `TaskGoalProjectionTests` 7/7：验证 WorkTask schema/事件不含
  Run、Goal、agent owner，dependency 只在当前 Session graph 内成立，`interrupted` Run 为 terminal；
- `WorkTaskRuntimeTests` 21/21：包含 `testTaskCreateDescriptorIsSessionScopedAndHasNoOwnerField`、
  `testDelegationPreflightFailureWritesNoPartialFacts`、stale revision 与 post-append lost-ack 边界；
- `AgentInvocationNonRecursiveTests` 11/11：验证 `delegate_task` 只接受已 attached worker，省略 target
  只选择现有 idle worker，缺 target/Mediator deny 不留下 message、delegation、lease、queue 或隐式 worker；
- `GoalRuntimeControllerTests` 33/33：验证恢复把悬空 active Run 写成 `interrupted`，显式 Resume 创建
  不同 RunID，且 Run/Goal/invocation terminal 不传播 WorkTask 状态；
- `PerAgentInferenceProfileTests.testAutomaticDelegationDoesNotProposeWorkerWhenNoneIsAttached` 1/1：
  验证 automatic delegation 不再 proposed/spawn worker；
- `IntatisProtocolTests` 107/107、`IntatisConversationTests` 212/212、`IntatisAgentKernelTests`
  220/220、`IntatisCoworkTests` 364/364、`IntatisSkillsTests` 29/29、`IntatisToolsTests`
  227/227（另有 19 个显式 opt-in skip）均通过；Cowork 内另确认 `PerAgentInferenceProfileTests`
  21/21、`OrchestrationReliabilityTests` 44/44、`PermissionReviewControlPlaneTests` +
  `RunControlTests` 58/58；
- `swift build` 与 `git diff --check` 通过。一次整仓 `swift test` 在 Tools/Skills 通过后，于既有
  SharedUI async waiter 中超过 60 秒无输出并人工中止（exit 130），因此不记为完整 suite 通过；
  未运行真实 provider、credential/network、GUI、macOS App 或 iOS App smoke。

2026-08-13 AuthorizationSidecar 绑定域分离与副作用完成 cast 删除的直接证据：

- `AgentLoop` 现在只用 stripped canonical business arguments 自身重算并核对
  `businessArgumentsDigest` / Character count；工具自定义的 `authorizationArgumentIdentity` 继续独立生成
  `ResolvedToolAuthorization.normalizedArgumentsDigest` / count。两组摘要各自闭环验证，不再互相比较；
  `PermissionReviewControlPlaneTests.testCustomAuthorizationIdentityDoesNotConflictWithBusinessArguments`
  与 `AutomaticPermissionReviewTests.testSecretSidecarFailsWhileCustomAuthorizationIdentityRemainsBound`
  覆盖 custom identity 与业务 JSON 摘要明确不同但仍可合法审查、执行的回归；
- 已删除 `SideEffectEvidenceLedger`、其 EventLog restore、全部 denied/failed/succeeded 记账、final 前
  unresolved 检查，以及 `toolExecutionRequiresManualReconciliation` /
  `unresolvedDeniedSideEffects` 两个 AgentLoop error 和对应 model-facing prompt。普通权限拒绝或 executor
  失败仍写 typed `tool_result` 并回到同一模型 turn，但不会再被二次 cast 成“整轮不能完成”；
- hard permission deny、`ToolDenialCircuitBreaker`、durable execution ticket、
  `effectDisposition`、`.doNotReplay` 与旧 attempt crash-replay guard 均保留；这些机制分别约束当前调用能否
  执行或旧 attempt 能否自动重放，不得重新组合成 final-completion gate；
- `AuthorizationSidecarTests` 12/12、`AgentLoopPolicyTests` 37/37、
  `AutomaticPermissionReviewTests` 39/39、`PermissionReviewControlPlaneTests` 52/52、
  `AgentInvocationNonRecursiveTests` 11/11、`PerAgentInferenceProfileTests` 21/21 均通过；
  模块级完整结果为 `IntatisAgentKernelTests` 220/220、`IntatisConversationTests` 212/212、
  `IntatisCoworkTests` 365/365，全部 0 failures；
- `swift build --disable-automatic-resolution` 与 `IntatisMac` macOS Debug unsigned build 通过；Mac 构建只有
  仓内既有 unused-result / deprecated `onChange` warnings。未运行真实 provider、credential/network、
  GUI、iOS App、签名、公证或发行打包 smoke。

2026-08-12 Cowork ordinary-worker WorkTask update 收窄的直接证据：

- `ToolRegistryLeaseTests.testWorkerTaskUpdateSchemaExposesOnlyBoundProgressAndSettlementFields`：
  worker 的 exact property set 为 `task_id/expected_revision/progress_note/status/result/evidence`，
  `additionalProperties=false`，status 只含 `in_progress/blocked/completed/failed`；同一测试同时确认
  manager 的 14 个完整字段与各自 capability grant 均保持不变；
- `WorkTaskRuntimeTests.testMutatingWorkTaskToolsRejectMissingHostManagerAsNotStarted`：worker 窄入口仍
  委托既有宿主执行链，缺失 host-bound manager 时与完整入口一样 fail closed，不伪报成功；
- `IntatisAgentKernelTests.testUnknownToolArgumentsDoNotRequestPermissionOrExecuteTool`：1/1；确认 closed
  schema 的未知字段不会产生 permission request，也不会进入 executor；
- `ToolRegistryLeaseTests` 26/26、`WorkTaskRuntimeTests` 22/22，加上述内核 gate 合计 49/49、
  0 failures；`swift build --disable-automatic-resolution` 通过。未运行全量 test、macOS/iOS app
  build、真实 provider 或 GUI smoke。

2026-08-12 `permission_reviewer_model` 独立控制面 route 的直接证据：

- canonical 顶层字段只接受 `<provider>/<model-id>` 的已配置 inference base profile；字段缺失只继承
  同一 JSON 文档的顶层 `model`，而显式空值、错误类型、未知/禁用 provider、未知 model 与 unresolved
  env/file reference、缺失/未知 top-level compatibility source，以及已选 Mac 配置整体损坏/不可读都
  让 reviewer fail closed。Mac 当前选择、UserDefaults、Cowork session default、
  `INTATIS_MODEL`、live/historical `@main` 与 main rebind 均不是 reviewer fallback；没有新增 UI 或
  session/EventLog schema；
- `AutomaticPermissionReviewTests`：39/39，覆盖独立 main/reviewer exact binding 的原子七事件落盘、
  reviewer tuple missing/mismatch、reviewer catalog TOCTOU 零事件失败，以及既有 reviewer lifecycle；
- `PerAgentInferenceProfileTests`：21/21；`CLIProviderAdapterTests`：13/13，覆盖 JSON-model compatibility、
  环境变量只改变 main 而 reviewer 不漂移、显式非法 reviewer fail closed、缺失 reviewer 时不能从缺失/未知
  JSON default 发明 route、独立 profile lowering 与 main rebind 后 reviewer durable binding 不变；
- `IntatisCLITests`：49 tests / 0 failures / 8 个显式 opt-in real-provider smoke skipped；未发送真实网络
  请求或产生计费；
- `swift build --disable-automatic-resolution` 与 `IntatisMac` macOS Debug unsigned build 通过；只有仓内
  既有 unused-result / deprecated `onChange` warning。Mac App 无独立 XCTest target，因此 Mac config
  presence/normalization/writer 与 runtime freeze 还通过源码审计和完整 target 编译验证，不能冒充真实
  GUI/provider smoke；
- 未读取或修改用户的真实 provider/auth 配置，未运行真实 permission-review provider matrix；模型的
  实际 plain-text verdict 稳定性仍需用用户配置的 reviewer route 做手动 smoke。

2026-08-05 Cowork coordinator 主动推进与外部目录恢复提示词的直接证据：

- `ContextProjectionTests`：22 tests / 0 failures；验证 coordinator 会先建立 execution objective、
  检查 bounded Skill catalog、只在用户明确要求持续/跨 run 目标时创建 durable Goal、为非简单工作
  建立最小 WorkTask 图、尽早委派有收益的分支并继续自己的关键路径，同时保留最小 team/lease；也验证
  coordinator 在工具真实可用时
  停止根外直接重试，使用 exact-directory `spawn_agent`、默认 `read_only`、按需
  `read_write`、随后 `delegate_task`，工具/扩展失败则报告 blocker；同一用例验证 worker 与
  Code 默认提示词不宣称 `spawn_agent`；
- `ToolRegistryLeaseTests`：16 tests / 0 failures；验证 Orchestrator 按 coordinator task lease
  生成的真实 provider request 同时含主动推进规则、`spawn_agent` 工具与上述恢复规则，worker lease
  边界不变；
- `IntatisSkillsTests`：29 tests / 0 failures；验证产品内置 `cowork-agent-orchestration` Skill 包含主动
  执行循环，同时继续保留 capability hard gate、最小团队与 exact profile 路由约束；
- `intatis-skill-creator/scripts/quick_validate.py`：`Skill is valid`；目录名/frontmatter、结构、文本安全
  与资源引用校验通过；
- `IntatisAgentKernelTests`：170 tests / 0 failures；`IntatisCoworkTests`：320 tests / 0 failures；
- SwiftPM 测试过程完成受影响源码/CLI package 的 Debug 编译。本次未改 App/UI、协议、权限实现或
  Xcode 工程，未另跑 macOS/iOS app build；也未执行真实模型的外部目录行为 smoke，因此这里只
  证明稳定提示词、工具表面与 lease 集成，不把任一模型一定遵循提示词写成确定性保证。

2026-08-05 Chat 托管搜索路由修订的直接证据：

- `IntatisProvidersTests`：171 tests / 0 failures；覆盖 exact route capability、OpenAI/OpenRouter
  request shape、strict routing options、legacy search route ignore、静默普通 Chat、窄化的同路由
  fallback、partial-response replay guard、两类 citation annotation，以及无效 legacy 搜索字段不
  阻止 Chat/有效 legacy 搜索字段不污染可见模型列表；
- `IntatisConversationTests`：173 tests / 0 failures；
- `IntatisCLITests`：28 tests / 2 opt-in real-provider tests skipped / 0 failures；
- `IntatisSharedUITests`：133 tests / 0 failures；
- `IntatisMac` macOS Debug unsigned build：通过；`IntatisiOS` generic Simulator Debug unsigned
  build：通过。iOS 首次独立依赖解析遇到 GitHub proxy 503，复用已成功解析并缓存的同一
  working-tree dependencies 后构建通过，该网络失败不计为源码失败；
- 未执行真实 provider/credential/network smoke，因此这里只证明离线 wire fixture、planner、
  integration 与两端编译，不声称任何具体厂商当前线上 endpoint 已通过。

2026-08-03 版本校准后的直接证据：

- `xcodegen generate`：通过；
- `scripts/check-version-consistency.sh`：通过，输出 `0.32 (build 32)`；
- `IntatisMac` unsigned universal Release：通过；最终 bundle 为 `0.32 (32)`，可执行文件为
  `x86_64 arm64`。这是代码与元数据验收，不是签名发行产物；
- `IntatisiOS` generic Simulator Debug：通过；最终 bundle 为 `0.32 (32)`；
- 两端构建有既有的 unused-result 与 deprecated `onChange` 警告，无构建错误；
- `swift build`：在允许 Swift/Clang 写入用户缓存的宿主环境通过；受限沙箱内首次尝试因
  module cache 无写权限而未进入源码编译，不计为产品失败；
- release script `zsh -n`：通过；无证书 preflight 按预期在任何正式输出前失败；
- 临时非发行探针：App runtime signing command、XML entitlements、UDZO DMG、DMG signing
  command 和 strict codesign 通过，临时目录已删除；
- `IntatisToolsTests`（外层 sandbox 外）：141 tests / 15 skipped / 0 failures；
- `testSharedSoftTokenBudgetReservesBeforeDispatchAndReportsProviderOverrun` 原始 fixture 已先
  稳定复现为 `requestTooLarge(limit: 800, estimatedInput: 889)`，证明生产 pre-dispatch
  保护正常；测试随后改为使用有充足 prompt 余量的命名预算常量，继续精确验证 provider
  忽略 output ceiling 后超支 1 token 的 soft-budget 语义；
- 修正后的 focused 用例：1 test / 0 failures；`IntatisAgentKernelTests`：169 tests /
  0 failures；
- 完整 `swift test`：通过。真实 browser/Git/provider/credential/network 等显式 opt-in
  用例仍按设计 skipped，不计为已执行的真实环境验证；
- Cowork agent-thread Computer Use：8 × 1,000 rows + 500 delta/s 下，1,000 rapid switches 与
  180 秒 soak（1,486 timed switches）均通过，0 warning / 0 incident；结束后 14 个
  `NSTextViewSharedData`、173 个 `GestureNode`，`vmmap` 62.1 MiB physical / 74.8 MiB peak，
  `ps` RSS 约 156.6 MiB；
- 2026-08-04 historical-roster 增量：`CoworkProjectionRegressionTests` 8/8、
  `CoworkAgentThreadPresentationModelTests` 10/10、`CoworkInferencePresentationTests` 6/6、
  `IntatisConversationTests` 172/172；Computer Use 实测 detach 当前 agent 后保持选择、离开再返回
  仍可读，并在 500 delta/s 下追加完成 1,000 rapid switches，0 warning / 0 incident、16 rows。
  当前 Codex managed sandbox 的完整 suite 只因 `IntatisToolsTests` process/Seatbelt/loopback 限制
  失败；一次完整 `IntatisSharedUITests` target 在 build 后无测试输出并被中止，相关定向用例已独立
  通过；
- 2026-08-04 rail lighting/fixed-geometry 增量：
  `ThreadLayoutTests|CoworkInferencePresentationTests|CoworkAgentThreadPresentationModelTests`
  30/30；IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug unsigned build 通过。
  原生 Light fixture 在同一 1372×768 viewport 中切换 `@main` / `@research`，composer 水平像素
  run 完全一致，rail 两态均为 x=1076…1365；旧 `.regular` glass card 的一次性 QA sample
  为 240/255，新系统 `Glass.clear` sample 为 244/255。该数值只用于同机同窗对照，不是颜色 token。
  8×1,000 rows + 500 delta/s 下再次完成 1,000 rapid switches，0 warning / 0 incident、≤16 rows。
  本次未重跑 180 秒 soak、Dark、Reduce Transparency、Increase Contrast、VoiceOver 或完整
  SwiftPM suite；不得从该 Light fixture 外推这些矩阵。
- 2026-08-04 rail window-stability 第一版的 31/31 与截图数据只保留为历史记录；用户随后仍稳定
  复现跳动，真实 Test session 也记录到 viewport preference 同帧重复更新，因此该结论已作废。
- 第二版 corrective pass（删除 GeometryReader/PreferenceKey 坐标链、改用
  `onScrollVisibilityChange`、拆除 shared glass container）的 85/85、360-cycle host 与当时的 AX/
  视觉结论已经被用户在新构建中的稳定复现推翻，不得继续当作 rail 不跳动的通过证据。当前第三版
  必须额外验证：outer-detail canvas 而非 `threadColumn` 直接拥有 trailing rail；selection 不在 rail
  render snapshot；蓝色 selection child 可独立更新；`Glass.clear` backdrop 是 content-independent
  Equatable view；transaction 同时关闭 animation 与 disablesAnimations。当前
  `ThreadLayoutTests|CoworkInferencePresentationTests|CoworkAgentThreadPresentationModelTests`
  31/31 通过，production-shaped host 包含 360 次交错 selection/mode/inspector/window-size 循环；
  IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug unsigned build 通过。按用户要求不使用
  Computer Use 或截图差分，因此最终几像素光学稳定性保留为用户新构建手动验收项，不能由自动化外推。
- 用户普通终端的 `security find-identity -v -p codesigning` 已报告两个有效 identity，发行
  脚本也已进入真实 Developer ID 签名和 App 上传；Codex 托管沙箱无法读取登录 Keychain，
  因而在沙箱内仍返回 `0 valid identities found`，不能覆盖宿主证据。两次 App submission
  已被 Apple 接收但查询时均为 `In Progress`；尚无 Accepted、staple 或 Gatekeeper 证据。

## Release GO 条件

只有以下条件同时满足才能写 release GO：

- 当前 working tree 相关 tests/builds 通过，已知失败有明确处置；
- 最终 App/ZIP/DMG 元数据为 `0.55 (55)`；
- Developer ID、notarization、staple、codesign、Gatekeeper 全部通过；
- NOTICE/ThirdPartyNotices 和最终 bundle resource/link inventory 一致；
- 关键真实环境矩阵完成，未完成项以明确的风险接受记录处理。
