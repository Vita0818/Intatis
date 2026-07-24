# CURRENT_UI_COLOR_SYSTEM — 系统原生表面与 Liquid Glass 规范

最近核对日期：2026-07-23

> **文档状态：当前实施规范。**
>
> Intatis 不再把“系统外观”解释为固定的纯白和纯黑。页面、侧栏、内容层与控制层均使用 Apple 平台的动态语义资源；在支持的系统上，导航与交互控件采用原生 Liquid Glass。`docs/UI_COLOR_SYSTEM.md` 只保存上一版香槟金 / 暖中性色方案，不随当前方案修改。

## 1. 核心规则

1. 不为浅色或深色模式声明固定 `.white`、`.black`、RGB、Hex 或取色器采样值。
2. macOS detail 区使用系统 window surface；sidebar 交还 `NavigationSplitView` 自己渲染，不覆盖自定义底色。
3. 普通 assistant / agent 正文直接继承系统 conversation canvas，不额外叠 Material 或描边；用户消息、失败回复、数据卡片、权限提示、artifact、Goal / Task 等需要边界的结构化内容使用系统 `Material`。
4. 功能层（导航、模式切换、composer、模型菜单、主要操作与紧凑交互控件）在 macOS 26 / iOS 26 采用原生 Liquid Glass。
5. Liquid Glass 不铺满页面，也不作为长文本或数据内容的背景；玻璃只承担浮于内容之上的导航和交互功能。
6. 文本、分隔线、强调色与错误色使用系统语义资源：`.primary`、`.secondary`、系统 separator、`.accentColor`、`.red` 等。
7. 颜色不是状态的唯一信息通道；状态同时保留文字、图标或结构提示。

“系统原生”指由当前 Apple 平台实时解析的语义表面和材质，而不是把某一台设备上看到的像素颜色写死。取色器只能用于视觉核对，不能成为令牌来源。

## 2. 表面层级

| 层级 | 当前实现 | 用途 |
|---|---|---|
| Window | SwiftUI `.windowBackground`；macOS 13 使用 `NSVisualEffectView.Material.windowBackground` 兼容 | macOS detail 根表面 |
| Sidebar | `NavigationSplitView` 原生 sidebar | macOS 导航栏及其 vibrancy / active-window 行为 |
| Conversation text | 继承 Window / 系统容器 canvas | 正常完成的 assistant / agent Markdown、公式与正文 |
| Structured content | `.regularMaterial` + 系统 separator | 用户消息、失败回复、信息卡片、权限、artifact、Goal / Task 等内容 |
| Functional glass | `glassEffect`、`GlassEffectContainer`、`.buttonStyle(.glass/.glassProminent)` | composer、模型菜单、主要按钮、操作组、agent pill 等 |
| Fallback | `.regularMaterial` 或系统 bordered button | macOS 13–15、iOS 16–18 等不支持 Liquid Glass 的部署目标 |

系统强调色用于焦点、选中态和 prominent 操作。Intatis 不再以固定黑白代替系统 accent，也不自行模拟玻璃的高光、折射、阴影或动态响应。

## 3. 组件映射

### 3.1 页面与侧栏

- macOS detail 区由 `IntatisSystemCanvas` 渲染动态 window surface。
- macOS sidebar 不设置 `IntatisTheme.canvas` 或其他背景覆盖层；`NavigationSplitView` 继续提供系统侧栏材质，内部是 `Intatis` 标题、带 SF Symbol 的 Chat/Code/Cowork 竖向三行导航、mode-specific session history/New 与底部 Settings 的连贯结构。只有当前模式行使用 interactive Liquid Glass。
- iOS 继续由 `NavigationStack` / SwiftUI 容器提供原生根背景，不引入 Intatis 私有页面色。

### 3.2 Chat

