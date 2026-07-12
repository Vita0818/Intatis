# Codex Git 控制方式调研报告

日期：2026-07-08

## 结论

Codex 对 Git 的处理不是简单地给 agent 开放 `git` shell，而是把 Git 拆成几层受控能力：

- App 层提供 Git diff/review 面板，支持查看 repo 状态、按文件或 chunk stage/revert、内联评论、commit、push 和创建 PR。
- Worktree 层用 Git worktree 隔离并行任务，默认在 detached HEAD 上工作，避免污染本地分支。
- CLI 层允许常规本地命令，但 review 工作流是只读 reviewer：读 diff、给 findings，不改工作区。
- 开源实现层把 Git helper 封装成专门模块：参数数组调用系统 `git`、禁用 hooks、抽取 patch 路径、支持 patch preflight/apply、读取 repo metadata、计算 base/merge-base。

因此，Intatis 的正确方向是“受限 Git 工具 + patch/index/worktree 能力 + PermissionEngine”，而不是让模型自由拼接 `git` 命令。

## Codex App 的 Git 行为

官方 Codex app features 文档显示，Codex app 有三种 thread mode：`Local`、`Worktree`、`Cloud`。Local 直接在项目目录工作；Worktree 用 Git worktree 隔离改动；Cloud 在远程环境运行。

Codex app 还提供内建 Git 功能：

- diff pane 显示 local project 或 worktree checkout 的 Git diff。
- 用户可添加 inline comments，让 Codex 针对具体 diff 行处理。
- 支持 stage 或 revert specific chunks / entire files。
- 支持 commit、push、create pull requests。
- 更高级 Git 任务交给 integrated terminal。

对 Intatis 的启发：UI 可以有状态/评审面板，但核心执行层应暴露更小粒度的 tool：status/diff、patch preflight/apply/revert、stage/unstage、commit，而不是一次性做完整 IDE 式 Git 工作流。

## Codex Worktrees 的隔离模型

官方 worktrees 文档说明，Codex 的 worktree 基于 Git worktree：多个 checkout 共享同一 `.git` metadata，但各自有独立文件副本。它用于：

- 让 Codex 并行工作而不打扰当前 Local checkout。
- 后台排队任务。
- 稍后通过 handoff 把线程移回 Local。

Codex managed worktrees 的关键点：

- 创建在 `$CODEX_HOME/worktrees`。
- 起点是用户选择 branch 的 `HEAD` commit。
- 默认 detached HEAD，以免污染分支。
- 如果选择带本地改动的 branch，可把 uncommitted changes 应用到 worktree。
- `.gitignore` 文件默认不会随 handoff 移动，除非通过 `.worktreeinclude` 指定被复制的 ignored paths。

对 Intatis 的启发：本轮先做 workspace 内 `.intatis/git-worktrees/<name>` 受管 worktree，默认 detached HEAD，不做 handoff，也不自动复制 ignored secrets。这个范围更小，但方向与 Codex 一致。

## Codex CLI 的 Git/Review 行为

Codex CLI features 文档里，`/review` 会启动 dedicated reviewer，读取用户选择的 diff 并输出 prioritized actionable findings，而且不触碰 working tree。review preset 包括：

- against base branch：找 merge base，diff 当前工作。
- uncommitted changes：检查 staged、unstaged、untracked。
- a commit：读取指定 SHA 的 change set。
- custom review instructions：同一 reviewer 换提示词。

CLI approval modes 也说明：Auto 默认可读文件、编辑和在工作目录内运行命令；Read-only 只咨询；Full Access 跨机器/网络执行能力更大。Codex 总是展示 action transcript，用户可用自己的 Git workflow review/rollback。

对 Intatis 的启发：Git review 和 Git mutation 应拆开。只读 diff/base/recent commit 可以默认 read-only；index/patch/commit/worktree mutation 必须走权限流；remote/push/PR/CI 暂不进入本 slice。

## openai/codex 开源实现观察

`openai/codex` 的 `codex-rs/git-utils` 模块公开了 Codex 如何封装 Git：

- `git-utils/src/lib.rs` 暴露 `apply_git_patch`、`extract_paths_from_patch`、`stage_paths`、`merge_base_with_head`、`collect_git_info`、`recent_commits`、`git_diff_to_remote` 等 Git helper。
- `apply.rs` 的注释说明入口是 `apply_git_patch`：写临时 patch 文件，调用 `git apply`，支持 preflight dry-run，并解析 stdout/stderr 里的路径诊断。
- `operations.rs` 用 `std::process::Command` 构造 `git` 调用，并给内部 helper 命令加 `core.hooksPath=/dev/null`，避免用户配置 hooks 影响内部操作。
- `info.rs` / `branch.rs` 负责 repo root、HEAD、branch、default branch、remote、recent commits、merge-base 等 metadata。

更细的实现要点：

- Git 调用是参数数组，不是 shell 字符串；`info.rs` 中 metadata 命令带 5 秒 timeout，并设置 `GIT_OPTIONAL_LOCKS=0`，避免大仓库或锁等待卡住 agent。
- Repo root 检测分两类：轻量 `.git` ancestor 检测不依赖 `git` binary；需要真实 metadata 时再用 `git rev-parse`。worktree trust root 会解析 `.git` file 中的 `gitdir:`，确认 linked worktree 回到主 repo。
- `collect_git_info` 并行读取 `HEAD`、branch、remote URL；`recent_commits` 用 `git log --pretty` 输出结构化 commit summary。
- `git_diff_to_remote` 会找可达 remote SHA，再对该 SHA 做 `git diff --no-textconv --no-ext-diff`；未跟踪文件用 `git diff --no-index --binary -- /dev/null <file>` 追加进 diff。
- `apply_git_patch` 的 preflight 使用 `git apply --check`，不改工作区；真实 apply 默认 `git apply --3way`。reverse apply 在非 preflight 场景会先 best-effort `git add -- <paths>`，降低 “does not match index” 类失败。
- patch 输出会被解析为 `applied_paths`、`skipped_paths`、`conflicted_paths`，而不是只返回一段 stderr；这使 UI/agent 后续可以按文件解释失败和冲突。

