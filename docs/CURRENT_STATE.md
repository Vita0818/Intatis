# CURRENT_STATE

文档状态：当前源码摘要
最近核对：2026-08-13
产品基线：v0.48（build 48）

## 版本与发行状态

- `HEAD` 与 `origin/main` 当前均为标题为 `v0.47` 的提交 `53f3320`。仓库没有 Git tag；该
  commit 标题不是产品版本事实源，`project.yml` 把当前产品基线定义为 `0.48 (48)`。
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 已推进为 `0.48 (48)`。两个仓库参考
  Info.plist、README、文档入口和发行脚本使用同一基线。
- 2026-08-11 已重新生成 Xcode 工程并通过 v0.48 版本一致性门；`IntatisMac` unsigned
  universal Release 与 `IntatisiOS` generic Simulator Debug 均构建通过，最终 bundle 均为
  `0.48 (48)`，macOS 可执行文件包含 `x86_64 arm64`。
- 本机 `/Applications/Intatis.app` 已安装上述当前工作树的 `0.48 (48)` ad-hoc Hardened
  Runtime 开发构建；bundle identifier 为 `com.Vita0818.IntatisMac`，严格 codesign 校验通过，
  embedded entitlements 为 audio input=true、JIT=false 且 library validation 未关闭；安装副本与
  已验证 staging 副本的可执行文件 SHA-256 一致，且无 quarantine xattr。安装前的
  `0.40 (40)` 已移至 `~/.Trash/Intatis-before-install-20260811-201644.app` 作为可恢复备份。该本机安装不是
  Developer ID 公证发行产物。
- macOS 只发行 `IntatisMac` Developer ID/direct-distribution 产品；不做 Mac App Store。
  `IntatisMacAppStore` 仍是 legacy source target，不进入默认构建、测试或 release gate。
- 用户宿主终端已报告两个有效 codesigning identity，其中 Developer ID Application 可被发行
  脚本选取；`Intatis-Notary` Keychain profile 也已配置。v0.48 最终 App/DMG 尚未完成 Apple
  notarization、staple 与 Gatekeeper 全链路，因此仍不得描述为正式 release。

## 当前产品面

### macOS

macOS 是完整产品：Chat、Code、Cowork、Settings 和本地诊断导出。

- Chat 使用无 Intatis Tools 的 `ChatLoop`，支持 OpenAI-compatible streaming、provider/model/
  variant 配置、provider-hosted search wire、citations、会话历史和本地图片附件。macOS Chat 已移除
  composer 中独立的“按提示词生成图片”入口，改为直接复用 Cowork 的 paperclip、系统文件选择器、
  多文件拖放和草稿附件菜单；旧 `artifact_added` / `artifact_progress` 仍可回放，不改历史协议。
  附件先进入 session `ArtifactStore` 并读回校验，`user_message` 只保存 `ArtifactID`；当前轮及后续
  历史重建时再解析为 provider `ImageAttachment`，不会把 base64 图片写入 EventLog。
  每次 Send 只按当前 exact route 的显式 capability 与 adapter dialect 可选地提供 hosted search；
  不支持、未知或未适配时在同一路由静默发送普通 Chat。
- macOS/iOS Chat 在成功回合落盘后可启动独立、无工具、无 web search 的隐藏标题请求，复用该
  回合冻结的 exact provider/model 与 `turn_outcome(completed)` seq 水位；后台重放只能读取该水位
  及以前的 EventLog，后续由其他 route 完成的内容不会泄入旧标题请求。它从该冻结前缀中只读取
  session 起点可证明串行的最早三个
  completed Chat 回合，不写入消息历史、turn stats 或 busy/Stop 状态；每进程、每 session 最多
  三个逻辑 generation，前两次可精确返回 `NO_TITLE`，第三次必须给出标题。输出通过严格 stream、
  长度、格式、路径/长标识与敏感内容验收后，才在跨进程锁内执行 Chat-only set-if-absent rename。
  手工 Rename 永远优先，自动命名不改变 recent-session 排序；生成、验收或 EventLog append 前的
  失败、取消、超时与旧/歧义历史均静默保留默认名称。若 rename 已 append、仅 projection/通知失败，
  EventLog 中标题已是 canonical truth，UI 可在刷新或重启后恢复。Code/Cowork 仍只使用既有显式
  Rename/`rename_session` 路径。
- Code 使用共享 headless `AgentRuntime.code`，提供工作区文件、patch、Git、managed
  terminal、Skills、外部 MCP、文档/媒体、浏览器，以及与浏览器独立的 provider-hosted search
  工具。工具可见性、lease、权限和 durable execution ticket 在执行前逐层核对。
- Code/Cowork/CLI 的普通文档读取已按格式拆成 `read_pdf`、`read_docx`、`read_pptx`、
  `read_xlsx`、`read_html`、`read_epub`，另保留职责独立的 `document_ocr`、
  `document_render`、`document_export_pdf`、`document_write`。聚合 `document_read` 已从
  live registry 下架；旧 session 的同名 capability 只作为兼容授权映射到五个固定格式 reader，
  不会重新暴露旧工具。旧
  `read_document` 自动 fallback、`edit_pdf_pages` 与 `reconstruct_document_image` 已从生产
  registry/fresh lease 下架；PDF P0 仅原生文本/metadata 读取、显式 OCR、页面 PNG 和新生成
  PDF 校验，不提供任何 PDF mutation。写入使用 source/destination snapshot、owner-only staging、
  CAS、格式语义验证与 file/directory 原子提交；模型不能选择 executable/backend/command/env 或
  fallback。五个非 PDF reader 只接受 `path` 与可选 `maxCharacters`，由宿主固定 exact 格式，
  并把 Docling 高层转换得到的 Markdown 整体做字符预算后返回；旧的 DOCX/PPTX/XLSX/HTML
  手写对象遍历与 native-structure 投影已删除。写入仍由
  python-docx/python-pptx/openpyxl/lxml 的明确 operation 子集负责，XLSX 在 openpyxl staging 后经固定 safe-profile LibreOffice Calc XLSX round-trip/save、formula + data-only
  cache postcondition 与 PDF preview 验证；不能只凭转换退出码声称已重算。EPUB 普通读取走固定
  Docling 高层转换；写入绑定仓内可重复构建的 pinned rbook helper source 和正式 EPUBCheck。
  rbook helper 的旧 read route 已删除。EPUB render/export 在 full-spine corpus gate 通过前不进入 model schema，并返回
  `unsupported_operation`。文档辅助资产会先冻结 digest/identity，backend 运行与提交锁内再次核对；
  staged commit 固定目标父目录 identity，生成物同时受单文件、总字节与 entry 数预算约束。当前开发机
  用户 runtime 已安装固定 Python Office/HTML/Docling 组件、Docling layout model、Tesseract、
  `intatis-rbook-helper`、pdfcpu 0.13.0、正式 EPUBCheck 5.3.0，以及版本化的官方
  LibreOfficeDev 26.8.0.0.beta1；固定后端只解析
  `~/Library/Application Support/Intatis/document-runtime/libreoffice/26.8.0.0.beta1/LibreOffice.app`，
  不再使用 `/Applications` 中的用户副本。该 App 来自 Document Foundation 官方
  298,129,546-byte Apple Silicon DMG，SHA-256
  `a56a5af102c78c294b3da48154958ecd9fa52d357589305c54e6e215ce611900`；`hdiutil verify`、官方
  detached PGP signature、宿主 `codesign --verify --deep --strict` 与 Gatekeeper 均通过，签名者为
  The Document Foundation Developer ID（Team ID `7P5S3ZLCN7`），Gatekeeper 判定为
  `Notarized Developer ID`。一次无 Intatis Seatbelt 的诊断调用曾让内置 Python 重写 App 内已签名
  `__pycache__`，造成随后真实 sealed-resource failure；该副本已移入废纸篓并从只读官方 DMG 重装。
  重装后的干净副本在完整 Intatis smoke 前后均通过相同签名/公证复验。

  macOS fixed runner 现在为每次 LibreOffice 调用创建当前用户、`0700`、短路径的
  `/private/tmp/intatis-lo-<12 hex>` 目录，并以 LibreOffice bootstrap 参数
  `-env:OSL_SOCKET_PATH=...` 传入。Seatbelt 只给该目录文件读写和匹配 `OSL_PIPE_*` 的本地 Unix
  socket bind/connect；IP 网络及其他 Unix socket 继续默认拒绝，调用结束后删除该目录。这个短路径
  同时避免 `sockaddr_un.sun_path` 超限；把 `OSL_SOCKET_PATH` 仅作为普通进程环境变量或放在长
  Darwin temp path 都不能满足 LibreOffice bootstrap/长度合同。真实 core smoke 已在同一 Seatbelt
  下跑通 DOCX write/read/preview/export/PDF read/render、PPTX write/read/preview/export/PDF read，
  以及 XLSX write、Calc round-trip、公式文本与 data-only cache `4`、preview/export；不会自动降级。
  五个格式 reader 的真实 runtime smoke 均已通过；另以用户提供的外部 Intatis-test corpus 中
  一份稀疏 XLSX 与三份 PPTX 运行只读复制后的回归，
  4/4 通过，稀疏表不再进入 openpyxl `EmptyCell` 手写投影。结构化普通读取 intent 仍经进程权限
  审查，但标记为 `safeToReplay`；解析失败会 durable settle 为 failed/unknown、返回模型并继续同批
  后续文件，不再触发虚假的 manual reconciliation。当前 `maxCharacters` 只约束最终返回给模型的
  Markdown；Docling 仍会先完成整份文档转换与 Markdown 导出。生产 runner 已有输入文件/归档展开
  上限、超时、取消与进程清理，但尚无独立 RSS 内存上限，因此超大或极端复杂文档仍是明确的资源
  边界，不能把字符裁切误写成峰值内存保证。旧 26.2.4 runtime 已按用户授权移入废纸篓。生产 runner 的 EPUB write/EPUBCheck 和 strict
  pdfcpu + Docling/Tesseract OCR smoke 也已分别通过。runtime 打包、双架构和其余发行许可闭包仍是
  独立工作。read-only Cowork worker 获得 in-process
  `read_pdf`、五个固定格式 reader 以及无持久写入的 `document_ocr`；render/export/write 只向
  read-write worker/coordinator 显式签发。iOS Chat 不链接任何文档 runtime。
