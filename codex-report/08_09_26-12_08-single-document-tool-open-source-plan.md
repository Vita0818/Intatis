# Intatis 最小文档工具组定稿：成熟后端，最薄连接层

日期：2026-08-09

状态：`FINAL DESIGN / IMPLEMENTATION NOT STARTED`

面向读者：后续负责实现的 Codex / Intatis 维护者

范围：

- PDF：读取已有文字、显式 OCR、页面直接导出 PNG 预览、验证转换生成的 PDF；
- DOCX、PPTX、XLSX、HTML、EPUB：读取、常见创建与编辑、静态预览、导出 PDF；
- 不支持任何以 PDF 为输入的修改操作。

> 方案已经收口。Intatis 不实现文档解析器、排版引擎、OCR 引擎、Office 渲染器或 PDF 内容编辑器，只把经过能力核实的成熟组件接到现有权限和工作区边界上。组件缺失或失败时明确失败，不自动切换后端。

## 0. 最终决定

本报告冻结以下决定：

1. **PDF 编辑整体后置。** 不支持正文编辑、批注、表单修改、合并、拆分、抽页、删页、重排、旋转、裁剪、水印、遮盖或脱敏。即使某个候选库能做其中一部分，本期也不注册这些 operation。
2. **PDF 观察能力必须具备。** 支持读取已有文字、显式 OCR，以及把指定页面直接渲染成 PNG。
3. **文档转 PDF 必须具备。** DOCX、PPTX、XLSX、HTML 使用唯一固定导出链；EPUB→PDF 的目标不变，但当前 `epub.js`/WKWebView 候选必须先通过 full-spine corpus gate，失败则改选一个经证明的成熟固定后端。生成新的 PDF 不等于编辑输入 PDF。
4. **工具按权限边界拆分。** 不再把读取、执行、写入全部塞进一个静态 `document` descriptor。
5. **XLSX 接受 LibreOffice 重写。** `openpyxl` 表达结构修改，LibreOffice Calc 重算并保存 staged XLSX；最终文件可能是 LibreOffice round-trip 结果。
6. **runtime 分发另案。** 本报告假定开发和测试环境已预置固定版本的后端；不设计下载器、安装器、App 内打包、双架构闭包、签名或公证。
7. **图片进入模型上下文另案。** 本报告负责可靠生成页面 PNG 及其元数据，不重复设计 provider、EventLog、replay 和 compaction 的多模态协议。相关平台问题见 `08_09_26-13_42-durable-multimodal-context-handoff.md`。
8. **成熟组件优先。** 只写 schema、权限和路径校验、固定调用、错误映射、staging、验证及原子提交；已有成熟实现的算法不在 Intatis 内重写。

在这些边界下，没有阻止编码的架构 blocker。后续仍要对精确版本、许可证、实际 API 和真实样本做集成核验，但这些是实现门，不再是产品范围选择。

## 1. 成熟开源优先是硬原则

### 1.1 能力先于接口

只有锁定版本的公开 API/CLI 能直接完成、并经真实 corpus 验证的 `(format, operation)`，才可列为 `supported`。

以下证据都不够：

- README 出现某个关键词；
- 源码里存在同名枚举或 annotation 类型；
- 文件能够 reopen；
- validator 返回成功；
- 页面能够渲染一张看似正常的图片。

它们不能单独证明编辑语义、无损往返、视觉保真或安全删除内容。

### 1.2 Intatis 只拥有连接层

每项操作绑定一个唯一 semantic backend，以及零个或多个职责不重叠的固定 renderer/validator。Intatis 只实现：

- strict tool schema 和 operation/format 矩阵；
- PermissionIntent、CapabilityLease、WorkspaceLease 和路径校验；
- 固定 executable/API、固定参数和版本化 JSON envelope；
- timeout、cancel、断网、进程树清理和有界日志；
- staging、后置条件验证和原子提交；
- 结构化错误与可审计的 engine/version 结果。

Intatis 不实现：

