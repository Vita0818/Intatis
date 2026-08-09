# Intatis 最小文档工具方案：固定开源后端，不做自动兜底

日期：2026-08-09

状态：`REVISED PROPOSAL / NO PRODUCT CODE CHANGED`

面向读者：后续负责实现的 Codex / Intatis 维护者

范围：PDF、DOCX、PPTX、XLSX、HTML、EPUB 的读取、渲染、创建和常见编辑

> 这不是“文档平台”、插件系统或宏大路线图。本方案只做一件事：把几个固定的成熟组件接到 Intatis 的一个薄工具上。组件不能工作时明确失败，不自动换后端。

## 0. 修正结论

上一版方案过度工程化，以下内容全部撤回：

- `DocumentService`/adapter registry 之类的通用框架；
- W0–W7 分期和 Document Pack 安装系统；
- 可替换 backend、MCP backend 和未来插件 ABI；
- 通用 Document IR；
- 为兼容所有后端而设计的大型能力协商层；
- 18k–30k 行的生产 P0 估算。

上一版虽然写了“不静默兜底”，但同时保留了 `format=auto`、等价后端选择和若干备用实现。这会给实际实现留下“主链失败后悄悄换一套”的空间，不符合要求。

修正后的方案只有这一条链路：

```text
Agent
  -> 一个 document 工具
  -> 一个固定 dispatch/switch
  -> 固定的开源库或固定命令
  -> 生成/修改文件
  -> 用固定验证器检查
  -> 成功提交，或者明确失败
```

没有运行时自动选后端，没有第二套实现，没有在线服务兜底，也不先建一个“将来什么都能装”的框架。

预计自研产品代码约 2.2k–4.0k 行；连同必要测试约 4.0k–7.2k 行。第三方源码、生成文件、fixture 和二进制不计入。这个估算覆盖六类格式的常见操作，不覆盖原生 Office/Acrobat 的全部高级功能。

## 1. 先把“兜底”定义清楚

### 1.1 禁止的行为

以下行为在新 `document` 工具中一律禁止：

1. Docling 失败后自动尝试 MarkItDown、Tesseract、PaddleOCR 或别的解析器。
2. LibreOffice 渲染失败后只返回抽取文本，并把任务标为成功。
3. `python-pptx`/`python-docx`/`openpyxl` 写入失败后改用另一套 OOXML 库重试。
4. 本地组件缺失时自动调用远程 API、浏览器网站或 MCP 服务。
5. 验证失败后仍保留输出文件并报告“基本成功”。
6. 捕获异常后返回空文本、空文档、占位图片或原文件副本。
7. 以 `auto`、`best_effort`、`compatible` 等名字隐藏后端切换。

### 1.2 允许的固定流水线不是兜底

一个操作可以要求多个组件顺序协作，但每个组件都有固定职责，缺一即失败。例如：

```text
DOCX render
  = LibreOffice 固定导出 PDF
  + PDFKit 固定渲染 PNG
```

LibreOffice 不是 PDFKit 的备用实现，PDFKit 也不是 LibreOffice 的备用实现；两者都是这个操作的必需步骤。任一步失败，整个操作失败。

### 1.3 失败合同

工具失败必须返回明确、可测试的错误，例如：

- `backend_missing`
- `backend_failed`
- `unsupported_operation`
- `unsupported_feature`
- `validation_failed`
- `render_failed`
- `image_delivery_unsupported`

结果中必须写出实际使用的组件和版本。一次调用只能出现预先规定的组件链，不能在日志中看到“先 A、再 B、最后 C 才成功”。

## 2. 当前代码里确实已有自动兜底

这不是假设。当前 `Packages/IntatisTools/Sources/DocumentMediaTools.swift` 中：

- `read_document` 默认把 `backend` 设为 `auto`；
- `auto` 先运行 Docling，失败后再运行 MarkItDown；
- `reconstruct_document_image` 同时提供 Docling、Marker、Tesseract 路线，其中包含明确的 `tesseract fallback` 文案。

所以答案是：当前文档工具代码里确实存在自动兜底。上一版报告没有把这个现状当成必须清除的约束，这是错误。

新 `document` 工具不能复用这段 `auto` 分支。实现时应同时做到：