- Code/Cowork/CLI 的 `generate_image` 与 `edit_image` 已接入 macOS/CLI 高级配置顶层
  `image_model`。主 agent 根据用户意图决定是否调用普通工具；model-facing schema 不接受
  provider/model，宿主统一从配置解析。缺少 `image_model` 时明确返回未配置，不再使用隐藏的
  `dall-e-3` fallback。专用图片 provider 可以不声明任何推理模型，因而不会进入 Chat/Code/
  Cowork 模型菜单。`generate_image` 调用 OpenAI-compatible `images/generations`；`edit_image`
  接受工作区内单张 PNG/JPEG/WebP（最多 50 MiB）、prompt 与不同的 PNG 输出路径，经同一权限、
  WorkspaceLease、`PathConfinement` 和 durable tool execution 链调用 multipart `images/edits`，
  两者均只接受 `data[].b64_json` 输出。mask、多参考图与原地覆盖尚未支持。
- Code 与 Cowork 的 Agent 图片输入已改为 durable active-history 链路。macOS共享composer reader对
  `.png`/`.jpg`/`.jpeg`使用确定性canonical MIME映射（其他格式才查询系统type database），GUI/CLI
  再把用户图片写入 exact-session `ArtifactStore`；`AgentLoop.send`拒绝调用方直接传入provider-ready
  `images`/data URL，stable与ordinary task-scoped current都只能从accepted attachment IDs经共享resolver
  有界读取并验证PNG/JPEG、MIME、完整解码、尺寸/像素、byte count与SHA-256。stable路径再把无
  base64/path的v2 descriptor写入model history。Code stable conversation与Cowork exact `@main`支持
  current/next/restart；ordinary task-scoped agent只承诺current，CLI Code只承诺同进程next。
  图片capability只在exact request adapter为`.openAI`且model声明`.visionInput`时打开；user/FCO两个
  flag独立检查，compatible/legacy/OpenRouter/unknown route默认false，tool-search gate与图片gate分离。
  MCP structured-result图片会以原`callID`进入多模态function output，live与restart replay使用同一
  canonical binding；stable媒体completion batch还要求同turn/call的唯一`tool_result`与同
  `{callID, agent, taskID, attempt}`的唯一settlement，Code首轮工具票据复用model-history规范化的attempt 1。
  unsupported route、缺失/损坏blob或descriptor不一致均在下一次provider请求前typed fail closed。
  automatic Cowork 不再因授权快照含 user/FCO 图片而 blanket deny；主模型可把与 exact action 相关的
  图片/PDF证据压缩进 same-call sidecar，reviewer 不会因此收到完整像素或整份文档。上下文压缩的
  summarizer会看见完整active window中的用户/工具图片；checkpoint成功后所有旧原图只由摘要接替，
  replacement不保留attachment/ref，但ArtifactStore blob与审计事实不删除。
- Cowork显式Retry由纯`SubmittedIntentRetryPlanner`按canonical task状态决定：outbox canonicalization
  继续保持attempt 1；restored queued exact task不递增attempt或改写queued事件，restored running已经由
  Orchestrator durable requeue到下一attempt时只对齐该exact attempt；只有failed/cancelled whole-task
  execution retry才递增，created/assigned/running或不一致状态fail closed。所有分支都复用同一
  SubmissionID、冻结payload/附件IDs与root task，不重复user event。
- macOS Chat/Code/Cowork 与 iOS Chat 的 composer 已在 Send/Stop 左侧接入同一个语音输入按钮。
  第一次点击开始录音，第二次点击停止并通过顶层 canonical `transcription_model` 指定的 exact
  provider/model 调用 `audio/transcriptions`；转写结果追加到完成时仍然可编辑的当前草稿，不自动
  发送。单模型 recorded-file runtime 已按 Flotis 当前实现迁入：默认 WAV/16 kHz/mono，录音 generation、
  stale-file 清理、stop/file-size 校验、取消/cleanup 与 disk-backed upload body 均保留；不再强制设置
  AAC bitrate。compatible adapter 使用 multipart，exact OpenRouter adapter 使用 JSON-base64
  `input_audio`。字段缺失或 adapter 不受支持时明确失败，不使用当前 Chat 模型或固定模型 fallback。
  专用 transcription provider 可为空 `models`，不会进入推理模型菜单；没有新增设置页或第二套模型
  配置。录音只使用 owner-only、有时长/大小边界且必清理的临时文件，Send 前不进入 EventLog 或
  ArtifactStore。Flotis 的多模型对比、全局快捷键、review/clipboard 与输入法未迁入。macOS shipping
  target 同时保留 TCC usage description 与 Hardened Runtime 最小 audio-input entitlement；App
  Sandbox 和遗留 App Store target 均未改变。
- Cowork 使用 `Orchestrator`、FIFO scheduler、MessageBus/Mediator、WorkTask/Goal、
  per-agent exact inference binding、独立 permission reviewer 与 goal verifier 控制面。
  AgentLoop 不同步递归调用另一个 AgentLoop。右侧 Agents 区域中的 ordinary agent 可作为
  当前窗口的只读对话选择；列表保留 session 历史上所有 durable agent，detached identity 继续
  可点击并由原状态图标显示已移除，当前选择不会跳回 `@main`。新窗口默认显示 `@main`，
  `@permission-reviewer` 等控制面 identity 仍为不可选择的状态项。