- PDF content stream、字体子集或正文重排算法；
- OOXML、HTML 或 EPUB 通用 serializer；
- OCR、layout、公式计算或 Office 渲染引擎；
- 第二套权限、sandbox、artifact、事务或调度平台；
- MCP server、动态 backend registry、插件 ABI、常驻 daemon 或通用 Document IR。

如果选定组件不能直接完成某个高级操作，先搜索并核验更成熟且许可证可接受的组件。找到后替换该 operation 的唯一后端；找不到或尚未证明时返回 `unsupported_operation`。不得为了保持表面功能完整而在 Intatis 中自行补写解析或排版算法。

### 1.3 “一个固定后端”不等于排斥其他成熟组件

一个固定流水线可以包含多个组件，例如：

```text
DOCX -> LibreOffice 导出临时 PDF -> PDFKit 渲染页面 PNG
```

两者职责不同，不是互相 fallback。任一步失败，整个调用失败。

当前表中的选择是 P0 固定映射，不代表永久禁止其他开源项目。以后发现更合适的成熟组件时，可以在完成许可证、provenance、能力和 corpus 审计后修改映射；运行时仍不得自动试第二个后端。

PDFKit 和 WKWebView 是 Apple-native 渲染例外，不应写成开源组件。选择它们是因为系统已有、接口稳定且能减少第一方代码。

## 2. 明确禁止自动兜底

新工具组禁止：

1. Docling 失败后自动尝试 MarkItDown、另一种 OCR 或远程 API。
2. LibreOffice 导出失败后只返回抽取文本并把任务标为成功。
3. `python-docx`、`python-pptx`、`openpyxl` 写入失败后改用第二套 OOXML 库。
4. 本地后端缺失时调用网站、云端转换服务或 MCP server。
5. 验证失败后仍提交输出，或返回空文档、占位图片、原文件副本。
6. 接受模型提供的 `backend`、二进制路径、shell 命令、网络地址或临时目录。
7. 用 `auto`、`best_effort`、`compatible` 等名称隐藏后端选择。

固定错误至少包括：

- `backend_missing`
- `backend_version_mismatch`
- `backend_failed`
- `unsupported_operation`
- `unsupported_feature`
- `ocr_required`
- `validation_failed`
- `render_failed`
- `output_conflict`
- `commit_uncertain`

每次成功结果必须报告预定 engine chain 和实际版本；失败只报告受清洗的错误摘要。

## 3. 模型侧工具按权限拆分

工具数量不是架构复杂度。下列入口共用同一套 schema utility、typed runner 和 worker，不各建一套服务：

| 工具 | 固定范围 | 权限边界 |
|---|---|---|
| `read_pdf` | PDFKit 读取已有文字、页数和基础 metadata | 只读；不启动外部进程 |
| `document_read` | DOCX/PPTX/XLSX/HTML/EPUB 原生结构读取 | process-backed observation；无持久工作区写入 |
| `document_ocr` | 对 PDF 执行用户明确请求的 OCR | 固定本地执行；不修改输入 PDF |
| `document_render` | PDF 直接转页面 PNG；其他格式先生成临时 PDF 再转 PNG | 写入显式 workspace `output_dir`，完整页面 bundle 原子提交 |
| `document_export_pdf` | 非 PDF 文档导出新的 PDF | 写入指定目标；拒绝 PDF 输入 |
| `document_write` | DOCX/PPTX/XLSX/HTML/EPUB 的声明子集 create/edit | 写入指定目标；拒绝 PDF 格式 |

规则：

- 每个 ToolDescriptor 使用固定 side effect，不做 invocation-time descriptor 变形。
- PermissionIntent、touched paths 和 capability 必须匹配精确输入/输出。
- read-only worker 只获得允许的观察型入口，不会因为持有读取 capability 而看见写操作。
- `document_write(format=pdf)`、`document_export_pdf(input_format=pdf)` 以及任何 PDF mutation 都在 schema/dispatch 边界返回 `unsupported_operation`。
- 工具名可以在实现时按现有 catalog 命名规范微调，但上述权限分组不得重新合并成一个万能 descriptor。

