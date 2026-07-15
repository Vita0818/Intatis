# CURRENT_UI_COLOR_SYSTEM — 系统原生表面与 Liquid Glass 规范

最近核对日期：2026-07-15

> **文档状态：当前实施规范。**
>
> Intatis 不再把“系统外观”解释为固定的纯白和纯黑。页面、侧栏、内容层与控制层均使用 Apple 平台的动态语义资源；在支持的系统上，导航与交互控件采用原生 Liquid Glass。`docs/UI_COLOR_SYSTEM.md` 只保存上一版香槟金 / 暖中性色方案，不随当前方案修改。

## 1. 核心规则

1. 不为浅色或深色模式声明固定 `.white`、`.black`、RGB、Hex 或取色器采样值。
2. macOS detail 区使用系统 window surface；sidebar 交还 `NavigationSplitView` 自己渲染，不覆盖自定义底色。
3. 内容层（消息、数据卡片、权限提示、artifact、Goal / Task 信息等）使用系统 `Material`，让外观随系统主题、窗口状态、墙纸色调、对比度和透明度设置动态解析。
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
| Content | `.regularMaterial` + 系统 separator | 消息、信息卡片、权限、artifact、Goal / Task 等内容 |
| Functional glass | `glassEffect`、`GlassEffectContainer`、`.buttonStyle(.glass/.glassProminent)` | composer、模型菜单、主要按钮、操作组、agent pill 等 |
| Fallback | `.regularMaterial` 或系统 bordered button | macOS 13–15、iOS 16–18 等不支持 Liquid Glass 的部署目标 |

系统强调色用于焦点、选中态和 prominent 操作。Intatis 不再以固定黑白代替系统 accent，也不自行模拟玻璃的高光、折射、阴影或动态响应。

## 3. 组件映射

### 3.1 页面与侧栏

- macOS detail 区由 `IntatisSystemCanvas` 渲染动态 window surface。
- macOS sidebar 不设置 `IntatisTheme.canvas` 或其他覆盖层，保留系统侧栏材质。
- iOS 继续由 `NavigationStack` / SwiftUI 容器提供原生根背景，不引入 Intatis 私有页面色。

### 3.2 Chat

- 用户与助手消息使用内容层 Material；角色差异仍由左右对齐、文字和系统 accent 选择态共同表达。
- composer 输入容器和发送操作使用 Liquid Glass；发送按钮使用 prominent glass。
- provider / model 菜单及 thread 操作使用系统 glass button。

### 3.3 Code

- 消息、Plan、Workspace、Recent Failures、权限提示和 artifact 属于内容层，使用系统 Material。
- header / workspace 操作与主要 CTA 属于功能层，使用原生 glass button。
- inspector 维持系统分栏结构，不创建固定灰色或纯黑 / 纯白面板。

### 3.4 Cowork

- Goal、Tasks、Git Status、项目数据等属于内容层，不套 Liquid Glass。
- Goal 操作、agent 操作、task action、项目设置按钮和紧凑 agent pill 属于功能层，可使用 Liquid Glass 并以 `GlassEffectContainer` 组织相邻效果。
- 红、橙、绿继续只承担错误、等待 / 阻塞、成功等语义状态，并同时保留文字或图标。

### 3.5 模式切换与设置

- Chat / Code / Cowork mode switch 使用系统 segmented `Picker`，让系统自行提供选中、键盘、焦点与可访问性行为。
- 设置表单继续优先使用原生控件；主要操作按语义使用 glass 或 glass prominent，不画自定义黑白按钮。

## 4. API 与部署边界

- `glassEffect`、`GlassEffectContainer`、`.glass` 和 `.glassProminent` 只在 macOS 26 / iOS 26 及以上启用。
- 项目仍支持 macOS 13 / iOS 16；旧系统必须走系统 Material / bordered control fallback，不能用手绘静态“仿玻璃”。
- `IntatisSharedUI` 通过可用性检查共享实现，不反向依赖 macOS app target，也不扩大 iOS 的 Chat-only 产品边界。
- 系统 Reduce Transparency、Increase Contrast、accent、active / inactive window 与其他辅助功能设置应由原生 API 自动响应，不能用固定值覆盖。

## 5. 事实来源

- `Apps/IntatisMac/Sources/IntatisDesign.swift`：系统 window canvas、macOS 13 兼容表面、语义色与内容卡片。
- `Apps/IntatisMac/Sources/IntatisMacRootView.swift`：原生 split-view sidebar 与 detail canvas。
- `Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`：内容 Material、Liquid Glass、glass button、容器与 segmented mode switch。
- `Packages/IntatisSharedUI/Sources/Views.swift`：共享 Chat 消息和 composer。
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
- Liquid Glass 只出现在导航和交互功能层；消息、Goal / Task 数据及长内容没有整片玻璃化。
- 支持的系统上使用真实 `glassEffect` / glass button；旧系统 fallback 仍由系统语义 Material / control 渲染。
- Chat / Code / Cowork 的 Light / Dark 运行态都经过视觉核对；不能只用源码搜索或固定像素值推断。
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