- macOS/CLI 高级配置已接入 canonical 顶层 `permission_reviewer_model`，只接受已配置的
  `<provider>/<model-id>` base profile；没有新增 UI。字段缺失时仅在配置解析层一次性继承同一 JSON
  文档的顶层 `model`；兼容来源缺失/未知、显式空值、错误类型、未知/不可解析 route 或整份已选配置
  损坏/不可读均 fail closed，不会回退 UI
  selection、Cowork session default、live/historical `@main` 或后续 rebind。fresh 七事件 bootstrap 与
  restore/re-enable 都使用独立冻结的 reviewer exact binding；每个审查 generation 仍从该 binding
  fresh-resolve provider wrapper。GoalVerifier 继续冻结首个可解析的 exact `@main` binding，与 reviewer
  配置互不替代；未增加 session/EventLog schema 字段。
- Cowork automatic 权限请求使用 single-pass same-call sidecar。request-owned provider-facing business schema
  增加 required string `__intatis_authorization_context`；对 `strict:true` function，装饰后的 `required` 必须覆盖
  全部 `properties`，同时保留 `additionalProperties:false`；装饰器递归验证 strict object，并在发网前
  typed fail closed。`tool_search` 本身不改，但其 provider-bound `tool_search_output` 内延迟发现的 function/
  namespace 子工具同样装饰，durable output 保留原始 schema。原 `ToolDescriptor`、registry/business required 与
  executor schema 不变；宿主仅在 deterministic gate 实际进入 automatic ask 时消费并验证该字段，
  deterministic allow/deny 忽略它。acting model 在原业务 function call 中用这一句话概括为什么 exact action 服务当前任务，
  不再二次调用 acting provider，也不复制 `request.messages`、完整 PDF/tool output 或全量图片。宿主在任何
  原业务 schema 校验、durable model history、EventLog 或 executor 之前拆除 sidecar，只用 canonical
  business arguments 计算 intent/path/network/action preview/authorization identity。valid sidecar 只在当前
  turn 的 acting-model 内存 conversation 中保留，作为下一次 function call 的正确格式示例；durable history
  仍只保存 stripped business call。automatic ask 的 reviewer 收到完整 canonical safe business arguments、
  完整 same-generation sidecar，以及 request/task/call/tool、ResolvedToolAuthorization、gate、lease、intent
  等机械宿主事实。live prompt 明确不发送 TaskContract objective/role/deliverable、causal userGoal、用户消息、
  assistant/history、PDF 或图片原文。raw sidecar 与 reviewer transient exact-args 副本均不落 EventLog 或
  permission lifecycle；`permission_request.context` 只保存 generation/snapshot/digest/status receipt。
  missing/malformed/secret-bearing sidecar 是 acting-model tool-input failure：只追加 failed/runtimeFailed
  `tool_result`，不创建 `permission_request` / `permission_resolved`、不调用 reviewer，也不消耗 permission
  denial fuse；同一 business args 后续补正仍能进入 reviewer。side-effect evidence 只在当前 turn 内阻止模型
  把未执行动作说成完成，restart 不恢复一条从未发生的权限拒绝。sidecar 与 exact call/generation/business
  digest 无法绑定时则单独 typed fail closed。manual/nonautomatic flow 不接收 transient input，若模型仍发送
  保留字段则在 business execution 前以 redacted audit + `authorization_context_mode_mismatch` 拒绝。图片存在
  本身不再 blanket deny。最终 reviewer 仍无工具，只接受非空 plain-text reason +
  末个非空行唯一 exact ASCII `ALLOW` / `DENY`。共享 prompt 建议 reason 约 240 Character，但 parser 不再
  因超长单独拒绝；宿主先扫描完整 reason 的敏感信息，再有界化任何需要交付的摘要。旧 JSON/code fence、
  缺失/重复/非末行 marker、空 reason、tool call、无 completion marker、非成功 finish、
  timeout/provider/cancel/persistence failure 均以 secret-free 细分类型 fail closed，risk 始终来自 host gate。live bound review 的
  model-authored reason 与 provider diagnostic 可能复述 transient input，因此 durable settlement/tool-result
  只使用固定宿主文案。automatic responder 缺 bound-invocation overload、cached/active duplicate 缺失或更换
  transient invocation、recovered automatic allow 再交付，以及 Cowork 误配 in-engine reviewer 均 fail closed。
  唯一没有 acting-model invocation 的 automatic `agent.attach` 只能由 `Orchestrator` 通过 dedicated host-admission
  entry 提交，并复核 exact task/tool/authorization/workspace identity 与先行 durable attach/lease events。
  acting model 仍可把相同文字作为普通 assistant 文本输出并按既有消息规则持久化，malformed acting-provider
  error preview 仍依赖通用 bounded/secret sanitizer。live 也没有固定 sidecar byte ceiling 或
  `review_input_too_large` admission；未来只能从真实 route budget 推导整份拒绝上限。真实 provider sidecar
  smoke 尚未运行。
- Cowork final turn 现在先校验 side-effect evidence，再原子发布 final message/model-history、idle
  与 completed outcome；旧日志中 failed/interrupted turn 的先行完成气泡会被展示投影纠正，失效的
  final assistant 也不再进入下一次 provider history。exact `@main` root 另可见模型主动调用的
  `finish_run` / `stop_run`：参数只有有界 reason，session/run/Goal/submission/root TaskID 全由宿主绑定；
  close installation 先形成 actor-local admission/authorization tombstone，EventLog 对每个 RunID 安装
  first-write durable claim 后才等待既有 admission 并 drain 同 run 的其余 task/message，恢复也先兑现该
  fence。普通自然语言 final 不伪造显式 claim；root failure/timeout、用户取消与 session shutdown 分别
  保留 runtime/user/hostLifecycle source，并在 provider/tool cleanup 前关闭精确 run。
- mailbox wake contract 冻结 1–8 个 exact MessageID，并按 ordinary message、information request、
  information reply receipt 与 delegation request 分配不同窄 authority。ordinary message 是 one-way、
  无通信工具；information request 只允许对 frozen RequestID 做一次 `reply_message(inReplyTo:)`；
  reply receipt 不允许 ACK，但允许在确有新问题时用 `request_information(based_on:)` 建立 fresh
  RequestID，并保留同一 conversation root。这样 `information_replied` 只终结一个 correlation，
  不终结长期协作。失败只在同一 TaskID 上有界重试；task completion、candidate progress 与 consumed
  IDs 同批落盘后才 ack。legacy nil binding 的歧义或耗尽 lineage 保持 pending/fail closed，新消息仍
  可独立投递。WorkTask 工具的 reviewer preview 已补齐 bounded semantic fields，并明确 `wt_…`、
  AgentInvocation `task_…` 与 latest revision 的边界。普通 worker 的同名 `task_update` 现由
  `update_bound_work_task` capability 投影为窄业务 schema，只提供 `task_id`、
  `expected_revision`、`progress_note`、允许的 `status`、`result` 与 `evidence`；manager 的完整
  状态、DAG、priority、retry/cancel 更新面保持不变。worker 未知/管理字段由 closed schema
  在授权与执行前拒绝，宿主仍继续核对当前 invocation binding、revision 与真实状态转换；automatic
  模式既有的 request-owned authorization sidecar 装饰不变，不属于 WorkTask 业务字段。
- Cowork 中每个 agent 的文件、Git、文档、浏览器文件与 terminal 工具仍只作用于自己的单一
  `workspaceRoot`。具有 `spawn_agent` 的 coordinator 提示词会在预知目标位于根外或收到
  out-of-workspace denial 后停止直接重试，改为按目标绝对目录创建默认只读的子 agent，再用
  `delegate_task` 交付目录内工作；确需修改时才请求 `read_write`。工具不可用或扩展被拒时只报告
  所需目录/访问级别的 blocker，不伪称完成；Code 与普通 worker 不宣称该恢复能力。