实现新目录时还必须同步迁移旧生产入口：

- `edit_pdf_pages` 从 standard/Code/Cowork 生产 registry 下架，生产 lease 不再授予对应 PDF 编辑 capability；若为历史日志兼容保留 decoder 或源码，也不得再被模型发现或执行。
- 当前带 `backend=auto` 和 Docling→MarkItDown fallback 的旧 `read_document`，必须重写成无 backend 选择的新固定入口，或从生产目录下架；不能和新工具并存成为隐式备用路线。
- 当前 `read_pdf` 对 image-only PDF 的提示必须从“调用 `read_document auto`”改成 typed `ocr_required`，只允许用户或模型随后显式调用 `document_ocr`。
- 旧 capability 名若为历史事件解码保留，不等于继续向 live roster/lease 授权。

## 4. 固定组件与 operation 映射

| 格式 | 原生读取 | 创建与编辑 | 导出 PDF | 页面预览 | 固定验证 |
|---|---|---|---|---|---|
| PDF | PDFKit；只读已有文字和 metadata | **不支持** | 不适用；只验证其他格式生成的新 PDF | PDFKit 直接 bitmap draw → PNG | `pdfcpu validate` 显式 strict 模式 + PDFKit reopen/render smoke |
| DOCX | `python-docx` | `python-docx` 的常见高层 API 子集 | LibreOffice Writer | LibreOffice 临时 PDF → PDFKit PNG | `python-docx` reopen + LibreOffice export + PDF 输出验证 |
| PPTX | `python-pptx` | `python-pptx` 已证明的 shape/text/image/table/chart 子集 | LibreOffice Impress | LibreOffice 临时 PDF → PDFKit PNG | `python-pptx` reopen + LibreOffice export + PDF 输出验证 |
| XLSX | `openpyxl`；大表必须指定范围 | `openpyxl` 修改 → LibreOffice Calc 重算并保存 staged XLSX | LibreOffice Calc | LibreOffice 临时 PDF → PDFKit PNG | `openpyxl` reopen + Calc round-trip 语义断言 + PDF 输出验证 |
| HTML | `lxml` | `lxml` DOM/attribute/text/style 节点操作 | WKWebView print-to-PDF，网络和远程资源关闭 | WKWebView PDF → PDFKit PNG | `lxml` parse + WKWebView load/render smoke + PDF 输出验证 |
| EPUB | `rbook` + 必要的章节 XHTML `lxml` 操作 | rbook 已证明的 metadata/resource/spine/ToC 子集 | **PROVISIONAL**：本地 `epub.js` + WKWebView print-to-PDF；整本 corpus 通过前不得标为 supported | 同一临时 PDF → PDFKit PNG | 固定 release EPUBCheck + full-spine render smoke + PDF 输出验证 |

多个组件列在同一格时表示固定流水线，不表示失败后换后端。

### 4.1 PDF 的最终边界

PDF P0 只提供三类观察操作：

1. `read_pdf`：PDFKit 提取已有文字和基础 metadata。
2. `document_ocr`：扫描件或 image-only PDF 的显式 OCR。
3. `document_render`：指定页面直接导出 PNG。

以下全部不注册：

- page extract/delete/reorder/rotate/crop；
- merge/split；
- watermark/stamp；
- form fill；
- annotation add/remove；
- redaction/secure deletion；
- 任意正文、图片或 content-stream 修改。

这是一项产品范围选择，不代表 pdfcpu 没有任何页面类能力。若以后重新加入 PDF 结构操作，应优先复核 pdfcpu 等成熟开源实现，而不是用 PDFKit 或 Swift 自写。但必须另行冻结 exact operation、唯一 writer 和验证 corpus。

`pdfcpu` 在本期只做：

- 对新导出的 PDF 执行显式 strict 结构验证；
- 必要时提供只读 `info` 诊断，不向模型暴露宽泛的编辑命令。