- 新工具不接受 `backend` 参数；
- 新工具不接受 `auto`；
- 新生产工具目录只向模型暴露新的 `document` 入口；
- 旧工具即使暂时为历史代码保留，也不能成为新工具的隐式后备路径。

本报告只修改方案，没有修改上述源码。

### 2.1 当前能力与目标能力不能混写

当前 Intatis 产品还没有正式的原生 Office `document` 工具：

- `read_document` 主要把文档转换为 Markdown；
- `edit_pdf_pages` 只覆盖部分 PDF 页面操作；
- Code/Cowork 虽可通过 managed terminal 临时运行脚本，但这不是稳定的文档产品合同；
- 当前 Codex/Cowork 宿主提供的文档 Skills 和运行库也不等于 Intatis 已经具备这些能力，不能把宿主能力当成产品依赖。

本报告描述的是待实现目标。实现完成后，模型才会通过正式的 `document` 工具直接读取、创建和编辑 DOCX/PPTX/XLSX 等原生文件。

## 3. 最小结构

### 3.1 模型侧只有一个工具

工具名固定为：

```text
document
```

请求外层保持很小：

```json
{
  "operation": "read|render|create|edit|convert",
  "format": "pdf|docx|pptx|xlsx|html|epub",
  "input_path": "optional/workspace/path",
  "output_path": "optional/workspace/path",
  "arguments": {}
}
```

规则：

- `format` 必须显式填写，不提供 `auto`。
- `create` 不需要 `input_path`；其他操作按需要求。
- `create`、`edit`、`convert` 必须有 `output_path`。
- `arguments` 是格式专属结构，不发明跨格式万能语义。
- 模型不能选择 backend、二进制路径、命令、网络地址或临时目录。
- 格式扩展名、magic bytes 与 `format` 不一致时直接拒绝。

统一结果只包含必要信息：

```json
{
  "ok": true,
  "format": "docx",
  "operation": "edit",
  "engines": ["python-docx 1.x", "LibreOffice 2x.x"],
  "output_path": "paper/revised.docx",
  "artifacts": [],
  "changes": [],
  "warnings": []
}
```

失败时 `ok=false`，返回错误码、失败组件和受清洗的错误摘要；不返回“降级后结果”。

### 3.2 原生编辑与视觉预览是两条不同链路

Office 文件的读取、创建和编辑始终在原生格式上完成，不经过 PDF：

```text
DOCX -> python-docx 打开/修改 -> DOCX
PPTX -> python-pptx 打开/修改 -> PPTX
XLSX -> openpyxl 打开/修改 -> XLSX
```

PDF 只承担静态视觉预览：

```text
原生 Office staging 文件
  -> LibreOffice 临时导出 PDF
  -> PDFKit 渲染 PNG
  -> 模型检查分页、溢出、重叠和版式
```

硬约束：

- 临时 PDF 不是编辑中间格式，不是文档事实源，也不能反向写回 Office 文件。
- 临时 PDF 只存在于本次操作的临时目录；除非用户明确请求 `convert` 到 PDF，否则不作为最终输出提交。
- DOCX/PPTX/XLSX 的结构化内容和编辑定位仍来自各自原生库；模型可以依据预览发现版式问题，但后续修改必须使用原生对象 ID/选择器，不能把 PDF 反向导入或转换后写回。
- PPT 动画、视频和交互，以及 Excel 交互行为不会出现在 PDF 预览中；预览只验证静态布局。
- Excel 的公式值由 LibreOffice Calc 固定重算，但单元格和公式本身仍由 `openpyxl` 读写。

### 3.3 宿主只写一个薄入口

Swift 侧不新增 `DocumentService`、backend protocol、plugin registry 或 provider factory。只新增一个 `DocumentTool`，内部用普通 `switch (format, operation)` 选择固定执行路线。

伪代码足够表达实际结构：

```swift
switch (request.format, request.operation) {
case (.docx, .edit):
    runFixedDocumentWorker("docx.edit", request)
case (.pptx, .edit):
    runFixedDocumentWorker("pptx.edit", request)
case (.pdf, .edit):
    runFixedBinary("pdfcpu", fixedArguments(request))
default:
    throw unsupportedOperation
}
```

执行继续复用 Intatis 已有的：

