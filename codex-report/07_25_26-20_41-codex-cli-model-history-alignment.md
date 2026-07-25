# Codex CLI 模型历史对齐：先把“上一轮真的带到下一轮”做对

日期：2026-07-25  
参考上游：`https://github.com/openai/codex`  
固定 commit：`4c43465133428898aa84f0bfc02c306ed65fb66a`

## 我们想解决什么

截图里的问题不是模型单纯“卡住了”，而是 harness 没有可靠保存模型自己的工作历史。

用户先交代一个任务，过一会儿再问“现在呢？”，正确行为应该是让同一条主对话继续包含：

```text
用户 U1
助手 A1
助手发起的工具调用
工具返回结果
用户 U2：现在呢？
```

不能只发送最后一句 U2，也不能把旧内容压成几句模糊摘要，更不能从 UI 气泡、任务完成文案或被截短的审计记录猜出模型当时看到了什么。目标很直接：只要还是同一个 Cowork `@main`，后续请求就应继续同一条模型对话。

## Codex CLI 实际怎么做

Codex CLI 为一个 thread 保存一列有顺序的 model items。用户消息、助手最终消息、function call 和 function output 都进入这一列；每次请求都从同一列生成 prompt。流式文字只是显示过程，完成后的 assistant item 才入历史一次。

工具调用也不是事后从日志猜出来的。助手返回完整 call 后，Codex 先把 call 放入历史，再执行工具，再把相同 call ID 的 output 放回历史。下一次模型请求看到的是它自己刚才发出的 call 和结果。

如果进程在 call 已记录、output 尚未记录时中断，Codex 在下一次 prompt 的临时副本里为该 call 补一个稳定的 `aborted`；孤立、找不到 call 的 output 不发送给模型。这些修正不倒写真实历史。

重启时，Codex 从 rollout 保存的 model items 重建 thread，不从 UI transcript 重建。历史太长时，它使用 compaction checkpoint 保存一份完整的 `replacement_history`，不是只留一段摘要后抛弃原来的结构。

本轮主要核对了：

- `codex-rs/core/src/state/session.rs`
- `codex-rs/core/src/context_manager/history.rs`
- `codex-rs/core/src/context_manager/normalize.rs`
- `codex-rs/core/src/session/turn.rs`
- `codex-rs/core/src/session/rollout_reconstruction.rs`
- `codex-rs/protocol/src/models.rs`
- `codex-rs/protocol/src/protocol.rs`
- `codex-rs/rollout/src/policy.rs`
- 上述模块对应的 context、history、resume 和 compaction tests

## Intatis 现在已经做到什么

适用范围是符合条件的 Cowork 稳定 `@main` root submission。普通 worker 仍只拿自己的任务上下文，Code 模式也还没有切换到这条 durable tool-history 链。

- 用户消息在第一次调用 provider 前进入 EventLog。
- assistant 最终文字完成后只记录一次。
- assistant 一次返回的完整工具调用批次，在任何工具开始执行前原子记录。
- 工具结果、工具执行结算和给模型看的有界清洗结果在同一个 EventLog batch 中落盘，不再存在“工具已成功，模型历史还没写”的取消窗口。
- 新建 `AgentLoop` 使用同一份完整 EventLog 时，会恢复 user、assistant、call、output 的原顺序。
- 已经成为 prior history 的 call 如果缺 output，只在请求副本中得到 `aborted`；孤立 output 删除；并行结果按 assistant 原来的 call 顺序恢复。
- 空 call ID，或同一个 turn 后续工具轮再次使用 `call_0`，会被改写成唯一的内部 ID；assistant call、工具结果和 execution ticket 使用同一新 ID。
- 读取模型历史前要求从 seq 0 到日志尾部完整且全部可理解；未来未知事件或序号缺口会在调用 provider 前停止。
- 新式模型历史已覆盖的回答和完整工具对，不会再通过 `ContextBundle` 重复塞给模型；如果只有 call、还没有 direct output，旧 audit result 不会被错误删除。
- UI projection 忽略 `model_history_item`，所以不会多显示一份回答或工具气泡。
- 旧 session 没有新记录时，只恢复能够严格证明的 root 用户文字和最终回答；不会把旧的截短工具审计记录伪装成真实工具历史。

安全边界仍然保留。`write_stdin` 原始输入永不写入 EventLog；`spawn_agent`、`rename_session`、未知或非法工具，以及检测到秘密或过长的参数，会保存固定的合法占位 JSON，而不是原文。工具输出进入模型历史前也会清洗并限制长度。

## 现在还没有做到什么

这还不能叫“完全复刻 Codex CLI”：

1. 没有 Codex-style replacement-history compaction checkpoint；`@main` 长历史目前还会继续增长。
2. 同一 submission 的 whole-task Retry 仍是 fresh invocation，不是 Codex 式中断 turn 原地 resume。
3. provider-native reasoning item 还没有保存和恢复。
4. 历史图片、多模态输入和多模态工具结果还没有从 ArtifactStore 重新装载。
5. rollback、fork 和分支 thread 的历史语义还没有实现。
6. 自动测试尚未证明真实 App/process 被杀后重开，也没有跑真实 provider 的超长连续会话。

这些项目不能用“最近 N 条消息”或一段自行编写的摘要替代。下一步应继续对照同一固定版本 Codex，先实现 replacement-history checkpoint：checkpoint 保存压缩后仍可直接作为模型输入的完整 item 数组，恢复时以最新 checkpoint 为基底，再追加之后的 durable items。

## 这轮有没有复制 Codex 源码

没有。本轮是 `reference`：固定上游 commit，阅读行为和测试，再用 Intatis 的 Swift、EventLog、权限和 lease 边界独立实现。没有复制、逐行翻译、vendor 或链接 Codex Rust 源码、prompt、测试、品牌文案或 UI 资产，因此本轮不需要修改 `NOTICE.md`。

## 当前验证

专项回归为 34 tests / 0 failures，覆盖：

- 跨 turn 的 U1/A1/tool/U2 顺序；
- fresh `AgentLoop` 从同一 EventLog 恢复；
- call/output 配对、顺序、missing/orphan；
- tool result、settlement、model output 的同批写路径；
- retry attempt 选择；
- 重复 call ID 唯一化；
- wrong agent/target、unknown event、seq gap 的 provider 前拒绝；
- worker 隔离和 ContextBundle 去重；
- `write_stdin` 原文不落盘。

最终完整验证结果：

- SwiftPM full suite：1000 tests / 14 skipped / 0 failures。
- `swift build --disable-sandbox`：通过。
- IntatisMac macOS Debug build：通过。
- IntatisiOS Simulator Debug build：通过。
- 两个 Xcode build 只有项目既有警告，没有新增编译错误。

这些结果证明当前源码可以编译、既有测试没有回归；它们不替代前面列出的真实 provider 长会话、杀进程恢复、compaction、reasoning、多模态、resume 和 fork 验证。最终命令与环境记录见 `docs/TESTING.md`。