- Cowork coordinator 的固定提示词以主动执行为默认：每轮先建立 execution objective、交付物、约束
  与验证方式，检查 catalog 并激活/读取明确相关的 exact Skills；非简单任务维护最小 WorkTask DAG，
  在开始时识别适合并行、专业复核、多模态或独立 workspace 的分支并在收益成立时尽早委派，child
  运行期间继续自己的关键路径，最终验证报告、结算 WorkTask 并持续推进到验证完成或真实 blocker。
  该行为不自动创建 durable Goal，也不改变最小团队、工具、lease、权限或 worker 能力边界。
- Settings 已收敛为渐进披露结构，保留 provider、模型、MCP、renderer、声明、配置和本地
  诊断 ZIP。诊断包尝试采集系统/App/session 诊断源，但排除原始会话、工具参数/结果、
  endpoint、credential、workspace、artifact、browser profile 与 bookmark；不远程上传。

### iOS

iOS 是结构性 Chat 子集，只链接 Core、Protocol、Providers、Conversation、Artifacts、
Multimodal 与 SharedUI。它支持 provider 配置导入、Chat/history、当前托管搜索 wire、
citations、Chat 自动命名、图片生成、输入栏语音转写和当前系统原生界面，但不链接 Tools、
Permission、AgentKernel、Cowork、MCP 或本地 workspace/shell。其 Chat 与 macOS 共用同一个
exact-route hosted-search planner；自动标题通过 exact-session metadata relay 更新对应 header/row，
切换到其他 session 不会把迟到标题写到当前会话。

### CLI

Swift-native `intatis` 提供 Chat/Code/Cowork REPL、managed execution、Skills、per-agent
profiles 与外部 MCP client。macOS/Linux 的 stdio、sandbox、bwrap/guard 和 PTY 能力按
实际 host 支持情况 fail closed。

## OKF / RAG knowledge bundle 当前状态

- 仓库已固定 Open Knowledge Format v0.2 的 `SPEC.md` / `LICENSE.md` / SHA-256 inventory，
  并新增非 iOS `IntatisKnowledge` product。该模块实现 Intatis OKF RAG Profile 0.1、九份冻结
  JSON Schema、bounded Yams OKF reader、deterministic Validator、validation receipt、
  `KnowledgeBundleBuildService`、immutable multi-version store、embedding/dense/BM25/RRF/reranker
  runtime contracts、mount registry、source-locator replay 和 `search_knowledge`。
- 高级 JSON/JSONC 配置现有 canonical `embedding_model` 与 `reranker_model` 两个独立 role；Mac、
  CLI 和共享 provider catalog 将它们解析为与 Chat/Agent route 无关的 exact binding。两者任一缺失
  时 Code/Cowork 不广告 Knowledge tools，并在现有状态面明确提示配置；不会退回当前聊天模型、
  Apple NaturalLanguage 或 embedding-cosine seam。首发 native adapter 为 OpenAI-compatible /
  OpenRouter embeddings 与显式 `intatis:siliconflow-v1` / `intatis:cohere-v2` / OpenRouter rerank
  dialect，credential 只在
  真实网络 dispatch 时解析。Mac/CLI 在广告工具或显示 `knowledge ready` 前，复用真实 provider
  构造器的同步 route 预检；缺 endpoint、维度或合规 adapter 时工具保持缺席且显示具体配置错误，
  预检不解析 credential、不联网、不取得目录 authority。adapter 现在还会校验并返回 provider 报告的
  token 与 billable units。Knowledge role 的 model-level adapter/options 会保留到 exact route，但同一
  provider 下的 embedding/reranker model 不会进入 Mac/CLI 普通 inference profile 或模型菜单；
  opt-in smoke/quality harness 可按 exact route 汇总这些原始计数，但不根据可变价目表臆算金额。
- Code、Cowork exact `@main` 与 macOS CLI 已通过 `HostToolRegistryAugmenter` 接入 closed-schema
  `build_knowledge` 和 path-aware `search_knowledge`。模型继续使用已有文件/文档工具阅读与整理，
  写出 OKF draft；build 工具只负责 deterministic canonicalization、configured document embedding、
  validate 与 atomic publish。两个工具都走原有 CapabilityLease、PermissionEngine、durable
  prepared/result/settled 和参数脱敏链，未新增 Knowledge 管理 UI。Chat、iOS、permission reviewer、
  GoalVerifier 与普通 Cowork worker 不获得这两个工具。
- `store_path` 可位于当前 WorkspaceLease 内，也可为用户自然语言点名的外部绝对目录。外部目录不
  扩大 WorkspaceLease，而由 exact `KnowledgeLease` 授予单一 root/operation/agent/session authority；
  Mac bookmark 只写入 session-owned、binary、owner-only `knowledge-access.plist`，CLI 在权限通过后
  生成 exact authorization reference。过宽/敏感目录、父目录替代、root replacement、只读 lease
  mutation 与 identity drift 均 fail closed；bookmark 文件及 sidecar lock 都执行 no-follow、owner、
  regular-file、single-link 边界，bookmark 可按 exact path 撤销，活动 scope 仍须先 drain。
- 建库与查询保持分离。build service 接收 workspace 内已授权的 OKF draft root，以及 workspace store
  或独立 KnowledgeLease 绑定的外部 store；它在任何 embedding 前做 secret scan，用 host chunker
  生成 grounded chunks，只在完整 Validator 通过后原子 publish。更新既有 store 必须在 writer lock
  内同时命中 `expected_store_id` 与 `expected_snapshot_id`。相同完整
  embedding/chunker/normalization identity 可按 canonical text 复用 vector；修改、删除或任一支持的
  模型身份字段变化会精确重建，冻结不支持的 scalar/quantization/metric 等组合直接拒绝。
- 发布布局现为 `.intatis-rag-store.json` + `.intatis-rag-snapshots/` + `.intatis-rag-host/`。
  WorkspaceLease 和 managed terminal 把三者作为不可移除、大小写无关 deny floor；普通 file/patch/
  Git/process/terminal 不能绕过 writer/Validator 改写发布库，Knowledge 内部只派生解除 exact managed
  patterns 的最小 projection。旧 `snapshots/` 只由 read-write build/update 在 store lock 内原子迁移；
  read-only open 不创建基础设施。pointer/layout rename 后 durability 无法确认时返回 non-retryable
  `commitUncertain`，不自动重试。
- build boundary 现在由 host-owned canonical v0.2 writer 重写 Agent draft：任意层非保留
  Markdown 都作为 concept，任意层 `index.md` / `log.md` 都按 OKF reserved shape
  验证；legacy `timestamp` / `# Citations` 只读兼容后迁移为 v0.2；source ID 由
  canonical resource 生成 opaque ID，bundle path 和 scope descriptor 分开处理，私有绝对路径
  不进入 portable snapshot 或 model-facing evidence。exact-slice `chunks.jsonl` 不包含运行时
  wall clock，相同 canonical bytes/config 跨时钟重建为 bit-stable。
- multi-source concept 只把显式 footnote 对应的 source ID 归给该 chunk；仅 exactly-one source
  concept 允许 concept-level fallback，歧义段不会被伪装成 grounded chunk。`generated` 若出现则
  必须同时具有 valid `by` / `at`，footnote claim、definition 与 `sources[].id` 必须机械闭合。
- local-core 仍保留 Apple NaturalLanguage English sentence embedding revision 1 / 512-d 的 exact
  runtime binding、`Float32` L2/cosine exact KNN、Intatis 多语言/代码 tokenizer、BM25/RRF 以及
  embedding-cosine test seam；这些都不代表 shipping 产品 fallback。model-driven 产品 snapshot
  固定 configured embedding identity 与 required semantic reranker identity；query 使用兼容 embedding，
  授权过滤发生在远端 rerank 前，只有实际 semantic rerank 后的 `rerank_applied=true` 才能成功。
  当前宿主冻结中英/代码 corpus 的历史 Apple local route 为
  Recall@5 0.882、MRR 0.681、nDCG@5 0.698、citation precision 1.000；这些数字只代表当前宿主与
  小型冻结 corpus，Intel 真机、最低支持 macOS 和大规模真实知识仍是 `UNKNOWN`。