- ToolRegistry/ToolContext；
- WorkspaceLease、CapabilityLease 和 PathConfinement；
- PermissionEngine 与 durable tool ticket；
- structured document runner 的超时、取消、断网和进程清理；
- ArtifactStore、changedFiles 和既有原子文件操作。

不要复制这些控制面，也不要在文档工具里再实现一套。

### 3.4 后端不是 MCP

P0 不新增文档 MCP server。

原因不是 MCP 不好，而是当前 Intatis 的本地 MCP stdio 在 macOS 禁止 server 再启动 LibreOffice、pdfcpu、EPUBCheck 等 helper；Linux local MCP workspace 又是只读。为了绕开这些限制再造 artifact broker、安装器和 trusted facade，会把一个薄工具重新做成大工程。

固定库和命令直接走现有 structured document runner。以后用户明确要求第三方扩展时再单独讨论 MCP；本方案不为它预留插件框架。

## 4. 固定组件表

每个操作只绑定下表规定的组件。这里列出多个组件时，它们是固定的不同职责或固定流水线，不是互相兜底。

| 格式 | 原生读取、创建与编辑 | 显式语义转换 | 视觉预览 | 写后验证 |
|---|---|---|---|---|
| PDF | Docling 读取；`pdfcpu` 负责页面、表单、批注、水印、合并拆分、裁剪、旋转和遮盖；富文本新建走固定 HTML→WKWebView PDF 路线 | Docling；需要 OCR 时显式启用固定 Tesseract 配置 | PDFKit | `pdfcpu validate` + PDFKit reopen |
| DOCX | `python-docx` | 只有明确请求转换为研究 Markdown/统一语义结构时才用 Docling | LibreOffice 临时 PDF→PDFKit PNG | `python-docx` reopen + LibreOffice export |
| PPTX | `python-pptx` | 只有明确请求转换为研究 Markdown/统一语义结构时才用 Docling | LibreOffice 临时 PDF→PDFKit PNG | `python-pptx` reopen + LibreOffice export |
| XLSX | `openpyxl`；大表读取范围必须显式给出 | 只有明确请求转换为研究 Markdown/统一语义结构时才用 Docling | LibreOffice Calc 临时 PDF→PDFKit PNG | `openpyxl` reopen + LibreOffice recalc/export |
| HTML | `lxml`；CSS/asset 只允许工作区本地资源 | 不另设默认转换后端 | WKWebView，脚本和网络关闭 | `lxml` parse + WKWebView load |
| EPUB | `rbook`；章节 XHTML 可复用 `lxml` | 不另设默认转换后端 | `epub.js` + WKWebView | EPUBCheck |

DOCX、PPTX、XLSX 必须作为同一个 Office 处理组实现：

- 同一个 Python worker；
- 同一套请求/响应、staging、错误和原子提交代码；
- 三个很薄的格式 adapter，分别映射段落、幻灯片对象和单元格；
- 同一个 LibreOffice→临时 PDF→PDFKit 视觉预览链；
- 同一种“原生库 reopen + LibreOffice 打开/导出”的验证模式。

三者的差异只来自文档对象模型。XLSX 额外需要 LibreOffice Calc 计算公式；这不构成另一套架构。

额外约束：

- Office 的普通 `read` 绝不启动 Docling：DOCX、PPTX、XLSX 分别固定使用 `python-docx`、`python-pptx`、`openpyxl`。
- Docling 只负责 PDF/OCR，以及用户显式请求的 Office→研究 Markdown/统一语义结构转换；不能成为原生 Office 读取失败后的备用路径。
- Docling 的 OCR provider 必须固定配置，不能使用会自动遍历多种 OCR 引擎的模式。
- LibreOffice 是 Office 渲染、旧格式转换和 Calc 重算的必需组件，不是“兼容性 fallback”。
- PDFKit/WKWebView 是已有 Apple 系统能力，不再引入 PDFium 或另一个浏览器引擎。
- 不接入 Open XML SDK、docx4j、Apache POI、PptxGenJS、PDFBox、qpdf、Calibre、Sigil 作为备用后端。
- MarkItDown 不进入新工具链。

## 5. 格式专属参数，不做万能 IR

外层只有一个工具，但 `arguments` 按格式分别定义。参数尽量贴近采用的开源库，以减少转换代码。

### PDF

支持的 operation 示例：

