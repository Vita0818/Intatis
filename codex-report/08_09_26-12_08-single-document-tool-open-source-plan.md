# Intatis 最小文档工具组定稿：成熟后端，最薄连接层

日期：2026-08-09

状态：`IMPLEMENTED / DEVELOPMENT RUNTIME VERIFIED / DISTRIBUTION & CORPUS RELEASE GATES OPEN`

面向读者：后续负责验证、打包和维护的 Codex / Intatis 维护者

范围：

- PDF：读取已有文字、显式 OCR、页面直接导出 PNG 预览、验证转换生成的 PDF；
- DOCX、PPTX、XLSX、HTML：读取、常见创建与编辑、静态预览、导出 PDF；
- EPUB：读取和声明子集创建/编辑；当前不注册 EPUB 渲染或导出 PDF；
- 不支持任何以 PDF 为输入的修改操作。

> 方案已经收口。Intatis 不实现文档解析器、排版引擎、OCR 引擎、Office 渲染器或 PDF 内容编辑器，只把经过能力核实的成熟组件接到现有权限和工作区边界上。组件缺失或失败时明确失败，不自动切换后端。

## 0. 最终决定

本报告冻结以下决定：

1. **PDF 编辑整体后置。** 不支持正文编辑、批注、表单修改、合并、拆分、抽页、删页、重排、旋转、裁剪、水印、遮盖或脱敏。即使某个候选库能做其中一部分，本期也不注册这些 operation。
2. **PDF 观察能力必须具备。** 支持读取已有文字、显式 OCR，以及把指定页面直接渲染成 PNG。
3. **文档转 PDF 必须具备。** DOCX、PPTX、XLSX、HTML 使用唯一固定导出链。EPUB→PDF 不以未证明的 `epub.js`/WKWebView 路线冒充完成：full-spine corpus gate 通过或另一个成熟固定后端经审计前，该格式不进入 render/export schema。生成新的 PDF 不等于编辑输入 PDF。
4. **工具按权限边界拆分。** 不再把读取、执行、写入全部塞进一个静态 `document` descriptor。
5. **XLSX 接受 LibreOffice 重写。** `openpyxl` 表达结构修改，LibreOffice Calc round-trip/save staged XLSX，再由 formula + data-only cache gate 决定是否接受；最终文件可能是 LibreOffice 重写结果。
6. **runtime 分发另案。** 本报告假定开发和测试环境已预置固定版本的后端；不设计下载器、安装器、App 内打包、双架构闭包、签名或公证。
7. **图片进入模型上下文另案。** 本报告负责可靠生成页面 PNG 及其元数据，不重复设计 provider、EventLog、replay 和 compaction 的多模态协议。相关平台问题见 `08_09_26-13_42-durable-multimodal-context-handoff.md`。
8. **成熟组件优先。** 只写 schema、权限和路径校验、固定调用、错误映射、staging、验证及原子提交；已有成熟实现的算法不在 Intatis 内重写。

在这些边界下，没有阻止源码实现的架构 blocker。当前连接层、权限、事务和固定后端源码已经落地；尚未完成的是被本报告明确排除的 runtime 分发，以及依赖真实制品/样本的 release gate，不应把二者混写成源码未实现。

### 0.1 本次实现收口

当前源码状态如下：

- 六个 exact 工具已进入 production registry：`read_pdf`、`document_read`、`document_ocr`、`document_render`、`document_export_pdf`、`document_write`；旧自动 fallback/PDF mutation/reconstruct 入口已下架，legacy capability 只保留解码。
- PDF 仅实现 native text read、显式 OCR 和页面 PNG；生产 schema 中没有 PDF mutation。
- DOCX/PPTX/XLSX/HTML 使用固定 Python/LibreOffice/WKWebView 链；EPUB 使用仓内 pinned rbook Rust helper source 读写，并要求 EPUBCheck。EPUB render/export 现在是 schema-level `unsupported_operation`，不是运行到一半再降级。
- process-backed observation 与写入 capability 已拆分。read-only worker 可获得 `read_pdf`、`document_read`、`document_ocr`；后两项必须是 exact `structured_read_only` intent，不能借此获得工作区写入、网络或通用 shell。render/export/write 只向 read-write worker/coordinator 签发。
- fixed backend runner、独立日志/生成物预算、辅助资产冻结与重验、owner-only staging、目标父目录 identity 固定、后置条件验证和原子提交均已实现。
- runtime 缺失、版本不符或未满足 corpus gate 时 typed fail closed；当前源码没有下载器、自动安装或备用 backend。