- 旧的 snapshot-bound `KnowledgeSearchToolHostAdapter` 继续兼容；shipping surface 使用
  `ModelDrivenKnowledgeToolHost`，每次按 `store_path` 获取 exact authority、读取 current pointer、
  mount exact immutable snapshot，并把 mount/bookmark scope 保留到当前 turn grounding 完成后 drain。
  一个 AgentLoop turn 的离线 E2E 已对两个外部 store 完成 build/search/rerank/citation，证明证据与
  snapshot 不串库；随后用 fresh host generation 重新取得 external authority、打开 durable current
  pointer 并再次 search/rerank/citation，证明不依赖进程内旧 handle。
- local-only `search_knowledge` 虽然不写文件、不联网，仍把知识正文带入 answering model，因此
  deterministic gate 对 exact instance intent 返回 `pass`，继续经过 reviewer、PermissionEngine、
  authorization correlation 与 durable lifecycle；不会继承普通本地 read 的自动放行。
- successful evidence 在返回前复核 concept/source/hash/可选 source locator；AgentLoop 又把它限制为
  current-turn citation，并在 final commit 前通过 exact registration 重新打开 snapshot 做异步机械
  重验。urgent purge 会关闭 admission、cancel/drain、使 current pointer 持久失活并清 receipt；不会
  擦除既有 EventLog/tool history，也不宣称物理 secure erase。
- build service 继续复核外层 exact resolved authorization；model-facing `build_knowledge` 已有真实
  registration 和 AgentLoop durable caller，不允许 service 或 raw terminal 旁路。
- Host augmentation close 现在有 checked drain：timeout/active access 会成为可见的 Code/Cowork/CLI
  runtime failure，不能误报成功；重复 close 保持 single-flight/idempotent。
- `IntatisKnowledgeTests` 最终精确计数见 `docs/TESTING.md` 本轮验证记录，覆盖 schema、OKF safety、filesystem、
  checksum/index corruption、secret/injection、build cancellation/timeout/reuse、snapshot/receipt/
  purge、hybrid/rerank/budget/ACL/source locator/final grounding 和质量/性能代理。AgentKernel 的
  current-turn citation registry 另有独立回归。OpenRouter 上 configured
  `google/gemini-embedding-2`（1536 维）与 `cohere/rerank-4-pro` 的最小 smoke、8-query 冻结质量集、
  真实 Agent 自主 read-organize-build-search-cite 及三份 DS-Algorithm PDF E2E 均已通过。macOS Code
  真实触发 exact-directory NSOpenPanel，生成 session-owned `0600` binary bookmark；应用退出重启并恢复
  同一 session 后再次搜索未重新弹窗。功能性模型驱动 Knowledge RAG 验收已闭环；质量集没有证明
  reranker uplift（dense nDCG@5 1.000，reranked 0.990），不能把功能完成外推为推荐模型质量优于 baseline。

## 当前架构事实

- 根 SwiftPM 图包含 15 个公共 library products、3 个内部 C/guard targets、CLI、开发期
  MCP conformance executable 和 15 个 test targets。精确清单以 `Package.swift` 为准。
- `EventLog` 的 append-only JSONL 是 session canonical truth；`session.json` 是可重建的
  schema-v2 projection，artifact 使用独立 blob/index store。
- Chat/Code/Cowork 都从稳定 `TurnID` 和结构化事件投影 UI。App 窗口只持有选择；macOS
  runtime 由进程级 `AppSessionRuntimeManager` 按 exact session key 持有。
- Code/Cowork 的工具调用必须经过 ToolRegistry、CapabilityLease、WorkspaceLease、
  PathConfinement、DeterministicPolicyGate、ModelPermissionReviewer、PermissionEngine 和
  durable tool execution。明确 hard deny 不能被 reviewer 放宽。
- production registry 不暴露 raw `run_shell`；shell-capable host 使用 runtime-owned
  `exec_command` / `write_stdin` managed terminal，默认断网并保留进程清理与输入清洗。
- Skills 只提供冻结上下文，不授予权限；外部 MCP 是 client-only，HTTP/stdio transport、
  OAuth/callback/task 和 process ownership 仍受产品边界与权限控制。
- Provider catalog 保留 model options/variant/adapter 语义；credential 只从受控 reference
  懒加载，不进入 EventLog、projection、诊断包或文档。

## Chat 与 Agent 托管搜索

- 搜索只属于当前所选 exact Chat route。该 route 明确支持时，向当前模型
  提供厂商对应能力并以 `tool_choice: auto` 让它自行决定是否搜索；不支持、未知或未适配时，当前
  模型静默发送普通 Chat，不显示提示或错误，不执行任何模型/服务/tool fallback。
- v0.31 引入的 `web_search_model` / `webSearchModel` 后台路由行为已取消。runtime 不读取它
  覆盖当前选择或发起额外模型请求；为旧配置兼容可继续 decode/preserve，但字段运行时无效、无
  警告，新生成配置不再主动加入。
- `Capability.hostedWebSearch` 与 MCP `toolSearch` 已分离；`ProviderRegistry.chatRuntimeRoute()` 先验证
  普通 Chat adapter，再按 exact model capability 与 exact adapter 规划 dialect。OpenRouter 使用
  `openrouter:web_search`，OpenAI Responses encoder 使用 `web_search`，compatible/legacy/custom
  默认关闭，因此不会再为了探测能力先发送可能失败的搜索请求。
- 只有 provider-specific 结构化 unsupported code/parameter 且首个有效 payload 尚未被接受时，
  provider 才允许在同一 provider/model/variant 上重发一次普通 Chat；裸 404、自由文本和 partial
  payload 都不会触发重放。
- Code/Cowork/CLI 新增普通 Agent Tool `hosted_web_search`。它只有 required `query`，不接受 engine、
  model、provider、结果数或浏览器参数；仅在 exact agent route 明确声明 provider-hosted search、
  adapter dialect 已实现、当前 lease 含独立 `ToolCapability.hostedWebSearch` 时注册。fresh read-write
  lease 获得该 capability；read-only/reviewer、旧 durable lease 和 unsupported route 不会被扩权。
- 该工具复用调用 agent 同一个 exact provider/model/options，专用请求使用
  `tool_choice: required`，并在 hosted shape 被拒绝时 fail closed；不会退回普通模型回答，也不会调用
  `browser_search`、`web_fetch`、MCP、shell、本地浏览器、第二模型或隐藏搜索后端。调用仍经过
  strict schema、secret scan、ToolRegistry、lease、权限三层门、durable ticket 与 ToolResult。
- production registry identity 已因新增独立工具推进为 `intatis.standard.v4` / `intatis.cowork.v4`。
  `swift build`、hosted-search focused tests、`CapabilityLeaseTests` 7/7、`ToolRegistryLeaseTests` 27/27、
  macOS Debug unsigned App build 与 iOS generic Simulator Debug unsigned build 已通过。另一次完整
  `swift test` 在 `IntatisToolsTests` 227/227（19 opt-in skipped）与 `IntatisSkillsTests` 29/29 通过后，
  于既有 SharedUI 时序测试 `testSelectedAgentUpdateRestartsRichRenderingDwell` 静默停滞并被中止；该 exact
  test 随后单独运行 1/1 通过，因此本轮不把完整 suite 记为通过。尚未使用真实 provider/key 消费额度
  做 live smoke。
  完整合同与当前 adapter 边界见 `docs/CHAT_HOSTED_SEARCH.md`。

## UI 与内容渲染

- macOS/iOS 当前使用系统语义表面和原生 Liquid Glass；正常 assistant/agent 正文直接落在
  conversation canvas，结构化状态、用户消息、错误、权限、Goal/Task 使用 Material 边界。