- 用户消息保留内容层 Material；正常完成的助手 / agent 回复没有外层卡片、底色或描边，Markdown、公式等直接显示在系统 canvas 上。失败 / 中断回复继续保留结构化容器与恢复建议。
- assistant / agent 名称右侧的消息时间属于三级只读元数据，不加 badge、图标、头像、玻璃或独立容器；它跟随系统本地化，24 小时内仅时间、7 天内星期加时间、更早为年月日加时间。
- composer 固定为两排：第一排左侧是模型选择控件，右侧是 Context / Input / Cached / Output / Time 只读 usage；Chat/Code/Cowork 的选择器共用原生 `Menu` 语义与 40pt 高 interactive Liquid Glass 胶囊。选择按钮关闭态只显示模型名，不显示 CPU/芯片图标、provider 名或 variant/reasoning 辅助文字；弹出菜单内部仍按 provider 分组并保留 variant 明细。第二排从左到右是当前产品面已有的附件或图像 action、原生多行 `TextField`、唯一主操作位。
- composer 第二排的附件/图像 action 与主操作使用 40×40 原生圆形 glass/bordered control，输入容器单行最小高度同为 40，同行 spacing 为 8；多行输入只向上增长，左右按钮保持底边对齐。主操作 idle 时是 Send，工作时在同一位置替换为 `Button(role: .destructive)` + `stop.fill` 的系统红色 Stop，不并排显示两个操作。
- composer 的附件、图像 action、Stop 与 Send 复用 `.controlSize(.regular)`、圆形 button border shape 和系统原生 glass / bordered 表现；Send 使用 prominent 语义，Stop 使用系统 destructive/red 语义且不自绘。sidebar `Recent` 旁 `+` 则使用 `.controlSize(.small)`、圆形 border shape 与原生 glass，fitting size 为 30×30。没有对应能力的 Chat / Code 不凭空增加附件入口。
- iOS 继续复用同一 composer；没有 top accessories 时不生成空白第一排，也不扩大 Chat-only 产品边界。
- 现有 macOS Chat 与共享 Code/Cowork `Thinking…` 行在 spinner 后显示 phase-local elapsed 文案（例如 `15s Thinking…`）；秒数使用等宽数字并进入 accessibility label，等待行结束即停止并重置，不改变协议或模型内容。

### 3.3 Code

- 正常 agent 回复继承系统 canvas；用户消息、失败回复、Plan、Workspace、Recent Failures、权限提示和 artifact 属于结构化内容层，使用系统 Material。
- Code 与 Cowork 共用名称右侧的低噪声消息时间；时间不参与 agent 状态、权限或任务完成语义。
- header / workspace 操作与主要 CTA 属于功能层，使用原生 glass button。
- inspector 使用 SwiftUI 原生 `.inspector`，不创建固定灰色或纯黑 / 纯白面板。

### 3.4 Cowork

- 正常 agent 回复与 Code 共用无外框正文渲染；tool、error、permission、task 与 agent-to-agent 等结构化记录仍保留语义容器。
- Goal、Tasks、Git Status、项目数据等属于内容层，不套 Liquid Glass。
- Goal 与 Tasks 只在可见的宽屏 inspector 中呈现；窄窗口或用户隐藏 inspector 时，不在 thread 顶部复制 compact dock，也不保留对应占位高度。
- Goal 操作、agent 操作、task action、项目设置按钮和紧凑 agent pill 属于功能层，可使用 Liquid Glass 并以 `GlassEffectContainer` 组织相邻效果。
- 红、橙、绿继续只承担错误、等待 / 阻塞、成功等语义状态，并同时保留文字或图标。

### 3.5 模式切换与设置

- Chat / Code / Cowork、mode-specific sessions、New 和 Settings 位于同一个 sidebar navigation/session center；mode 是带 SF Symbol 的三行竖向按钮，仅选中行使用 interactive Liquid Glass，session 保留明确选中态与原生 Rename/Delete context menu。
- 设置表单继续优先使用原生控件；主要操作按语义使用 glass 或 glass prominent，不画自定义黑白按钮。

## 4. API 与部署边界

- `glassEffect`、`GlassEffectContainer`、`.glass` 和 `.glassProminent` 只在 macOS 26 / iOS 26 及以上启用。
- 当前产品 deployment target 是 macOS 26 / iOS 26；源码中的 Material / bordered fallback 只保留为防御性实现，不属于当前产品验收矩阵，也不能被替换成手绘静态“仿玻璃”。
- `IntatisSharedUI` 通过可用性检查共享实现，不反向依赖 macOS app target，也不扩大 iOS 的 Chat-only 产品边界。
- 系统 Reduce Transparency、Increase Contrast、accent、active / inactive window 与其他辅助功能设置应由原生 API 自动响应，不能用固定值覆盖。

## 5. 事实来源

- `Apps/IntatisMac/Sources/IntatisDesign.swift`：系统 window canvas、macOS 13 兼容表面、语义色与内容卡片。
- `Apps/IntatisMac/Sources/IntatisMacRootView.swift`：系统 split-view sidebar 材质、title/竖向 icon mode/history/Settings 内部结构与 detail canvas。
- `Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`：结构化内容 Material、30×30 sidebar New 圆形 glass control、原生圆形 icon controls、40pt composer/selection-menu 几何合同、两排 composer、首排 usage strip 与可选 accessories。
- `Packages/IntatisSharedUI/Sources/Views.swift`：共享 Chat 消息和 composer；正常 assistant / agent 回复继承系统 canvas。
- `Packages/IntatisSharedUI/Sources/CodeViews.swift`、`CoworkViews.swift`、`ArtifactViews.swift`：各产品面的内容层 / 功能层映射。
- `Apps/IntatisMac/Sources/IntatisChatScreen.swift`、`IntatisMacApp.swift`：macOS Chat、设置与 home CTA。