`pdfcpu validate` 只能证明其检查范围内的 PDF 结构，不能证明视觉正确、内容语义保真或敏感内容已删除。PDFKit reopen/render 也只是解析和渲染 smoke test。两者都不得被描述为安全脱敏验证器。

页面 PNG 使用 PDFKit bitmap draw，而不是把 `thumbnail` 当作精确 DPI 接口。实现必须固定：

- page range；
- CropBox/MediaBox 选择；
- page rotation；
- 白色或透明背景；
- annotation 是否可见；
- scale/DPI、单页像素上限、总像素和总字节上限；
- 输出 PNG MIME、digest、width、height 和 page ordinal。

### 4.2 OCR 是显式操作

OCR 与“PDF 页面转图片”不是一回事：render 只生成像素；OCR 从像素识别文字。

固定行为：

- 普通 PDF 读取不自动启动 OCR；PDFKit 没有可用文字层时返回 `ocr_required`。
- 只有 `document_ocr` 才启动 OCR。
- OCR 固定使用 Docling 的 PDF pipeline，并显式选择 `TesseractCliOcrOptions`；Tesseract 是流水线必需组件，不是 Docling 失败后的 fallback。
- 固定 Tesseract absolute binary、tessdata、allowlisted languages 和 PSM；不得沿用 Docling 默认语言列表或自动 engine 选择。
- 显式关闭不需要的 table、formula、code enrichment 和远程模型下载；需要的 layout artifact 必须来自固定本地路径。
- 输出至少包含 page、text、block/bbox、confidence 和 engine/version。

Docling 默认 PDF 配置会打开 OCR 并使用 `OcrAutoOptions`，因此不得直接采用默认 `PdfPipelineOptions`。实际依赖应按所选 Docling PDF extra 的 closure 核查；其中的 `pypdfium2`/PDFium 是传递依赖，不是本方案的直接页面预览 backend。

首期 OCR 不给原 PDF 写隐藏文字层，也不生成 searchable PDF。若以后需要 `ocr_to_searchable_pdf`，作为新的 PDF 生成 operation 单独选择成熟后端和验收合同。

### 4.3 Office 原生编辑与视觉预览分离

DOCX、PPTX、XLSX 的事实源始终是原生格式：

```text
DOCX -> python-docx -> staged DOCX
PPTX -> python-pptx -> staged PPTX
XLSX -> openpyxl -> staged XLSX -> LibreOffice Calc recalc + save
```

静态预览链固定为：

```text
validated staged Office file
  -> LibreOffice 导出临时 PDF
  -> pdfcpu strict validate + PDFKit reopen
  -> PDFKit 页面 PNG
```

临时 PDF 不反向写回 Office，也不是 Office 文档事实源。只有用户调用 `document_export_pdf` 时，PDF 才作为最终目标提交。

支持范围必须按实际公开 API 枚举，不能写成格式整体“任意编辑”：

- DOCX：常见 section、paragraph、run、style、table、image、header/footer；宏、OLE、ActiveX、SmartArt、完整修订历史和未知 OOXML part 不承诺无损往返。
- PPTX：已证明的 slide add/access、shape、text frame、image、table 和受支持 chart API；不承诺 slide delete/reorder/clone、动画、复杂 SmartArt、嵌入对象、宏和任意 layout/theme 重写。
- XLSX：sheet/range/cell、公式表达式、style、table、named range 和受支持 chart 类型；`openpyxl` 不计算公式，pivot cache、外部连接、不支持函数和厂商扩展必须拒绝或返回精确 warning。

### 4.4 XLSX 重算和保存合同

固定写入链是：

```text
openpyxl 修改 staged XLSX
  -> LibreOffice Calc 以隔离 profile 打开
  -> UNO XCalculatable.calculateAll()
  -> 以固定 XLSX filter 保存 staged XLSX
  -> openpyxl reopen 做语义验证
  -> LibreOffice 导出临时 PDF 做静态预览
  -> 全部通过后原子提交
```

不能只调用 `--convert-to` 就声称最终 XLSX 的 cached values 已刷新。