### 0.2 2026-08-11 LibreOffice 实机验收更新

本节覆盖本报告后文 2026-08-09 的开发机盘点，但不改变“runtime 分发另案”的产品决定：

- 用户 Intatis runtime 已换成官方 Apple Silicon LibreOfficeDev 26.8.0.0.beta1，固定路径为
  `~/Library/Application Support/Intatis/document-runtime/libreoffice/26.8.0.0.beta1/LibreOffice.app`。
  官方 DMG 为 298,129,546 bytes，SHA-256
  `a56a5af102c78c294b3da48154958ecd9fa52d357589305c54e6e215ce611900`；DMG 内建校验、官方 detached
  PGP signature、宿主严格 codesign 与 Gatekeeper 公证验收均通过；
- 先前的无 Seatbelt 诊断运行曾让 LibreOffice 内置 Python 改写 App 包内已签名 `.pyc`，造成一次真实
  sealed-resource failure。该副本已移入废纸篓并从只读官方 DMG 重装；干净副本在完整 Intatis
  smoke 前后均保持 `valid on disk` / `Notarized Developer ID`；
- LibreOffice SingleOffice IPC 不能靠普通 process environment 设置 `OSL_SOCKET_PATH`，也不能放在
  会超出 Unix socket 长度上限的长 Darwin temp root。fixed runner 现在建立每调用 current-UID
  `0700` 的 `/private/tmp/intatis-lo-<12 hex>`，以 `-env:OSL_SOCKET_PATH=...` 传入 bootstrap，Seatbelt
  仅放行该目录和 exact `OSL_PIPE_*` 本地 Unix socket，继续拒绝 IP 网络及其他 socket，并在结束后清理；
- 真实 opt-in core smoke 已通过 DOCX、PPTX、XLSX 三格式。覆盖 write/read、LibreOffice preview/export、
  PDF read/render，以及 XLSX Calc round-trip、公式文本保留与 data-only cache 值 `4`。旧 26.2.4
  runtime 已按用户授权移入废纸篓；
- 这些结果关闭的是当前 Apple Silicon 开发机的 LibreOffice 可用性 gate，不代表 universal runtime、App
  内打包、NOTICE/许可证、Developer ID 重签、公证或 clean-machine corpus/distribution closure 已完成。

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

旧生产入口的迁移结果：

- `edit_pdf_pages` 已从 standard/Code/Cowork 生产 registry 下架，fresh lease 不再授予对应 PDF 编辑 capability；历史 decoder 不会映射为 model-visible tool。
- 带 `backend=auto` 和 Docling→MarkItDown fallback 的旧 `read_document` 已从生产目录下架，不与新工具形成隐式备用路线。
- `read_pdf` 对 image-only PDF 返回 typed `ocr_required`，只允许用户或模型随后显式调用 `document_ocr`。
- 旧 capability raw value 仍可随历史 EventLog/durable lease 解码和恢复，但 registry 没有映射，因而不能形成 live tool authority；fresh factory 永不签发。这里不要求破坏旧日志或在内存反序列化时丢弃兼容字段。

## 4. 固定组件与 operation 映射