- `pages.extract|delete|reorder|rotate|crop`
- `merge`
- `watermark.add`
- `form.fill`
- `annotation.add`
- `redaction.apply`

不提供“查找任意段落并像 Word 一样重排 PDF 正文”。该请求返回 `unsupported_operation`。

### DOCX

普通 `read`、`create` 和 `edit` 都固定使用 `python-docx`。支持的对象包括 section、paragraph、run、style、table、image、header/footer。

只有用户明确请求把 DOCX 转成研究 Markdown/统一语义结构时，`convert` 才固定调用 Docling；`python-docx` 失败后不得调用 Docling 继续完成普通读取。

不承诺宏、OLE、ActiveX、SmartArt、完整修订历史和任意未知 OOXML part 无损往返。检测到明确不支持的输入特征时，在写入前返回 `unsupported_feature`。

### PPTX

普通 `read`、`create` 和 `edit` 都固定使用 `python-pptx`。支持的对象包括 slide、shape、text frame、image、table、chart、layout reference。

只有用户明确请求把 PPTX 转成研究 Markdown/统一语义结构时，`convert` 才固定调用 Docling；`python-pptx` 失败后不得调用 Docling 继续完成普通读取。

不承诺动画、复杂 SmartArt、嵌入对象、宏和所有主题扩展无损编辑。

### XLSX

普通 `read`、`create` 和 `edit` 都固定使用 `openpyxl`。支持 sheet、range、cell、formula、style、table、chart、named range。公式写入由 `openpyxl` 完成，重算固定交给 LibreOffice Calc。

只有用户明确请求把 XLSX 转成研究 Markdown/统一语义结构时，`convert` 才固定调用 Docling；`openpyxl` 失败后不得调用 Docling 继续完成普通读取。

不执行宏，不承诺所有 pivot cache、外部数据连接和厂商扩展。

### HTML

支持 DOM insert/replace/delete、attribute、text、stylesheet 和本地 asset。selector 必须在文档中精确命中；零命中或多命中时按请求约束失败，不能“猜一个最像的节点”。

脚本、远程字体、远程图片和网络请求默认禁用。

### EPUB

支持 metadata、manifest、spine、nav、chapter XHTML 和本地 asset。所有写入必须通过 EPUBCheck 才能提交。

不处理 DRM，也不承诺脚本型、媒体覆盖等高级 EPUB 的完整编辑。

## 6. 真正需要写的代码

| 自研部分 | 作用 | 估算 |
|---|---|---:|
| `DocumentTool.swift` | 一个 schema、参数校验、固定 dispatch、调用现有 runner、结果清洗 | 350–600 行 |
| Python document worker | 一套公共协议；三个 Office adapter；HTML adapter；显式 Docling 调用 | 900–1,600 行 |
| PDF 固定调用胶水 | Docling/PDFKit/pdfcpu/WKWebView 的固定操作映射 | 200–350 行 |
| rbook 小 helper | 把固定 JSON 操作映射到 rbook；不做通用 server | 250–450 行 |
| 固定 manifest/版本检查 | 精确模块、二进制、模型和版本；无安装器 | 100–150 行 |
| 窄的预览图回传桥 | 仅在当前 provider 路径无法直接复用现有 Artifact/图片附件时添加 | 300–600 行 |
| 产品代码合计 | 各行存在共享代码，不能机械相加；不含第三方源码 | **约 2,200–4,000 行** |
| 测试与小型 fixture driver | 格式操作、验证、无兜底断言、权限/路径回归 | 1,800–3,200 行 |
| 总计 | 不含第三方源码和 fixture 文件本身 | **约 4,000–7,200 行** |

Office 三种格式共用约 60%–70% 的 worker/runner 代码；三个 adapter 合计预计约 900–1,500 行，而不是三套独立工程。

以一名熟悉 Intatis 的实现者计算，合理工程量约 12–20 个工作日：组件固定、打包和许可证核查约 2–4 日；薄适配和预览桥约 6–10 日；真实文档 corpus、渲染和无兜底回归约 4–6 日。这里是工作量估算，不是要求建立分阶段项目流程。

明确不写：