- iOS 与 macOS 已统一品牌/session/Settings 的 serif 标题和系统 sans 正文/控件，两端使用
  model/usage + action/input/voice/Send-or-Stop 的两排 composer；voice 始终紧邻主操作左侧，
  不占用或复制唯一的 Send↔Stop 槽位。composer 的 compact secondary/voice control 另显式固定
  40pt 外层布局与圆形 `contentShape`，使屏幕上完整圆形控件与真实点击区域一致，而不是只让内部
  SF Symbol 字形响应点击。macOS Chat 与 Cowork 的 paperclip、附件数量/移除菜单、文件 importer
  和 URL drop modifier 现在是同一套共享 surface；Code 与 iOS Chat 的现有能力边界不随之扩大。
- rich text 使用仓内经审计的 Microsoft SwiftStreamingMarkdown thin derivative 与
  exact iosMath Apple-native 数学排版；plain-safe 仍是运行时救援路径。
- macOS Chat/Code/Cowork history 使用最多 16-row eager page 与显式分页，避免旧的 rich +
  lazy session-entry layout cycle。旧性能数字只保留在 Git/report 历史，不是当前 release
  readiness 证明。
- Cowork 不再把完整 `CodeProjection.items` 发布给 MainActor，也不在点击时扫描/过滤完整
  历史。Conversation actor 在 fold 时维护 typed per-agent index；每个窗口只持有选中 agent
  的一个最多 16-row page、独立分页边界和 stale-request generation。非选中 agent 的增量
  不会刷新当前 transcript，查看选择也不改变 runtime、scheduler、mailbox、lease 或发送目标。
- Cowork roster 现分成 EventLog-derived historical identity catalog 与 live operational roster：
  前者驱动 stable-ID lazy Agents 列表和只读 conversation selection，后者独占 send/delegate/
  message/ask/rebind/remove、settings 与 workspace/capability 操作。presentation 会先按 agent
  线性聚合 task/lease/status，避免历史 agent 数量增长后形成 agent×task/lease 重扫。Agents
  使用 durable 首次 admission 的创建顺序；status、消息、detach 或 reattach 不会触发重排。
- Cowork thread header 只显示 session durable name。宽屏 rail 继续作为同一 conversation canvas
  的 trailing overlay；outer rail 固定 348pt、glass card 固定 318pt，并使用系统 `Glass.clear`
  降低独立光块感，不增加整栏背景、手绘阴影或渐变。Agents 使用更大的系统文字，选中态只保留
  accent 蓝色背景，不再叠加勾选图标；顶部 compact permission 只显示状态、tool、安全摘要与必要
  action，不展示 risk chip、raw arguments 或默认展开详情。
- Cowork thread header 不再提供独立 MCP Content 快捷按钮；内容浏览保留在
  `Project Settings → MCP → Browse Content`。右侧 status rail 显隐开关使用系统 compact 圆形
  glass/bordered icon control；这两项只改变 header chrome，不进入 rail overlay、固定宽度或
  render-boundary 输入。
- rail 现在是 thread 上不参与布局协商的 `.overlay(alignment: .trailing)`，并关闭 inspector
  transaction 的隐式动画。rail 由只包含 rail 输入的 Equatable render boundary 隔离；thread 的
  empty/loading/page/rich 状态不能重新物化 cards。每个 passive `Glass.clear` 都位于自己的稳定
  backdrop，独立 status cards 不再放入会融合/重组 shape 的 `GlassEffectContainer`；系统动态
  separator 的单物理像素 `strokeBorder` 继续作为轮廓锚点，不使用固定 RGB、渐变、投影或自绘高光。
- Code/Cowork 的 raw bottom-anchor 恢复不再通过 GeometryReader、屏幕全局坐标或
  `PreferenceKey` 回写布局；系统 `onScrollVisibilityChange` 只在 anchor 可见性真正变化时提交
  observation。窗口移动、focus 或全屏变化因此不会仅因 screen origin 改变而触发 thread 布局链。
- Cowork transcript 复用一个固定 ScrollView 根和最多 16 个稳定行槽。agent/page 切换及选中
  agent 的连续增量期间先显示轻量 raw text；同一选择和内容静止 300 ms 后才重新准入 rich
  Markdown，避免快速点击或 streaming 为每次更新挂载新的 AppKit 文本/选择子树。content/raw
  frame 在 ScrollView 扩展到 overlay 下方前固定，因此 Agent 内容、空态和 scroller 可见性都不会
  改变中栏或 composer 的水平边界。

## 持久化与安全边界

- session EventLog、workspace bookmark、artifact、browser profile、inference catalog 和
  provider/auth 配置各有独立 owner、权限和 schema 边界；bookmark bytes 不进 JSONL。
- SecretScanner、Mediator、Keychain/credential resolver、Hardened Runtime、managed
  terminal Seatbelt/default-network-deny 与 iOS linkage boundary 均保留。
- 旧 schema 与未知 future event 的兼容/fail-closed 规则不得因文档或版本更新而改变。
- 第三方代码、prompt、字体和依赖来源以 `NOTICE.md`、`ThirdPartyNotices/`、vendor ledger
  与 `docs/OPEN_SOURCE_REUSE.md` 为准。本轮版本/文档校准没有新增依赖。

## 最近验证状态

- 2026-08-13 Cowork Session 内独立 WorkTask / Run 中断 / 原子委派重构：WorkTask 已删除
  Run、Goal、agent owner 字段和跨 Run dependency/carry-forward 路径；Goal 与 WorkTask 状态不再
  相互传播。provider、网络和 runtime 中断把旧 Run 终结为 `interrupted`，显式 Resume 创建新
  RunID。`delegate_task` 只使用已经 attached 的 data-plane worker；纯 Mediator/exact-provider 检查在
  admission lock 外等待，随后在 lock 内重新复核全部可变状态并以一个 EventLog batch 提交 message、
  delegation、lease、invocation、queue 与必要的 WorkTask linkage。提交前拒绝保持 EventLog 零变化并
  结算 `not_started`。当前验证：`IntatisProtocolTests` 107/107、`IntatisConversationTests` 212/212、
  `IntatisAgentKernelTests` 220/220、`IntatisCoworkTests` 364/364、`IntatisSkillsTests` 29/29、
  `IntatisToolsTests` 227/227（另有 19 个显式 opt-in skip），`swift build` 通过。整仓
  `swift test` 仍受既有 SharedUI async waiter 停滞影响，未记为全量通过；详见 `docs/TESTING.md`。
- 2026-08-13 Permission Reviewer plain-text verdict 格式修复：240 Character 从有效性硬上限改为共享
  prompt 的简洁度建议；241/500/1000 Character 的非敏感 `ALLOW` 与 `DENY` reason 均保留原决定。
  完整 reason 在任何摘要截断前先做敏感信息检查；live bound settlement 继续只写固定宿主文案。
  缺失/重复/非末行 marker、空 reason、JSON/code fence、无 completion 与非成功 finish 分别保留 typed、
  secret-free failure kind，旧 `malformed_verdict` / `provider_still_stopping` 继续可解码。
  `PermissionReviewProtocolTests` 13/13、`IntatisPermissionReviewerTests` 14/14、
  `PermissionReviewControlPlaneTests` 51/51，合计 78/78、0 failures。未运行全量 test、macOS/iOS app
  build、真实 provider 或 GUI smoke。
- 2026-08-12 Cowork ordinary-worker WorkTask update 收窄：worker 继续使用稳定的 `task_update`
  名称与既有执行/权限/持久化链，但业务字段仅保留当前任务的进度、允许状态、结果和证据；
  manager 的完整更新字段未收窄。`ToolRegistryLeaseTests` 26/26、`WorkTaskRuntimeTests` 22/22，
  另有 closed-schema pre-permission/execution gate 1/1，相关合计 49/49、0 failures；
  `swift build --disable-automatic-resolution` 通过。未运行全量 test、macOS/iOS app build、真实
  provider 或 GUI smoke。