接受以下结果：

- LibreOffice 可能重排或重写 ZIP parts、cached formula values、style serialization 和 metadata；
- 最终 XLSX 是 LibreOffice round-trip 文件，不要求 byte-identical；
- 模型请求的单元格、公式和样式变更仍由 `openpyxl` 表达，但最终序列化可由 LibreOffice 重写。

验证以 sheet/cell/formula/value/style/关键对象语义断言为准，不比较整个 XLSX ZIP bytes。宏、外部连接、未知 pivot/vendor extension 默认不进入无警告写入链。

### 4.5 HTML 和 EPUB

HTML 使用 `lxml` 做 DOM 操作。selector 首期固定为 XPath；如果以后接受 CSS selector，必须显式锁定并审计 `cssselect`，不能假定 `lxml` 自己完整实现 CSS 选择器。

WKWebView 只加载工作区本地资源；网络、远程字体、远程图片和业务脚本默认关闭。WKWebView load/render 是视觉 smoke test，不是 HTML 标准合规证明。

EPUB 使用 rbook 已证明的 EPUB2/3 高层 API 子集，章节 XHTML 可走 `lxml`。导航只承诺 ToC/guide/landmarks/生成导航子集，不承诺任意 nav XHTML 无损重写。rbook 当前仍是需要真实 round-trip corpus 验收的候选，不因已有 checkout 就称为完全成熟。

`epub.js` 只负责本地渲染，EPUBCheck 只负责 conformance。必须采用固定正式 release artifact，不能把开发 snapshot 当成发行基线；Java runtime 和发行闭包留给后续 runtime-distribution 任务。

EPUB→PDF 是本报告中唯一仍带实现 gate 的格式链。`epub.js` 是阅读渲染组件，只有真实整本 corpus 证明它能稳定加载完整 spine、字体和本地资源，并由 WKWebView 打印全部章节而不是当前可见章节后，才可把该 route 注册为 `supported`。若证明失败，必须先审计并选定一个许可证可接受、已经能完成整本 EPUB→PDF 的成熟开源后端；不得在 Intatis 中自行实现章节拼接、分页或 PDF 合并算法。

## 5. “Structured runner”只是固定命令连接器

这里的 runner 不是服务、插件系统或第二个 agent。它就是模型工具和固定本地程序之间的受控调用层。

模型提交：

```json
{
  "operation": "export_pdf",
  "format": "docx",
  "input_path": "reports/input.docx",
  "output_path": "reports/output.pdf"
}
```

Swift 把它解析成 host-owned invocation：

```text
backend = libreoffice
route = writer.export_pdf
executable = manifest 中固定绝对路径
arguments = host 生成的参数数组
stdin/stdout = 版本化 JSON envelope
```

模型不能提供 executable、command string 或额外环境变量。

当前 `StructuredProcessShellRunner` 可复用 workspace allow-list、Seatbelt/bwrap、断网、timeout/cancel、环境清洗和进程树清理，但它目前仍接受整段命令并通过 `/bin/sh -c` 运行。因此本期要在它之上增加很窄的 `DocumentBackendInvocation/Runner`，或直接像现有 browser typed runner 一样接受固定 invocation。

同时必须修正一个现有边界：当前默认 8 MiB `maximumOutputBytes` 还被转换为 `ulimit -f`，会同时限制后端生成的文档。文档 runner 必须分别限制：

- stdout/stderr/log bytes；
- 单个生成文件大小；
- 多输出总大小；
- 页面/像素/解压后内容预算。

这属于必要连接层，不是重建文档平台。

P0 使用 native Tool path，不新增 MCP server。

## 6. Staging、验证和提交

现有权限与进程底座可复用，但仓库目前没有一个可直接用于大文档 backend 输出的完整提交 helper。需要增加窄的 document staged-output commit：