| 格式 | 原生读取 | 创建与编辑 | 导出 PDF | 页面预览 | 固定验证 |
|---|---|---|---|---|---|
| PDF | PDFKit；只读已有文字和 metadata | **不支持** | 不适用；只验证其他格式生成的新 PDF | PDFKit 直接 bitmap draw → PNG | `pdfcpu validate` 显式 strict 模式 + PDFKit reopen/render smoke |
| DOCX | `python-docx` | `python-docx` 的常见高层 API 子集 | LibreOffice Writer | LibreOffice 临时 PDF → PDFKit PNG | `python-docx` reopen + LibreOffice export + PDF 输出验证 |
| PPTX | `python-pptx` | `python-pptx` 已证明的 shape/text/image/table/chart 子集 | LibreOffice Impress | LibreOffice 临时 PDF → PDFKit PNG | `python-pptx` reopen + LibreOffice export + PDF 输出验证 |
| XLSX | `openpyxl`；大表必须指定范围 | `openpyxl` 修改 → LibreOffice Calc round-trip/save + cache gate | LibreOffice Calc | LibreOffice 临时 PDF → PDFKit PNG | `openpyxl` formula/data-only reopen + Calc round-trip 语义断言 + PDF 输出验证 |
| HTML | `lxml` | `lxml` DOM/attribute/text/style 节点操作 | WKWebView print-to-PDF，网络和远程资源关闭 | WKWebView PDF → PDFKit PNG | `lxml` parse + WKWebView load/render smoke + PDF 输出验证 |
| EPUB | pinned `rbook` helper | metadata/resource/spine/ToC 声明子集 | **不支持（当前 schema 不注册）** | **不支持（当前 schema 不注册）** | helper reopen/postcondition + 固定 release EPUBCheck；未来 render/export 另需 full-spine gate |

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
XLSX -> openpyxl -> staged XLSX -> LibreOffice Calc round-trip/save + cache gate
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
  -> LibreOffice Calc 以隔离 profile 做固定 XLSX round-trip/save
  -> openpyxl 以 formula view reopen 做语义验证
  -> openpyxl 以 data-only view 验证目标公式存在可读非公式缓存
  -> LibreOffice 导出临时 PDF 做静态预览
  -> 全部通过后原子提交
```

不能只凭 `--convert-to` 退出成功就声称最终 XLSX 的 cached values 已刷新。本实现选择 `soffice`
自身的固定 Calc XLSX filter，而不直接启动带 macOS parent launch constraint 的 bundled Python；只有
round-trip 后 exact 公式文本仍在、且 data-only 视图得到非 `nil`、非 formula 的可读缓存时才继续。
该 verifier 不自行计算公式，也不声称缓存值在数学上正确。

接受以下结果：

- LibreOffice 可能重排或重写 ZIP parts、cached formula values、style serialization 和 metadata；
- 最终 XLSX 是 LibreOffice round-trip 文件，不要求 byte-identical；
- 模型请求的单元格、公式和样式变更仍由 `openpyxl` 表达，但最终序列化可由 LibreOffice 重写。

验证以 sheet/cell/formula/value/style/关键对象语义断言为准，不比较整个 XLSX ZIP bytes。宏、外部连接、未知 pivot/vendor extension 默认不进入无警告写入链。

### 4.5 HTML 和 EPUB

HTML 使用 `lxml` 做 DOM 操作。selector 首期固定为 XPath；如果以后接受 CSS selector，必须显式锁定并审计 `cssselect`，不能假定 `lxml` 自己完整实现 CSS 选择器。

WKWebView 只加载工作区本地资源；网络、远程字体、远程图片和业务脚本默认关闭。WKWebView load/render 是视觉 smoke test，不是 HTML 标准合规证明。

EPUB 使用仓内 `Packages/IntatisTools/Runtime/rbook-helper` 对 rbook 0.7.10 做固定 `json-v1` 连接。当前公开子集是 bounded read，以及 metadata/resource/spine/ToC 的 create/edit；不承诺 remove/reorder、任意 nav XHTML 或通用 EPUB serializer。helper 自身做 ZIP 预算、路径/重复项/加密/非普通成员检查、写后 reopen 和 operation postcondition，最终 conformance 仍由固定正式 EPUBCheck 负责。

EPUB→PDF/PNG 当前不属于 supported surface。`epub.js` 仍可作为未来候选研究材料，但不会被当前工具偷偷调用。只有真实整本 corpus 证明固定路线能稳定加载完整 spine、字体和本地资源并输出全部章节后，才可重新加入 schema；若证明失败，先审计另一个成熟后端，不在 Intatis 中自行实现章节拼接、分页或 PDF 合并算法。

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

实现已经增加窄的 `DocumentBackendInvocation` / `DocumentBackendProcessRunner`。模型只提交文档 tool schema；宿主生成固定 executable、argv、环境和 JSON request。macOS 使用 exact Seatbelt roots，Linux 使用 exact/empty bwrap roots，缺少可信 sandbox 时 fail closed，不通过通用 shell 解释 model-authored command。

日志和生成物预算已经拆开：

- stdout/stderr/log bytes；
- 单个生成文件大小；
- 多输出总大小与 entry 数；
- 页面/像素预算；OOXML/EPUB 在语义后端入口另做 ZIP entry、单项/总展开量、压缩比、加密、重复名、穿越和非普通成员检查。

这属于必要连接层，不是重建文档平台。

P0 使用 native Tool path，不新增 MCP server。

## 6. Staging、验证和提交

仓库现已增加窄的 document staged-output commit：

```text
校验 source/destination、辅助资产、格式和 expected source digest
  -> 在目标同目录创建唯一 no-follow staging
  -> 固定 backend 只写 staging
  -> reopen/结构验证/operation postcondition/必要的 render smoke
  -> 计算 staging digest
  -> backend 前及 commit lock 内重核 source/destination/辅助资产 identity 和 digest
  -> 固定目标父目录 fd/identity，no-follow 单次原子 replace 或创建
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
- 辅助图片/HTML local assets 不是 live path 旁路：先冻结 regular/single-link 文件的 digest、size、dev、inode，backend 前与 commit lock 内重验；授权后替换、symlink 或 hardlink 均 fail closed。

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