- 文档 parser、OOXML serializer、PDF renderer、OCR engine、Office renderer；
- MCP server、插件市场、动态 backend registry；
- Document Pack installer/update manager；
- 通用 Document IR；
- 常驻 daemon、XPC 服务、数据库或缓存层；
- 另一套权限、sandbox、artifact 或事务系统；
- 第二后端和自动 retry 编排。

如果实现开始明显超过 4.0k 产品代码，应先检查是否正在重写开源库已有能力或引入了上述被禁止的框架，而不是自然接受范围膨胀。

## 7. 开源组件现状

当前 `/Users/vita/Vitemis/Intatis/OpenSource` 已有与本方案直接相关的 checkout：

- `docling`
- `python-docx`
- `python-pptx`
- `pdfcpu`
- `tesseract` 和 `tessdata`
- `libreoffice-core`
- `rbook`
- `epub.js`
- `epubcheck`

还需要补齐：

- `openpyxl`：XLSX 的固定 Python 后端；当前目录中没有该 checkout。
- `lxml`：通常已作为 Python Office 库的依赖安装，但发布前仍应固定精确版本和来源；是否单独 checkout 可按 provenance 规则决定。

其余已下载仓库保留作评估资料，不接入生产链。下载了不等于必须集成。

许可证方向：Docling、Python Office 库、openpyxl、lxml、pdfcpu、Tesseract、rbook、epub.js、EPUBCheck 均是宽松许可证候选；LibreOffice 是独立进程使用的混合/copy-left 工程。正式打包前仍必须按精确 tag/commit、实际发行物和传递依赖完成 `docs/OPEN_SOURCE_REUSE.md` 要求的审计，并更新 NOTICE/provenance。不能只根据仓库首页的 license badge 下结论。

不要编译并嵌入完整 `libreoffice-core` 源码。实际运行使用固定版本的官方 macOS 构建；源码 checkout 只用于核查和需要时的补丁定位。是否随 Intatis 分发，取决于最终许可证和体积决策。

## 8. 预览图的最小处理

模型要真正检查版式，`render` 必须把 PNG 交给下一次模型请求，而不只是返回路径文字。

这里不建设通用“多模态工具输出平台”。只做窄桥接：

1. renderer 将 PNG 写入现有 ArtifactStore/工作区；
2. tool result 保存 ArtifactID、MIME、digest 和尺寸，不保存 base64；
3. 下一次 provider request 将这些 ArtifactRef 作为图片内容附在当前 tool result 上；
4. provider 不支持该能力时，返回 `image_delivery_unsupported`，不能改成文本模式后声称视觉检查完成。

如果当前附件通道可以直接复用，这部分只做适配，不新建类型系统。只有证明现有类型无法表达时才增加一个文档预览专用字段。

## 9. 写入和验证

不新建通用事务框架，只复用现有安全执行能力并增加很薄的文件处理：

```text
检查输入和目标路径
  -> 在目标同目录创建 staging 文件
  -> 固定后端写 staging
  -> 固定验证器 reopen/render/validate
  -> 验证通过后原子替换目标
  -> 返回 changedFiles 和 digest
```

验证失败时删除本次 staging，原文件不变。工具返回失败，不保留一个“也许能打开”的输出给模型继续使用。

这不是为了建设新平台，而是避免一个失败的开源组件调用破坏用户文件。Intatis 已有大部分权限、路径、ticket 和 ArtifactStore 能力，文档工具只需要接上。

## 10. 必须通过的无兜底测试

除正常格式 corpus 外，至少固定以下回归：

1. 普通 DOCX/PPTX/XLSX `read` 必须分别只启动 `python-docx`、`python-pptx`、`openpyxl`；断言 Docling 没有被调用。
2. 移除 `python-docx` 后调用普通 DOCX `read`，必须返回 `backend_missing`；不得启动 Docling 或 LibreOffice 代读。
3. 移除 Docling 后调用 PDF `read` 或显式 Office→研究 Markdown `convert`，必须返回 `backend_missing`；不得尝试 MarkItDown、原生 Office 库或别的解析器完成同一操作。
4. 让 Docling 返回非零，必须返回 `backend_failed`；不得尝试第二解析器。
5. 移除 LibreOffice 后调用 DOCX/PPTX/XLSX `render`，必须失败；不得只返回文本并标成功。
6. Office `edit` 的最终输出必须仍是原生 DOCX/PPTX/XLSX；断言临时 PDF 不参与读写回原生对象，也不会作为最终 artifact 提交。
7. 让 `python-pptx` 写入失败，目标文件保持原样；不得调用 PptxGenJS 或 Apache POI。
8. 让 EPUBCheck 拒绝 staged EPUB，最终输出不得提交。
9. 让 provider 拒绝图片 tool output，必须返回 `image_delivery_unsupported`；不得声称已视觉检查。
10. 每次成功结果的 `engines` 必须和固定表完全一致。
11. 所有后端断网运行；不得出现远程 URL 请求。
12. 搜索生产文档执行代码，不应出现 backend 遍历、`fallback`、`best_effort` 或失败后第二实现 retry。