```text
校验 source/destination、格式和 expected source digest
  -> 在目标同目录创建唯一 no-follow staging
  -> 固定 backend 只写 staging
  -> reopen/结构验证/operation postcondition/必要的 render smoke
  -> 计算 staging digest
  -> commit 前重新核对 source/destination identity 和 expected digest
  -> 单次原子 replace 或创建
  -> fsync 并读回 committed target，与 staging digest 核对
  -> 返回 changedFiles、digest、engine/version
```

规则：

- 默认不覆盖已存在目标。
- 只有显式 `replace_existing=true` 且 `expected_digest` 匹配时才允许替换。
- terminal commit 开始前发生失败、取消、timeout 或 backend crash 时，原目标必须 byte-identical。
- terminal commit 一旦开始，必须把取消延迟到 commit/read-back/reconciliation 得到结论之后；若 rename/fsync 后无法证明最终状态，返回 `commit_uncertain`，不得声称原目标未变，也不得自动进行第二次写入。
- `document_render` 必须接收显式 workspace `output_dir`，并按写入型工具授权。多页 PNG 与 manifest 作为一个新的输出目录整体提交，不接 ArtifactStore sink，也不得暴露部分成功的页面集合。
- validator 只按它真正证明的属性报告，不把 reopen/render 夸大为语义或视觉等价证明。

预览图片进入 ArtifactStore、provider request、replay 和 compaction 的协议属于独立多模态任务。本报告只冻结 renderer 输出的 PNG 与 metadata contract；不得在这里再造“文档专用图片上下文桥”。

## 7. 开源组件与开发环境盘点

当前 `/Users/vita/Vitemis/Intatis/OpenSource` 已有相关评估 checkout：

- `docling`
- `python-docx`
- `python-pptx`
- `pdfcpu`
- `pdfium`（评估 checkout，不等同于 Docling 实际采用的 `pypdfium2` 发行物）
- `tesseract`、`tessdata`
- `libreoffice-core`
- `rbook`
- `epub.js`
- `epubcheck`

仍需在集成前锁定：

- `openpyxl` 精确版本和来源；当前本地清单没有对应 checkout。
- `lxml` 精确版本和传递依赖；是否单独 checkout 按 provenance 需要决定。
- Docling OCR 实际采用的 extra、模型 artifact、`pypdfium2` wheel 和绑定的 PDFium revision。
- LibreOffice、Tesseract/tessdata、EPUBCheck 的开发/测试版本和可执行文件 hash。

本地 checkout 只代表候选源码存在，不代表已经集成、分发或通过许可证审计。每个实际采用项仍须按 `docs/OPEN_SOURCE_REUSE.md`：

1. 固定 tag/commit/release artifact；
2. 核对目标文件、根许可证、NOTICE、传递依赖和模型/数据资产；
3. 选择 dependency、external-runtime、vendored 或 derived 形式；
4. 记录 provenance，并在实际引入或分发时更新 NOTICE/ThirdPartyNotices；
5. 保持 PermissionEngine、Lease、PathConfinement、EventLog 和 iOS 边界不变。

LibreOffice 的使用、许可和最终分发方式必须单独核查。本报告只假设开发/测试环境能通过严格版本 preflight 找到它；不承诺当前 Intatis 安装包已经自带任何 document runtime。

## 8. 第一方工程量：按 Codex 工作包估算

以下只估算 Intatis connector/glue，不用人日表达：

| 本报告内第一方工作 | 估算 |
|---|---:|
| 权限拆分的 Swift 工具入口、strict schema、operation matrix、路径和 PermissionIntent | 450–750 行 |
| typed backend invocation、JSON envelope、timeout/cancel 接线及输出限制修正 | 300–550 行 |
| staging、格式验证和原子提交 helper | 180–320 行 |
| Office/HTML Python worker 与薄 adapter | 900–1,500 行 |
| EPUB/rbook helper | 200–400 行 |
| PDFKit native read/render、显式 OCR、pdfcpu validation 和文档→PDF connector | 250–500 行 |
| backend preflight/version reporting，不含安装或打包 | 50–100 行 |
| **产品 connector/glue 合计** | **约 2,300–4,100 行** |
| 权限、无 fallback、OCR、写入完整性和格式合同测试 | **约 1,500–2,700 行** |