本次核对的开发机状态：

- 用户管理的 document runtime 可导入 Docling 2.117.0、python-docx 1.2.0、python-pptx 1.0.2、openpyxl 3.1.5、lxml 6.1.1；它不是 App 分发闭包。
- LibreOffice 26.2.5.2 与 Tesseract 5.5.3 / Leptonica 1.87.0 可发现。
- 用户 runtime 尚无固定 Docling model artifact，也未安装 `intatis-rbook-helper`、`pdfcpu` 或正式 EPUBCheck wrapper/artifact；对应真实 route 当前应返回 `backend_missing`，不能把 source checkout 或版本命令成功当作可用能力。
- `Packages/IntatisTools/Runtime/rbook-helper` 已有 exact Cargo pins/lock、测试与 provenance；这证明 source/build closure，不等于 universal signed binary 已进入产品。

发行前仍需锁定 Docling models 与 `pypdfium2`/PDFium、LibreOffice/Tesseract/tessdata、pdfcpu、EPUBCheck、Python/wheel 原生闭包的实际制品 hash、架构、许可证和签名状态。

本地 checkout 只代表候选源码存在，不代表已经集成、分发或通过许可证审计。每个实际采用项仍须按 `docs/OPEN_SOURCE_REUSE.md`：

1. 固定 tag/commit/release artifact；
2. 核对目标文件、根许可证、NOTICE、传递依赖和模型/数据资产；
3. 选择 dependency、external-runtime、vendored 或 derived 形式；
4. 记录 provenance，并在实际引入或分发时更新 NOTICE/ThirdPartyNotices；
5. 保持 PermissionEngine、Lease、PathConfinement、EventLog 和 iOS 边界不变。

LibreOffice 的使用、许可和最终分发方式必须单独核查。本报告只假设开发/测试环境能通过严格版本 preflight 找到它；不承诺当前 Intatis 安装包已经自带任何 document runtime。

## 8. 第一方工程量：原估算与实际判断

下表是编码前对 Intatis connector/glue 的工作包估算，不用人日表达：

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
3. Office worker、LibreOffice 导出与 XLSX round-trip/save + cache gate；
4. HTML create/edit/export 与 EPUB read/write；
5. corpus、权限、安全、取消和无兜底回归。