Apple 官方设计与 API 依据：

- [Liquid Glass overview](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [SwiftUI `glassEffect`](https://developer.apple.com/documentation/swiftui/view/glasseffect%28_%3Ain%3A%29)
- [SwiftUI `windowBackground`](https://developer.apple.com/documentation/swiftui/shapestyle/windowbackground)

## 6. 验收清单

- 浅色界面是系统当前解析出的 window / sidebar / Material 外观，而非固定纯白。
- 深色界面是系统当前解析出的 window / sidebar / Material 外观，而非固定纯黑。
- 侧栏保留系统材质，前台 / 后台窗口状态切换时能够跟随系统。
- Liquid Glass 只出现在导航和交互功能层；正常 agent 正文直接位于系统 canvas，用户消息和结构化卡片使用 Material，Goal / Task 数据及长内容没有整片玻璃化。
- 支持的系统上使用真实 `glassEffect` / glass button；旧系统 fallback 仍由系统语义 Material / control 渲染。
- Chat / Code / Cowork 的 Light / Dark 运行态都经过视觉核对；不能只用源码搜索或固定像素值推断。
- thread header 显示 session display name；Code / Cowork header 使用紧凑顶部留白且 Cowork 不常驻 permission-reviewer 横幅；消息无 agent 头像与通用 Agent badge；正常 agent 回复无外层卡片；agent 名称旁有本地化三级时间元数据；sidebar 模式为带图标的竖向三行且仅选中行使用玻璃，Recent New `+` 为 30×30 原生圆形 glass；composer 第一排保持 40pt、关闭态仅模型名的 model/profile glass 菜单左、usage 右，第二排保持已有 action 左、输入居中、可选 stop 与 Send 右；第二排 action/stop/Send 与单行输入均为 40pt，输入变为多行时按钮底边不漂移；Cowork 无 inspector 时不显示 Goal/Tasks 顶部副本。
- macOS 与 iOS touched targets 均可编译，全量 SwiftPM 测试通过。

静态复核重点：

```sh
rg -n 'IntatisTheme\.canvas|scheme == \.dark \? \.black : \.white|Color\.(white|black)|LinearGradient' Apps Packages
rg -n 'glassEffect|GlassEffectContainer|buttonStyle\(\.glass|regularMaterial|windowBackground' Apps Packages
```

第一组命中需要人工确认是否属于图标、图片或测试语境；任何页面 / 组件固定表面色都不符合本规范。第二组用于确认系统语义表面和玻璃入口仍存在。

## 7. 2026-07-15 实施验证

- SwiftPM build 通过。
- IntatisMac macOS Debug 与 IntatisiOS Simulator Debug 构建通过。
- 使用 Computer Use 检查本轮构建的 Chat、Code、Cowork：Light 使用系统浅色 window / sidebar / Material，Dark 使用系统动态深灰层级而非纯黑；composer、CTA、模式切换和相关操作呈现原生控件 / Liquid Glass。
- Light / Dark 验收使用 DEBUG-only 启动参数 `-IntatisAppearanceLight` / `-IntatisAppearanceDark` 隔离测试，不修改用户的全局系统 Appearance；生产启动不设置偏好，始终跟随系统。
- 完整 SwiftPM 测试通过：605 tests，14 skipped，0 failures。

## 8. 未固定的部分

- 系统表面、Material、Liquid Glass、`.primary`、`.secondary`、separator、accent 和状态色的最终像素值不固定。
- 不为不同墙纸、显示器 profile、Display P3 / HDR、Reduce Transparency、Increase Contrast 或 window focus 状态建立硬编码色表。
- 本文规范视觉表面与颜色语义，不替代布局、动态字体、焦点、键盘操作和完整无障碍规范。

## 9. 2026-07-21 OS26 UI shell 复验（历史）

- 该次截图与 Computer Use 只验证当时的自定义纵向 mode/session 表面，以及“usage 独占上方一行、model/profile/attachment 位于输入容器”的旧布局。控制位置已被 2026-07-23 方案取代，不能继续作为当前像素、键盘或焦点行为的 Passed 证据。
- 当时的 session-name header、无消息 agent 头像/通用 Agent badge和 Code/Cowork 原生 inspector 结论仍是历史事实。
- `swift build`、IntatisMac macOS Debug、IntatisiOS Simulator Debug 与 `CoworkInferencePresentationTests` 4/4 通过。
- Computer Use 在最新 Debug app 中只读检查了 Chat、Cowork 与宽屏 inspector；参考图和实现截图在同一比较输入中核对，结果见根目录 `design-qa.md`。
- 本轮没有改字体 token、用户字体选择、EventLog/projection schema、权限链路、iOS chat-only target 边界或开源依赖。

## 10. 2026-07-22 conversation surface 收口

- Cowork 对话页删除常驻 permission-reviewer 顶部横幅；Code / Cowork session header 的顶部留白统一从 26pt 收紧为 12pt。真正待处理的 `PermissionCard`、permission FIFO 与权限引擎没有删除；横幅原有的 workspace reauthorization / automatic-review retry 只在异常时进入 Cowork Project Settings 的 Recovery 区。
- macOS Chat、Code、Cowork 与共享 iOS Chat 的正常 assistant / agent 回复取消外层 Material、圆角和描边，正文、Markdown 与公式直接继承系统 canvas；用户消息、失败 / 中断回复、tool、error、permission、task 等结构化内容继续保留容器。
- macOS Chat/Code/Cowork 与共享 iOS Chat 的 assistant/agent 名称右侧复用同一时间表现：首次 message envelope 定时，24 小时 / 7 天滚动分层，遵循当前 locale、时区和 12/24 小时偏好；流式完成不刷新为“完成时间”。
- 没有硬编码白色背景，也没有修改字体。`MessageRenderingTests` 22/22、`swift build --disable-sandbox`、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 通过；运行态 Light / Dark 和真实长回复视觉复核仍待用户检查。
- 名称旁时间追加后的组合过滤实际执行 161 tests / 0 failures，SwiftPM 与 macOS/iOS Debug app target 再次构建通过；遵守 renderer NO-GO，没有启动 App/fixture，因此不同 locale、Light/Dark 和跨阈值长期停留仍未做运行态视觉结论。

## 11. 2026-07-23 原生 List sidebar 与两排 composer（已撤销）

- 该轮曾把 macOS 根侧栏收敛为单个 `List(selection:)`，以 `Section` 组织 mode、当前 mode 的 sessions 与 Settings，并采用 `.listStyle(.sidebar)`；此排布已被同日后续视觉修订撤销，不再代表当前实现。
- composer 第一排为 model/profile 左、usage 右；第二排为当前已有附件/图像 action 左、`TextField` 居中、可选 Cowork stop 与 Send 右。`+`、附件、图像 action、stop 和 Send 使用统一 regular/circle 原生 glass/bordered control，Send 保持 prominent。Cowork selector 仍可在 busy 时选择且只冻结下一次 `@main` Send；没有新增 Chat/Code 附件能力，字体未改。
- Swift parse、`swift build --target IntatisSharedUI`、`IntatisSharedUITests` 50/50、`PerAgentInferenceProfileTests` 20/20、`SubmittedIntentStoreTests` 11/11、`SubmissionProjectionTests` 4/4、XcodeGen、IntatisMac macOS Debug 与 IntatisiOS generic Simulator Debug build 均通过。
- 本轮没有启动 App 或 renderer fixture；当前像素、sidebar 键盘/焦点、Light/Dark、Reduce Transparency 和真实窄宽布局仍为 `UNKNOWN`。

## 12. 2026-07-23 sidebar 竖向导航恢复与 composer 几何修正

- sidebar 当前为系统 `NavigationSplitView` 材质内的 `Intatis` 标题、带 SF Symbol 的 Chat/Code/Cowork 竖向三行导航、mode-specific `Recent` history/New 与底部 Settings；仅当前模式行使用 interactive Liquid Glass。该状态取代同日较早的单一 `List(selection:)` 和横向 segmented control 修订；session Rename/Delete、busy delete gate 与 durable selection 逻辑保持不变。
- `Recent` 旁 New `+` 使用 24pt label、`.controlSize(.small)`、圆形 button border shape 与原生 glass，fitting-size probe 为 30×30。composer 仍为两排；第一排 Chat/Code/Cowork 模型或 profile `Menu` 共用 40pt 高 interactive Liquid Glass 胶囊，关闭态只显示模型名，右侧 usage 保持只读且不伪装成按钮。
- 第二排附件/图像 action/stop/Send 的 icon label 统一为 32×32，经原生 `.glass` / `.glassProminent` 或 bordered fallback 后得到 40×40 外观；输入容器单行最小高度为 40、间距为 8、圆角为 20。外层使用 bottom alignment，多行输入时按钮保持贴底。
- 原生控件 fitting-size probe 确认 Recent `+` 为 30×30，plain native `Menu` 加共享 interactive glass label 后为 40pt 高；第二排 glass/glassProminent/bordered 按钮与单行输入均为 40pt。Swift parse、SharedUI build、`IntatisSharedUITests` 50/50、`PerAgentInferenceProfileTests` 20/20、XcodeGen、macOS Debug 与 iOS generic Simulator Debug build 均通过。
- 遵守 renderer NO-GO，本轮未启动 App 或 fixture；实际像素、sidebar 交互、Light/Dark、Reduce Transparency 和真实窄宽布局仍为 `UNKNOWN`。