- 2026-08-11 fixed-format document reader 拆分与瘦身 gate：完整 `IntatisToolsTests` 223/223
  （19 skipped）、`AgentLoopPolicyTests` 36/36、`CapabilityLeaseTests` 7/7、
  `ToolRegistryLeaseTests` 25/25、`MessageDelegationSplitTests` 10/10，均 0 failures。用户提供的
  外部 Intatis-test 目录只作为输入；测试把 1 份稀疏 XLSX 与 3 份 PPTX 复制到临时
  workspace 后运行，4/4 读取成功且不修改原目录。installed core runtime 与 EPUB write/read smoke
  各 1/1 通过；rbook write-only helper 的 fmt/check/test/clippy 全门通过（7 unit + 2 integration）。
  `swift build --disable-automatic-resolution`、版本一致性检查、macOS `IntatisMac` Debug unsigned 与
  iOS generic Simulator Debug unsigned build 均退出 0，仅报告仓库既有 warning。一次整仓
  `swift test --disable-automatic-resolution` 在完成 Tools 后挂于既有 SharedUI async waiter，采样后
  人工中断为 130；不能记为本轮全量通过，也未观察到 document reader 相关 failure。
- 2026-08-12 Cowork single-pass permission sidecar corrective gate：
  `PermissionReviewControlPlaneTests` 47/47、`AgentLoopPolicyTests` 37/37、
  `AutomaticPermissionReviewTests` 35/35、`DurableMultimodalAgentLoopTests` 9/9、
  `AuthorizationSidecarTests` 12/12、`IntatisPermissionReviewerTests` 10/10、
  `PermissionReviewProtocolTests` 12/12，合计 162 tests / 0 failures。覆盖 same-call string sidecar 拆包与
  绑定、ask-only host requirement、valid sidecar 的 current-turn in-memory formatting example、raw/transient
  durable isolation、missing → missing → corrected same-args 调用可达 reviewer、tool-input failure 不消耗
  permission denial fuse、live reviewer prompt 不含 user/task semantic narrative、manual 保留字段拒绝、
  dedicated host admission、active/cached/recovered invocation 复验、固定宿主 reason/provider-failure 文案及
  in-engine reviewer 误配 fail closed。新增 strict-schema 回归还使用真实 shipped Skill/Knowledge descriptor，
  并抓取 OpenRouter 与 OpenAI-compatible 两种最终 Chat Completions HTTP body，递归断言所有 strict
  function 的递归 `required == properties.keys` 与 `additionalProperties:false`，以及 request-owned deferred
  MCP function 装饰与 durable output 不变；其中一条贯通 automatic Cowork `tool_search` 执行到下一轮
  `AgentRequest`。上述 162 计数只代表 focused
  permission suites；本次 strict-schema 修正另有 `SearchKnowledgeToolTests` 4/4。
  snapshot-bound `search_knowledge` 迁至 input schema v2；v1 resource 原样保留，v2 将 `limit` 表示为
  provider-required integer-or-null，null 映射宿主默认 8。
  `swift build --disable-automatic-resolution` 通过；受影响目标分别为 `IntatisAgentKernelTests` 217/217、
  `IntatisKnowledgeTests` 118/118、`IntatisCoworkTests` 364/364、`IntatisCLITests` 45/45（8 skipped）。
  `IntatisMac` macOS Debug、`CODE_SIGNING_ALLOWED=NO` 构建通过；只出现仓库既有 unused-result 与 SwiftUI
  deprecation warnings。
  完整 `swift test --disable-automatic-resolution` 完成 Tools 223/223（19 skipped）后再次挂于仓库既有
  SharedUI async waiter，连续两分钟无输出后人工中断为 130，不能记为本次全量通过。opt-in 真实 provider
  strict-sidecar smoke 已成功编译但按设计跳过；未运行真实计费请求或 UI/manual switch smoke。
- 2026-08-11 model-driven Knowledge live acceptance：OpenRouter 最小 smoke 1/1，embedding 为
  1536 维并报告 input/total token 7，reranker 返回完整 permutation、有限 score 和 search unit 1；
  8-query 冻结集的 dense baseline 为 MRR/nDCG@5/Recall@5 = 1.000/1.000/1.000，configured reranker
  为 1.000/0.990/1.000，embedding usage 343 token、reranker usage 8 search units。真实 Agent 对测试
  文本在 32.686 秒内完成 read → OKF draft → external build → required-rerank search → exact evidence
  citation；另一个 110.980 秒的 E2E 用 `read_pdf` 读取 `DPV-chap2.pdf`、`DPV-chap4.pdf`、
  `DPV-chap6.pdf` 的冻结页段，形成 3 个 concept / 22 chunks 后检索并引用。macOS Code 首次外部搜索
  出现 exact-directory NSOpenPanel，保存 session-owned `knowledge-access.plist`（binary、`0600`、revision
  1）；退出、重启、恢复同一 session 后再次调用未出现授权框。空库按设计返回 `KB_INDEX_NOT_READY`，
  没有修改文件。Knowledge 118/118、Knowledge Provider 11/11、tool wire metadata 5/5、CLI 9/9、
  AgentLoop 2/2、grounding 7/7、Cowork lease 25/25、SecretScanner 1/1，以及工作区沙箱外
  managed-terminal publication anti-bypass 1/1 均通过；macOS/iOS Debug unsigned build退出 0。
  本轮整仓 `swift test` 在完成 Tools/Skills 后，于既有 SharedUI async scheduler 测试进程中持续约
  7 分钟 0% CPU/无新输出并被人工中断为 130，不能记为全量通过，也未观察到本任务相关 failure。
  provider 没有返回完整货币金额，项目仍不按可变价格表推算账单。
- 2026-08-05 Flotis 单模型语音 runtime 迁移：`ComposerVoiceInputTests` 6/6，覆盖 draft merge、
  WAV 16-bit PCM 及 WAV/M4A 均不注入 `AVEncoderBitRateKey`；
  `IntatisProvidersMultimodalTests` 22/22，覆盖 owner-only disk-backed multipart WAV、OpenRouter
  JSON-base64 `input_audio`、exact runtime route、严格 JSON Content-Type、timeout 与错误 payload。
  完整 `swift test`、XcodeGen、版本一致性检查、`IntatisMac` macOS Debug 和 `IntatisiOS` generic
  Simulator Debug unsigned build 均通过；两端最终 bundle 含麦克风 usage description。先前本地
  ad-hoc macOS Debug 签名包已读回 `com.apple.security.device.audio-input=true` 且 strict codesign
  verify 通过，但这不替代正式 Developer ID/Hardened Runtime/公证验证。未执行真实麦克风或线上
  transcription provider smoke，也未启动 App 做视觉检查，因而真实权限交互、设备录音、具体
  provider/model 可用性、计费和像素表现仍为 `UNKNOWN`。
- 2026-08-03：`xcodegen generate` 与 `scripts/check-version-consistency.sh` 通过。
- `IntatisMac` unsigned universal Release 构建通过；最终 bundle 为 `0.32 (32)`，可执行文件
  同时包含 `arm64` 与 `x86_64`。该构建用于源码与元数据验收，不是可分发签名产物。
- `IntatisiOS` generic Simulator Debug 构建通过；最终 bundle 为 `0.32 (32)`。两端构建仅有
  既有的 unused-result / deprecated `onChange` 警告，没有构建失败。
- `swift build` 在允许 Swift/Clang 写入用户缓存的宿主环境通过，覆盖 CLI 与 SwiftPM
  products；受限沙箱内的首次尝试仅因 module cache 无写权限而未进入源码编译。
- 上一轮外层 sandbox 外的 `IntatisToolsTests`：141 tests / 15 skipped / 0 failures。
- focused `IntatisAgentKernelTests`：169 tests / 0 failures。过期的 800-token soft-budget
  fixture 已改为保留充足真实 prompt 余量，同时继续验证 provider 忽略输出 ceiling 后的
  soft-budget overrun；生产 `requestTooLarge` 保护未修改，独立 admission/concurrency 回归仍保留。
- 完整 `swift test` 已在允许 Swift/Clang cache、process 与 loopback 测试的宿主环境通过；
  需要真实 browser/Git/provider/credential/network 的 opt-in 用例仍按声明跳过，不能冒充已验证。