实现后的判断仍是“中等偏大”，但主要工作已经完成。实际安全闭包比原表更大：除了格式 adapter，还必须处理辅助资产 TOCTOU、父目录替换、运行期聚合输出预算、OOXML/EPUB ZIP 预算、last-write-wins 后置条件、XLSX 外链/pivot/vendor-extension 拒绝和 read-only process 权限形状。这些不是重写文档算法，而是让薄连接层符合 Intatis 既有安全/持久化合同；因此不应为了命中原行数估算而删除。

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
7. `pdfcpu` 只以显式 `--conf disable --offline validate --mode strict` validation/info 身份出现；不得调用 annotation、redaction、page mutation、form 或 watermark 命令。
8. DOCX/PPTX/XLSX 普通 read 分别只启动 `python-docx`、`python-pptx`、`openpyxl`；不得调用 Docling 代读。
9. LibreOffice 缺失时 Office render/export 明确失败；不得只返回文本或静默省略视觉步骤。
10. XLSX 写入测试证明固定执行 `openpyxl edit -> Calc XLSX round-trip/save -> formula + data-only reopen`；以语义断言验证公式、可读缓存、样式和关键对象，不比较 ZIP bytes，也不把转换退出码冒充重算证明。
11. Office edit 的最终输出保持原生格式，临时 PDF 不参与回写。
12. HTML 远程 URL、字体、图片和网络请求被拒绝；selector 零命中或多命中按 schema 失败。
13. EPUBCheck 拒绝 staged EPUB 时不得提交；rbook round-trip 只验收声明的 API 子集；EPUB→PDF 必须证明完整 spine 而非单章渲染，gate 通过前 route 不得注册为 supported。
14. terminal commit 前任一 backend 写入失败、验证失败、取消或 timeout 后，目标文件保持原样；commit 已开始时必须完成 read-back/reconciliation，无法证明则返回 `commit_uncertain` 且不自动重写。
15. 模型不能注入 backend、binary path、command、environment、network URL 或临时目录。
16. 日志上限和生成文件上限相互独立，大于 8 MiB 的合法文档不会仅因 stdout cap 被 `ulimit -f` 截断。
17. 每个工具在 ToolRegistry、CapabilityLease、WorkspaceLease、PermissionIntent 和 touched paths 上都与精确权限分组一致。
18. 生产文档执行代码不得遍历候选 backend、使用 `best_effort` 语义，或在失败后切换到第二个 semantic backend/retry；辅助几何计算等局部实现细节不属于后端兜底。
19. renderer 能稳定生成完整页面 PNG 集及 metadata；本测试不冒充“模型已收到图片”的多模态验收。
20. iOS target 不链接 IntatisTools、document runtime 或本地 Agent 执行能力。
21. 生产目录不再暴露旧 `edit_pdf_pages` 或带 `backend=auto` 的旧 `read_document`；`read_pdf` 不再建议隐式 auto OCR；legacy capability 可以兼容解码，但不能映射为 live tool authority，fresh lease 不得签发。

本次源码验证已覆盖合同、registry/lease、PDF native render、staging/commit、Python writer/verifier、HTML WKWebView、固定 LibreOffice/pdfcpu argv、权限和 rbook helper。2026-08-09 的聚焦 suite 数量保留为历史证据；2026-08-11 当前工作树重新运行 `swift test --filter IntatisToolsTests` 退出 0，其中 DocumentToolContract 16/16、DocumentInfrastructure 12/12、DocumentPythonWriteBackend 20/20、DocumentFixedBackends 4/4，DocumentToolsIntegration 非 opt-in 项 11/11（3 个真实 runtime 项按设计跳过）。另以 opt-in 单独运行 LibreOffice core smoke 1/1，覆盖 DOCX/PPTX/XLSX 和公式缓存；真实 Docling/Tesseract OCR、pdfcpu validation、rbook/EPUBCheck 的既有本机 1/1 证据也已取得。仍开放的是 clean-machine、大样本 corpus 和发行闭包 gate，不能由 fake runner、开发机安装或 source test 代替。

## 10. 单一完成标准

源码范围完成时必须同时满足：

- 模型目录按权限暴露拆分后的文档工具，而不是一个万能 `document` descriptor；
- 旧 `edit_pdf_pages` 和自动 fallback `read_document` 已从生产 registry/lease 下架或被固定实现替换，不能绕过新合同；
- PDF 只有 native read、显式 OCR 和页面 PNG，任何 PDF mutation 均明确不支持；
- DOCX/PPTX/XLSX/HTML/EPUB 的声明子集各绑定唯一 backend；缺少实际 runtime 时 typed fail closed；
- DOCX/PPTX/XLSX/HTML 绑定固定导出链；EPUB render/export 在 full-spine gate 前明确不属于当前完成面；
- XLSX 经 LibreOffice Calc 固定 XLSX round-trip/save 和 formula + data-only cache gate 后再提交，并接受合法 OOXML 重写；
- 所有写入都经过 staged output、精确验证和原子提交；
- runner 只接受 host-owned typed invocation，不接受模型 shell command；
- 组件缺失或失败时明确失败，没有自动后端切换；
- 页面 PNG 和 metadata 已生成；模型上下文传递由独立多模态方案验收；
- 开发/测试 backend 的版本可报告，runtime 分发没有被误写为已经解决；
- 实际采用的开源版本、许可证、来源和传递依赖可追溯；
- 第一方实现保持在薄连接层，不重写 parser、renderer、OCR、formula 或 serializer。