对 Intatis 的启发：本轮采用同类工程形态：`GitService` 抽象 + process-backed system `git`，参数数组调用，不拼 shell；patch 先解析 paths 再执行；repo metadata 和 workspace 边界显式校验。没有复制 Codex 源码。

## Intatis 本轮实现映射

本轮 Intatis 已补上：

- read-only：`git_status`、`git_diff`、`git_diff_staged`、`git_info`、`git_recent_commits`、`git_diff_base`、`git_branch`、`git_apply_patch_check`、`git_worktree_list`。
- write：`git_create_branch`、`git_stage`、`git_unstage`、`git_commit`、`git_apply_patch`、`git_stage_patch`、`git_unstage_patch`、`git_worktree_create`。
- destructive：`git_revert_patch`、`git_worktree_remove`，均要求显式确认参数。
- 权限：coordinator lease 可获得 `gitControl`；worker 默认没有任何 Git 工具；旧 `runShell` 兼容路径只暴露 read-only Git 工具。
- 安全：参数数组调用 `git`；设置 `GIT_TERMINAL_PROMPT=0`、`GIT_OPTIONAL_LOCKS=0`、`core.hooksPath=/dev/null`、`core.fsmonitor=false`；Git 子进程有 5 秒 command timeout；repository root 必须等于 workspace root；普通 `.git` metadata 不得逃出 workspace；受管 worktree 限定 `.intatis/git-worktrees/<name>`；非 cached apply 使用 `git apply --3way`，reverse apply 前 best-effort stage 已存在路径。

## 仍未做的部分

为了保持风险边界，本地 Git control slice 当时仍未实现：

- checkout/switch。
- merge/rebase/reset/clean。
- push/fetch/pull/remote auth。
- PR 创建、CI triage、GitHub review bot。
- Codex app 风格完整 handoff。
- `.worktreeinclude` ignored-file copy 机制。
- libgit2/SwiftGit2 in-process backend。

其中 remote fetch/pull-ff/push/switch 已在后续 remote/cloud Git 基础能力 slice 中补上；merge/rebase/reset/clean、force push、remote auth 管理、PR/CI/review bot 仍应作为后续独立 slice，先设计权限、UI、测试矩阵，再实现。

## 追加：remote/cloud Git 基础能力落地

本轮继续对照 Codex Cloud / Codex app 公开资料后，Intatis 已把 remote Git 从“未实现”推进到受控 Agent 工具原语：

- `git_remotes`：列出已配置 remote，输出遮蔽 URL 中的凭据/token。
- `git_fetch`：只接受已配置 remote name，不接受 URL remote/refspec；这是 write + network 工具。
- `git_pull_ff`：只在 clean working tree 上对当前分支执行 `git pull --ff-only <remote> <branch>`，要求 `confirmRemote` / `confirmBranch` 精确匹配。
- `git_push`：只把当前分支推送到已配置 remote name，要求确认，标记为 destructive + network high-risk；不支持 force / force-with-lease。
- `git_switch`：只在 clean working tree 上切换既有本地分支，要求 `confirmBranch` 精确匹配，不实现 discard-style checkout。

能力租约也拆开：`gitControl` 继续代表本地 Git control；新增 `gitRemote` 代表 remote Git control。coordinator 默认可获得两者，worker 默认仍无任何 Git 工具；旧 `runShell` 兼容路径仍只暴露 Git read-only 工具。

这不是完整 Codex Cloud/PR 工作流。Codex Cloud 的关键产品层能力是：在远端容器中 checkout 选定分支/commit、运行 setup、受控网络策略、完成后展示 diff 并提供 PR 入口。Intatis 当前只在本地/工作区 agent 工具层补齐 remote Git 的最小安全原语，真实 remote auth 仍依赖用户本机 Git credential helper / SSH agent，Intatis 不读取、保存或展示凭据。

仍未做：

- PR 创建、CI triage、review bot。
- merge/rebase/reset/clean。
- force push / force-with-lease。
- remote auth 管理或 GitHub/GitLab token 管理。
- Codex Cloud 式远端容器执行环境。
- Codex app 风格完整 Local/Worktree/Cloud handoff。

## 主要来源

- OpenAI Developers, Codex app features: https://developers.openai.com/codex/app/features
- OpenAI Developers, Codex app review: https://developers.openai.com/codex/app/review
- OpenAI Developers, Codex app worktrees: https://developers.openai.com/codex/app/worktrees
- OpenAI Developers, Codex cloud environments: https://developers.openai.com/codex/cloud/environments
- OpenAI Developers, Codex remote connections: https://developers.openai.com/codex/remote-connections
- OpenAI Developers, Codex CLI features: https://developers.openai.com/codex/cli/features
- openai/codex GitHub repo: https://github.com/openai/codex
- openai/codex `git-utils`: https://github.com/openai/codex/tree/main/codex-rs/git-utils
- openai/codex `apply.rs`: https://raw.githubusercontent.com/openai/codex/main/codex-rs/git-utils/src/apply.rs
- openai/codex `operations.rs`: https://raw.githubusercontent.com/openai/codex/main/codex-rs/git-utils/src/operations.rs