对 Codex 来说，这是一个中等偏大的实现目标，适合拆成 4–5 个相互可验收的修改包：

1. 工具拆分、typed runner、staging/commit；
2. PDFKit read/render、显式 OCR、pdfcpu validation；
3. Office worker、LibreOffice 导出与 XLSX recalc/save；
4. HTML/EPUB create/edit/export；
5. corpus、权限、安全、取消和无兜底回归。

第一包完成后，PDF/OCR 与 Office adapter 可以并行。它不适合做成一个无法审阅的大 patch，但不需要再开展 PDF 编辑 backend 研究。

以上估算不包括：

- 第三方源码和二进制；
- runtime 下载、双架构打包、签名、公证和 clean-machine 安装；
- 图片进入模型上下文的 provider/EventLog/replay/compaction 改造；
- 真实 corpus 文件的搜集与授权；
- 未来 PDF mutation/searchable PDF；
- iOS 产品能力。

行数是防止重造解析器和平台的警戒线，不是牺牲正确性的硬上限。明显超出时先检查是否正在实现开源组件已经具备的算法、扩大 operation 范围，或误把另案平台工作计入本报告。

## 9. 必须通过的测试

1. `document_write` 和 `document_export_pdf` 对 PDF 输入返回 `unsupported_operation`；生产 registry 不出现任何 PDF mutation operation。
2. `read_pdf` 只走 PDFKit，不启动 Docling、Tesseract 或 shell。
3. 无文字层 PDF 的普通读取返回 `ocr_required`，不得自动 OCR。
4. `document_ocr` 必须报告固定 Docling + Tesseract engine chain；缺组件或非零退出明确失败，不换 OCR 引擎。
5. OCR 测试断言 binary、tessdata、language、PSM 和本地 artifacts 路径均为 host 冻结值，且断网。
6. PDF 页面 PNG 固定 page box、rotation、background、annotation 策略、像素预算、MIME、digest 和 ordinal。
7. `pdfcpu` 只以显式 strict validation/info 身份出现；不得调用 annotation、redaction、page mutation、form 或 watermark 命令。
8. DOCX/PPTX/XLSX 普通 read 分别只启动 `python-docx`、`python-pptx`、`openpyxl`；不得调用 Docling 代读。
9. LibreOffice 缺失时 Office render/export 明确失败；不得只返回文本或静默省略视觉步骤。
10. XLSX 写入测试证明固定执行 `openpyxl edit -> Calc calculateAll -> save XLSX -> reopen`；以语义断言验证公式、值、样式和关键对象，不比较 ZIP bytes。
11. Office edit 的最终输出保持原生格式，临时 PDF 不参与回写。
12. HTML 远程 URL、字体、图片和网络请求被拒绝；selector 零命中或多命中按 schema 失败。
13. EPUBCheck 拒绝 staged EPUB 时不得提交；rbook round-trip 只验收声明的 API 子集；EPUB→PDF 必须证明完整 spine 而非单章渲染，gate 通过前 route 不得注册为 supported。
14. terminal commit 前任一 backend 写入失败、验证失败、取消或 timeout 后，目标文件保持原样；commit 已开始时必须完成 read-back/reconciliation，无法证明则返回 `commit_uncertain` 且不自动重写。
15. 模型不能注入 backend、binary path、command、environment、network URL 或临时目录。
16. 日志上限和生成文件上限相互独立，大于 8 MiB 的合法文档不会仅因 stdout cap 被 `ulimit -f` 截断。
17. 每个工具在 ToolRegistry、CapabilityLease、WorkspaceLease、PermissionIntent 和 touched paths 上都与精确权限分组一致。
18. 搜索生产文档执行代码，不应出现 backend 遍历、`fallback`、`best_effort` 或失败后第二实现 retry。
19. renderer 能稳定生成完整页面 PNG 集及 metadata；本测试不冒充“模型已收到图片”的多模态验收。
20. iOS target 不链接 IntatisTools、document runtime 或本地 Agent 执行能力。
21. 生产目录不再暴露旧 `edit_pdf_pages` 或带 `backend=auto` 的旧 `read_document`；`read_pdf` 不再建议隐式 auto OCR，legacy capability 不能进入 live lease。