当前源码已按上述边界收口。真正分发或在 clean machine 宣称 route 可用之前，仍必须补齐外部 runtime、正式制品、许可证/签名与真实 corpus gate；这些不会触发隐藏 fallback，也不改变当前 tool contract。达到这些条件就结束，不顺手扩展成通用文档平台。

## 11. 当前实现依据

- `DocumentToolContracts.swift` / `DocumentTools.swift`：六工具 strict schema、format/operation matrix、permission/touched paths、固定后端编排；PDF 和 EPUB render/export 边界在 decode/dispatch 前收窄。
- `DocumentMediaTools.swift` / `PDFNativeDocumentService.swift`：PDFKit native read、typed `ocr_required`、精确页面 PNG 与无 PDF mutation surface。
- `ShellGit.swift`：host-owned document invocation、exact WorkspaceLease、Seatbelt/bwrap、版本 preflight、断网、timeout/cancel、进程树清理，以及彼此独立的日志/生成物预算。
- `DocumentInfrastructure.swift`：source/destination/辅助资产 snapshot，owner-only staging，commit-lock CAS，父目录 identity 固定，file/directory 原子提交和 `commit_uncertain`。
- `DocumentPythonBackend.swift` / `DocumentFixedBackends.swift`：固定 Office/HTML/OCR JSON 路线、请求 operation 与宿主环境绑定、OOXML 预算和 preservation gate、LibreOffice safe-profile Calc XLSX round-trip/save、完整 pdfcpu strict argv 与 operation postcondition；XLSX cache 检查只证明目标公式保留且可读缓存存在，不声称数学正确。
- `HTMLDocumentPDFRenderer.swift`：HTML local assets 先受 allowlist/快照约束并内联到 stage，WKWebView 只读 stage root，网络/active content fail closed。
- `DocumentEPUBBackends.swift` / `Runtime/rbook-helper`：固定 rbook/EPUBCheck 连接、EPUB read/write 子集与 ZIP/reopen/postcondition；Cargo exact pins、依赖许可证和发行 gate 记录在 `ThirdPartyNotices/DocumentRBookHelper.md`。
- `Leases.swift` / `PermissionIntent.swift` / `DeterministicPolicyGate.swift` / `Orchestrator.swift`：五项 process capability 拆分、legacy decode-only、exact `structured_read_only` 观察权限和 worker 可见性。
- `OpenSource/pdfcpu`、Docling pipeline options、LibreOffice Calc filter/security schema 及各格式库公开 API 仍是能力边界的上游核查依据；checkout 不冒充已安装 runtime。

## 12. 本轮状态

本轮已经修改产品源码、测试、项目文档、NOTICE/ThirdPartyNotices，并新增 pinned rbook helper source；未修改 `OpenSource/` 研究 checkout。Swift 文档工具与权限相关 target/聚焦 XCTest、Rust locked check/test/fmt/clippy 均已执行。最新合并文档过滤器在当前工作树执行 69/69 通过；其余非文档测试结果只按实际运行记录表述，不把未执行的全仓 suite 冒充成功。

未完成且明确留给后续的事项：document runtime 的 App 内打包/安装器方案、双架构闭包、Intatis 发行物的 Developer ID 重签/公证、第三方 NOTICE/许可证闭包、clean-machine 验证，以及受授权的真实大样本 corpus。当前开发机已安装并验收的 LibreOffice、Docling model、pdfcpu、EPUBCheck 与 rbook helper 不能外推为发行完成。图片进入模型上下文仍由独立报告处理。