- 2026-08-03 Cowork agent-thread 专项：Debug fixture 使用 8 个 selectable agent、每个 1,000
  条记录、4-agent 合计 500 canonical delta/s，先完成 1,000 次 rapid switch，再完成 180 秒
  10 Hz nominal soak（实际 1,486 次 timed switch）；Computer Use 观测为 0 main-thread warning、
  0 incident，结束时仍只挂载 16 条，`NSTextViewSharedData` 为 14、`GestureNode` 为 173。
  `vmmap` physical footprint 为 62.1 MiB、峰值 74.8 MiB；`ps` RSS 为约 156.6 MiB。两者口径
  不同，均未出现旧实现的线性增长。本 fixture 是 offline presentation stress，不替代真实
  provider/EventLog/低端设备长时矩阵。
- 2026-08-04 historical roster 修正：512 identity 投影用例在 detach 500 个后仍保留 512 个
  历史项且 live roster 仅 12 个；detached selection、512-ID presentation catalog、lazy/unfiltered
  rail 与 read-only operation fence 的定向测试通过，IntatisConversationTests 172/172、IntatisMac
  Debug unsigned 构建通过。Computer Use 实测 detach 当前 `@research` 后不跳回 main，离开再返回
  仍可查看 985–1,000 / 1,000；随后在 500 delta/s 下完成 1,000 rapid switches，0 warning / 0
  incident，仍只挂载 16 rows。
- 2026-08-04 rail lighting/fixed-geometry 修正：`ThreadLayoutTests`、
  `CoworkInferencePresentationTests` 与 `CoworkAgentThreadPresentationModelTests` 组合共 30 tests /
  0 failures；IntatisMac 与 IntatisiOS Simulator Debug unsigned build 通过。1372×768 原生 Light
  对照中，`@main` / `@research` 的 composer 像素边界一致，rail 均位于 x=1076…1365；8×1,000
  rows + 500 delta/s 下再次完成 1,000 rapid switches，0 warning / 0 incident、最多 16 rows。
  该次没有重跑 180 秒 soak、Dark、Reduce Transparency、Increase Contrast 或完整 SwiftPM suite。
- 2026-08-04 rail window-stability 第一版结论已被用户复现结果推翻，不再作为当前通过证据。
  后续真实 Test session 日志证明旧 `IntatisThreadViewportFramesPreferenceKey` 在全屏变化时仍会同帧
  重复更新；仅做像素相位修正不能解决问题，相关旧截图/数值只保留为历史排查记录。
- 2026-08-04 上述第二版 corrective pass 随后也被用户在新构建中稳定复现结果推翻：删除 viewport
  preference 与 shared glass container 仍不够，因为 trailing overlay 的几何宿主仍是会随 transcript
  更新的 `threadColumn`，且 `selectedAgentID` 仍在整个 rail 的 Equatable snapshot 中；每次点击都会
  让所有原生 glass section 重新进入更新周期。当前源码改为由 exact outer-detail canvas 分别托管
  leading thread 与 trailing rail，thread 不再是 rail 的 alignment guide；selection 从 rail snapshot
  中移除并通过独立轻量状态只更新蓝色行背景/无障碍 value；每个 `Glass.clear` backdrop 也成为
  content-independent Equatable view。`ThreadLayoutTests|CoworkInferencePresentationTests|
  CoworkAgentThreadPresentationModelTests` 31/31 通过，其中 production-shaped host 完成 360 次
  agent selection/mode/inspector/window-size 交错变化；IntatisMac macOS Debug 与 IntatisiOS generic
  Simulator Debug unsigned build 通过。按用户要求不使用 Computer Use 或截图采样，真实视觉是否消除
  数像素光学跳变仍需用户在新构建中确认，不能沿用前两版的截图/AX 结论。
- 同日 Codex managed sandbox 内的完整 `swift test --disable-sandbox --quiet` 仍只有
  `IntatisToolsTests` 的 process/Seatbelt/loopback 用例受宿主限制失败；单独完整
  `IntatisSharedUITests` 一次在 build 后无用例输出并被中止，当前修改直接覆盖的 SharedUI 定向
  用例均独立通过。不得把这次 sandbox 运行记成全量通过。
- 直分发脚本已在用户宿主环境进入真实 Developer ID 构建/签名链路；一次开启代理/VPN的
  运行在 Apple notarization 网络阶段未完成，另一次先关闭代理/VPN的运行则在 SwiftPM
  克隆 `swift-system` 时因 GitHub 专用代理 `127.0.0.1:1082` 已停而失败。脚本现在支持
  `INTATIS_PAUSE_BEFORE_NOTARIZATION=1`：保持代理完成构建/签名，暂停后切换网络，并在不
  重建的情况下探测及重试 Apple notarization。
- Apple `notarytool history` 已确认两次 `Intatis-notary-upload.zip` 完整到达服务端，但查询时
  均长时间停在 `In Progress`；用户中断的是本地 `--wait`，没有取消服务端任务。旧脚本把
  JSON 结果重定向且无限等待，隐藏了实时状态，并在 Control-C 后删除临时签名 App。脚本现
  改为可见 upload + submission ID、默认 30 分钟有界 wait，以及 owner-only recovery state；
  超时/中断后可复用同一 App/DMG submission，不再重建或重复上传。旧的两条任务发生在持久
  recovery 加入前，即使之后 Accepted，也没有本地原 App 可直接完成 staple。最终 Accepted、
  staple 和 Gatekeeper 证据仍未取得。

## 当前已知缺口

1. 先等待现有两条 App submission 到达 terminal，期间不要继续重复上传；随后只运行一次
   新的可恢复两阶段流程，完成 App/DMG notarization、staple、codesign 与 Gatekeeper
   assessment，并记录最终 ZIP/DMG 和 SHA-256。在这些证据齐全前不能发布。
2. 真实 provider/key、第三方 MCP/OAuth、长时 browser/profile、VoiceOver/clipboard、低端
   iPhone/iPad 与长 soak 仍有环境矩阵空白；不得用离线 fixture 冒充。
3. macOS 27/Xcode 27 当前仍是 beta toolchain evidence；最低支持系统/设备的正式矩阵需要
   独立验证。
4. `@ai-sdk/openai` 的普通 Chat adapter 仍未实现，所以该 exact adapter 即使声明
   `hosted_web_search` 也会按既有规则在网络前 config fail closed；在普通 adapter 完成前不能把
   已有 OpenAI Responses search encoder 宣传为完整 native OpenAI route 支持。真实厂商 smoke 仍待
   用户凭据环境验证。
5. Knowledge 的功能性真实 E2E 已完成，但当前 8-query 冻结集没有证明推荐 reranker 相对 dense
   baseline 的质量 uplift，nDCG@5 反而从 1.000 降至 0.990。它仍需要更难、更大、独立标注的领域集合
   做模型选择；large-corpus latency/memory/disk/cost ceiling、Intel/最低 macOS 与 Linux provider matrix
   仍为 `UNKNOWN`。provider usage 可报告 token/search units，但没有 versioned price evidence 时不推算金额。
6. Cowork sidecar 的 focused offline gate 已通过，但仍有明确 P2/信任边界：单字符串是 acting model 的
   未信任解释，可能遗漏或编造语义；acting model 也可在普通 assistant 文本自行复述它并按既有消息规则
   持久化。malformed acting-provider error preview 仍依赖通用 sanitizer；live 没有固定 input ceiling，未来
   必须从 exact route budget 推导并整份 fail closed。若错误注入 in-engine reviewer，当前会在其返回后拒绝，
   因而仍可能多一次不应存在的调用；shipping 默认没有该配置。真实 provider route compliance 仍是
   `UNKNOWN`。

## 文档治理

当前文档入口和历史分类见 `docs/README.md`。`CURRENT_STATE.md` 从本轮开始只保留当前摘要；
已完成阶段、旧测试数字和事故调查留在 Git 历史及 dated reports，不再无限追加到这里。