## 10. 单一完成标准

本报告范围完成时必须同时满足：

- 模型目录按权限暴露拆分后的文档工具，而不是一个万能 `document` descriptor；
- 旧 `edit_pdf_pages` 和自动 fallback `read_document` 已从生产 registry/lease 下架或被固定实现替换，不能绕过新合同；
- PDF 只有 native read、显式 OCR 和页面 PNG，任何 PDF mutation 均明确不支持；
- DOCX/PPTX/XLSX/HTML/EPUB 的声明子集使用唯一成熟 backend 读写；
- DOCX/PPTX/XLSX/HTML 能通过固定链导出新 PDF；EPUB 只有在 full-spine corpus gate 通过，或先选定并验证另一个成熟固定后端后，才可计入完整完成；
- XLSX 经 LibreOffice Calc `calculateAll()` 和 save 后再提交，并接受合法 OOXML 重写；
- 所有写入都经过 staged output、精确验证和原子提交；
- runner 只接受 host-owned typed invocation，不接受模型 shell command；
- 组件缺失或失败时明确失败，没有自动后端切换；
- 页面 PNG 和 metadata 已生成；模型上下文传递由独立多模态方案验收；
- 开发/测试 backend 的版本可报告，runtime 分发没有被误写为已经解决；
- 实际采用的开源版本、许可证、来源和传递依赖可追溯；
- 第一方实现保持在薄连接层，不重写 parser、renderer、OCR、formula 或 serializer。

达到这些条件就结束，不顺手扩展成通用文档平台。

## 11. 本报告核查过的本地依据

- `Packages/IntatisTools/Sources/DocumentMediaTools.swift`
  - 当前 `read_document` 默认 `auto`，存在 Docling→MarkItDown fallback；
  - 当前 `edit_pdf_pages` 直接写最终路径，不能作为 staged commit 先例。
- `Packages/IntatisTools/Sources/ShellGit.swift`
  - 当前 structured process 底座仍通过 `/bin/sh -c` 接收命令字符串；
  - 默认 output cap 同时进入 `ulimit -f`；
  - 当前 document runtime 是 optional/user-managed，Intatis 不负责安装。
- `Packages/IntatisTools/Sources/ToolProtocol.swift`
  - `ToolDescriptor.sideEffect` 和 authorization snapshot 是静态合同；
  - `ToolContext` 当前没有可直接复用的 ArtifactStore sink。
- `Package.swift`
  - `IntatisTools` 当前不依赖 `IntatisArtifacts`，图片持久化不能在本报告里假定已经接通。
- `OpenSource/pdfcpu`
  - stock CLI annotations 只有 list/remove；没有 secure redaction apply 命令；
  - 本报告因此删除所有 PDF mutation claim，只保留 strict validation/info。
- `OpenSource/docling/docling/datamodel/pipeline_options.py`
  - 默认 `do_ocr=true` 且 `ocr_options=OcrAutoOptions()`；
  - 存在可固定 binary/tessdata/language/PSM 的 `TesseractCliOcrOptions`。
- `OpenSource/libreoffice-core/offapi/com/sun/star/sheet/XCalculatable.idl`
  - `calculateAll()` 明确定义为重算全部单元格；
  - 保存 staged XLSX 仍需经 UNO storage API 和固定 filter 实现与测试。
- `OpenSource/python-docx`、`python-pptx`、`rbook`、`epub.js`、`epubcheck`
  - 只按公开 API 已证明的操作子集列入，不把仓库存在等同于任意编辑能力。

## 12. 本轮状态

本轮只修订本报告，没有修改产品源码、配置、测试、项目既有说明文档或 `OpenSource/` checkout；没有运行构建或测试。