这些测试比再写一套抽象层更重要，因为它们能直接防止程序悄悄长期运行在兜底上。

## 11. 可行性与明确边界

| 范围 | 可行性 | 说明 |
|---|---|---|
| PDF 阅读、页面操作、表单、水印、遮盖、渲染 | 高 | 现成组件覆盖；任意正文 reflow 不支持 |
| DOCX 常见创建与结构化编辑 | 高 | `python-docx` 成熟；复杂 OOXML 特性显式拒绝 |
| PPTX 常见创建与对象编辑 | 高 | `python-pptx` 足够覆盖常用需求；高级动画/SmartArt 不支持 |
| XLSX 单元格、公式、样式、表格、图表 | 高 | `openpyxl` + 固定 LibreOffice 重算 |
| HTML 创建、DOM/CSS 编辑与渲染 | 高 | `lxml` + WKWebView，且不需要新浏览器 runtime |
| EPUB 常见书籍创建与编辑 | 中 | rbook 需要用真实 corpus 做 round-trip 验收，EPUBCheck 是硬门 |
| 原生 Office/Acrobat 全功能等价 | 不可行且不需要 | 超出“薄接口复用开源组件”的范围 |

如果某个格式的已选组件不能满足一个高级功能，默认答案是“该操作暂不支持”，不是再接第二个库。只有用户明确决定扩大支持范围时，才重新选择唯一后端并替换原有实现。

## 12. 实施时的单一完成标准

实现不按宏大阶段展开。完成标准就是：

- 模型目录中只有一个新 `document` 工具；
- 六类格式的常见 read/render/create/edit 请求都走固定表；
- DOCX/PPTX/XLSX 共用一个 Office worker，普通读取分别固定使用三个原生库；
- Office 原生编辑链不经过 PDF，PDF 只作为不回写的临时视觉预览；
- 所有写操作都有固定验证器和原子提交；
- 页面/幻灯片/工作表/章节预览能真正进入模型视觉输入；
- 组件缺失或失败时明确失败；
- 没有自动后端切换；
- 没有新增 MCP server、插件框架或安装平台；
- 自研产品代码控制在约 2.2k–4.0k 行；
- 开源版本、许可证、来源和实际分发物均可审计。

达到这些条件就结束。不要顺手扩展成通用文档平台。

## 13. 本报告核查过的本地依据

- `/Users/vita/Vitemis/Intatis/Packages/IntatisTools/Sources/DocumentMediaTools.swift`
  - 确认现有 `read_document` 的 Docling→MarkItDown `auto` 兜底；
  - 确认现有图片重建路径存在多后端和 Tesseract fallback。
- `/Users/vita/Vitemis/Intatis/Packages/IntatisTools/Sources/ShellGit.swift`
  - 确认已有 structured document runtime/LibreOffice 执行基础，可复用而无需新 runner。
- `/Users/vita/Vitemis/Intatis/Packages/IntatisMCPStdio/Sources/MCPStdioExecutionGuard.swift`
  - 确认 macOS MCP stdio helper/descendant execution 限制。
- `/Users/vita/Vitemis/Intatis/Packages/IntatisMCPStdio/Sources/MCPProductionStdioTransport.swift`
  - 确认 Linux local MCP workspace 只读约束。
- `/Users/vita/Vitemis/Intatis/OpenSource/`
  - 确认当前已下载候选仓库清单；未修改任何 checkout。

## 14. 本轮状态

本轮只重写本报告。没有修改产品源码、配置、测试、项目既有说明文档或 `OpenSource/` 中的任何仓库；没有运行构建或测试。
