# YoRHa 2B 骨架修复 companion（测试候选）

这个小包是现有 `yorha_2b_base_static` 与
`yorha_2b_alternate_static` 衣橱包的配套补丁。它只在衣橱桥报告这两个精确
ID、精确 BODY/HEAD/HAIR 路径、实际 BODY mesh 和当前控制角色都匹配时工作，
把角色根节点的 `via.motion.DummySkeleton` 临时切到该变体私有的 `/90`
`FbxSkeletonResourceHolder`。它不包含衣橱静态资源，也不能单独替代静态包。

## 文件和前置条件

1. 使用包含通用快照别名
   `_G.owots_appearance_lab.get_adapter_snapshot()` 的当前 OWOTS 测试运行时。
   本轮配套运行时来源为
   `_validation/scarlet-manual-migration-20260915/adapter-runtime-release-20260916/OWOTS-Appearance-Test-20260915.zip`
   （SHA-256：`18708febc3e806b843d9e3232a910363b587c6d30b965bc4c90bc0560337e97f`）。
   运行时包本身的安装说明和依赖以其 README 为准。
2. 先安装匹配的 2B 静态衣橱包，再把本 companion ZIP 的内容合并解压到
   **游戏根目录**，保留 `natives/stm/...`、`manifest/...` 和
   `reframework/autorun/...` 的目录结构。不要把 `manifest` 文件单独放到
   `mods` 目录。
3. 为得到真实的原版 `/90` 基线，测试时请由用户手动停用原作者提供的全局
   替换 PAK/loader 版本。这个 companion 不会自动删除、改名、禁用或覆盖
   任何用户 MOD；有冲突的 MOD 由用户自己选择停用并记录。
4. 这个候选包只复制同一个经过审计的 93 骨骼、v7 `FBXSKEL` 两份，分别放在
   两个变体的私有路径。它不捆绑游戏 PAK、存档、日志、生成 SDK 或原作者
   loader。

## 手动验收

启动游戏并进入可以控制角色的场景，在现有衣橱界面选择一个精确的 2B
变体。适配器**默认是 `diagnostic` 只读模式**，会先在
`UpdateMotion` 游戏线程上同步读取并记录真实角色基线，不会替换 holder。确认
日志和 A/B 条件正确后，测试者再在 REFramework Lua 控制台调用
`_G.yorha_2b_skeleton_adapter.set_mode("apply")`（或
`enable_apply()`）；普通测试的主入口是打开 REFramework 菜单中的
**“Enable 2B independent skeleton (experimental)”** 复选框（默认关闭），
勾选后即排队启用 `apply`。控制台调用仅作为开发备用入口。模式切换本身不做
native 写入，真正绑定仍只发生在下一次游戏线程回调。开始绑定后会
等待 Motion 重建，只有以下条件全部满足才会报告 `active`：

* `status` 中 `active_mod_id` 与选择一致，`owned_rig_path` 是对应私有路径；
* 当前根节点仍由唯一的 Motion/DummySkeleton 组件拥有，BODY 是角色后代，
  且唯一 mesh 路径与 manifest 一致；
* Motion 已构造，关节数为 93，关节名顺序等于绑定前基线；
* 关键关节的位置等于审计过的私有 `/90` 数据。

适配器会在 REFramework 数据目录（通常是
`游戏根目录/reframework/data/yorha-2b-skeleton-status.json`）写入
`yorha-2b-skeleton-status.json`。只读模式的
`diagnostic_sample` 记录用于首次核对的原始 holder 和 93 关节基线；启用修复
后，其中
`events` 的 `skeleton_requested` 记录绑定前的原始 holder 路径及关键基线
位置，`active_diagnostics` 记录私有 holder 路径和实际新骨架位置；这两项
用于判断“路径切换成功”与“体型实际生效”是否一致。`runtime_verified=true`
只表示当前 lease 已在本次运行中完成这些检查，不表示历史运行成功。
诊断 JSON 按状态改变立即写入，并在同一状态下约每 60 个游戏帧刷新一次，避免
每帧写盘；绑定和恢复的 native 校验仍逐游戏帧执行。

切换菜单时，如果快照仍是同一 `sessionId` 和 body ID 的 `menu_paused`（即使
暂停快照自身的 `selectionRevision` 前进），适配器会保持 holder 且不写 native；
恢复游戏后会重新检查完整角色身份、路径和最新 revision。取消选择、选择 body
改变、角色改变或出现错误时，它会先把
原 holder 写回，然后等待 Motion 重新构造 93 个基线关节，完成验证后才释放
引用并产生 `restored` 事件。

## 失败时的行为

缺少桥、路径/mesh 不匹配、忙碌切换、SDK contract 不匹配、foreign holder、
关节拓扑错误、Motion 重建超时或恢复验证失败都会 fail closed。恢复失败时
状态为 `quarantined`，保留 resource/holder 引用并阻止自动重新绑定；公开的
`yorha_2b_skeleton_adapter.retry_restore()` 只会排队请求，真正的 native 操作
仍由下一次 `UpdateMotion` 游戏线程执行。

`on_script_reset` 可能来自 UI/render 线程，适配器不会在那里调用 holder
setter。若没有后续游戏线程 callback，状态会明确写成
`script_reset_restore_unverified`，不会声称已经恢复。脚本 reset 后 Lua 的
resource/holder 引用可能随 LuaState 垃圾回收而失效，不能假定旧 holder 会一直
被 pin；此时必须完整重启游戏，才能重新建立干净的基线。不要把脚本重新加载
当作恢复手段，也不要通过 MCP/ThreadPool 跨请求读取或写入托管对象，更不要在
状态未验证时强行重载。

## 当前限制

这是一个有边界的测试候选，不是通用骨架转换器，也不修复 cloth、动画重定向、
其他角色或任意 PFB。离线包格式/路径/93 骨骼校验可以自动通过，但当前交付
仍需在关闭全局替换 MOD 的条件下完成一次受控的游戏内 A/B，比较原版和 2B
变体的 holder 路径、Motion 状态、关键关节位置及可见体型。
