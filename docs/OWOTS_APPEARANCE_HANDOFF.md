# 鬼武者外观系统：人工验收交接

记录时间：2026-09-14 22:14，北京时间。用户暂时无法人工验证，因此本阶段停止继续实机试验，等待接手。目标尚未完成，尤其不能称为自动读档修复或原生双向同步已完成。

## 2026-09-15 接手更新

Mesh 导出包原生预加载已通过：`blender-export-native-fixture-preload.json` 返回 ready/valid=true、selected=false，PFB=`mods/owots_appearance_lab/3ea18d14908baea2/ch001_00_00.pfb`。同一联合编辑工程以 `owots_appearance_lab` ID 重新导出以符合现有调试接口隔离路径限制；只新增 7 个资源，未安装 registry、未换装。安装清单 `blender-export-fixture-install.json`。早先另有 `mods/author.outfit` 的 7 个资源复制到游戏，首次调用被路径守卫拒绝，未加载；勿误认为作者命名空间的引擎加载失败。运行时仍为周期 8 采样版，CG 调查按用户要求暂缓。

用户随后确认另一段 CG 隐藏部位正常。Stage100/Area100_000、播放状态下启动 `cg-working-audit-start.json`；30 秒结果 `cg-working-audit-result.json`：LateUpdateBehavior.Post 10856、PrepareRendering.Pre 10852、UpdateBehavior.Post.BeforeHide 10852 次对象检查，可见观测与读取错误均 0。`cg-working-parts.json` 保存对象对照。这是正常过场的正对照，原 Stage202 CG 故障仍未修复，不应把特定 CG 的通过推广为所有过场通过。

最新实际安装：CG 采样候选已部署，周期 8 编译零错误，哈希 `7450e0cf2c462ad8e130ec5bdcca3c4d3e1269d9b3195604f6ac1ae2f079c936`；旧版备份 `pre-cg-audit-installed.cs`。首次 clear 因暂停未完成，恢复播放后 retry 完成，随后才替换源码。已恢复 `local.manba_declared_test` 与 `local.weapon_double`，HEAD/HAIR/CLOAK/GAUNTLET 隐藏，持久化依据磁盘配置重新开启。用户在清理期间报告四个部位全部出现，该观察受主动清理干扰，不能当作独立 CG 故障证据。

采样期间场景已从 Stage202/Area202_003 转为 Stage100/Area100_000。`cg-audit-first-result.json` 中三个阶段各 981 次调用、3924 个对象观测，visibleObservations=0/errors=0；这证明采样器可用，不证明原 CG 故障消失。下一次复现需重新发 `visibility_audit {start:true}`，30 秒后读结果；同时记录游戏播放/暂停及视觉现象。下文“未安装”是部署前历史，以上为最新状态。

当前优先故障：用户反馈 CG 播放时隐藏披风出现，Esc 暂停后消失。PID 17836 在已确认 `isPaused=false` 时采样，CLOAK 地址 `0x217830F930`、网格 `ch001_00_01.mesh` 与暂停时一致，DrawSelf/Draw 均为 false。不能据此排除帧内后续重写、独立布料渲染或另一模型实例。播放证据 `cg-cloak-confirmed-playing.json`，暂停证据 `cg-cloak-after-play-parts.json`。**尚未修复**。

源码新增限时只读 `visibility_audit`，检查 UpdateBehavior.Post.BeforeHide、LateUpdateBehavior.Post、PrepareRendering.Pre 的可见计数。候选 bundle `bundled-cg-visibility-audit/OWOTSAppearanceLab.cs`，SHA256 `7450e0cf2c462ad8e130ec5bdcca3c4d3e1269d9b3195604f6ac1ae2f079c936`，runtime 编译通过，**未安装**。已请求用户恢复 CG，让旧资源可完成清理后再部署；当前安装仍为下方 V3。部署前保留当前选择/设置，关闭记录写入，正常清理资源，备份现有源码；部署后恢复选择和原设置。不要把统计采样当作视觉验收。

Mesh 后续进展：`RE-Mesh-Editor-main/tools/appearance-rsz` 已加入可编译的离线 PFB 18 / USER 3 路径编辑工具。真实 PFB/Catalog 测试通过，扫描资源表、外部 userdata 和资源类字符串；写出后核对字段、引用、CRC、对象表。默认拒绝模板 CRC 不匹配，当前样本两处不匹配仅在实验显式覆盖下测试。详见 Mesh `docs/appearance-authoring.md`。工具尚未接入 Blender 操作器；勿将此称作完整服装工程导出。

本阶段未重载运行时插件，也未更改玩家外观。仅新增游戏本地 `natives/stm/mods/owots_appearance_lab/pfb_roundtrip` 内的两份独立测试资源并执行原生预加载，ready/valid 成功；未装备该资源。证据位于 `_validation/owots-appearance-20260914/pfb-roundtrip/native-preload.json` 与 `rsz-bridge-test-report.json`。原生模板文件留在私有验证目录，不随源码发布。

最新安装 V3：PID 17836 编译周期 7 完成、零错误，SHA256 `5b114c93d4cbe57d98ed96aa5a235c257391361030279e5d3bc49ba8f8cd33a8`。包含四分类菜单、披风/护手显示开关、声明来源确认页、V2 sidecar 读写与组合恢复候选。安装前旧插件备份 `pre-v3-installed.cs`，实际外观记录全部复制到 `pre-v3-saves`，设置备份 `pre-v3-preferences.json`。这些内容替代下文仍称 V2 写入未安装的历史状态。

当前实机：`local.manba_declared_test`（菜单名“manba · 声明隐藏版”）+ `local.weapon_double`，披风通过确认覆盖声明并显示，护手/原生头发/原生头部隐藏。保留旧 `local.manba_2` 供对照；新增测试 manifest 由 Mesh builder 生成，仍留在游戏本地。`v3-force-prompt.json`、`v3-force-cloak.json` 和 `v3-force-inspect.json` 证明确认前无切换、确认后披风显示而护手仍隐藏。真实菜单视觉与新 sidecar 保存/读档验收已向用户发出可选请求，等待其反馈，不能按接口调用结果代替人工菜单验收。

持续开发应优先继续 Mesh 工程流程、原生资源索引/PFB 结构化往返与导出，期间关注用户 V3 反馈。当前持久化和自动恢复依磁盘设置开启，原生菜单同步关闭。用户若保存，新的外观 sidecar 将写为 V2，已有 V1 原内容会另外备份；不要拿旧版插件直接覆盖安装后测试 V2 记录。

最新组合候选：PID 17836 编译周期 6 完成无错误，SHA256 `15ef55a1830e08310dff5ed75d0c42a138e2e3c1ef4c54f8ddeaf0280de0ac54`，旧包备份 `pre-compose-installed.cs`。`wardrobe_registry` 读取新旧协议，`wardrobe_select` 驱动四分类期望组合，经现有原生资源加载流程应用并设置隐藏。底层暂合并成 outfit/weapon 两次加载，逻辑选择仍按四类保留；完整四分类 UI、存档与强制提示尚未接入。

`compose-body-declared.json`：Mesh Python builder 生成的 schema 2 BODY-only manba 配置直接应用，HEAD/HAIR 隐藏，CLOAK/GAUNTLET 自动抑制，旧两倍武器保留。`compose-declared-visibility.json` 证实原生部件隐藏；`compose-body-cancel.json` 和 `compose-cancel-visibility.json` 证实取消 BODY 恢复原生显示、武器仍保留，装备编号完全相同。正常实机状态检查通过，尚无视觉/CG/读档验收。

临时 manifest 已删除，组合已完整清理，完整 `local.manba_2` 与 `local.weapon_double`、持久化/自动恢复均恢复。磁盘 preferences 当前已为 Persistence=true、AutomaticRestore=true、NativeMenuSync=false，热重载后会重新启用，后续测试不能仅在重载前关闭。四分类候选禁止开启旧写入器，防止内部合成 ID 污染 v1 sidecar。

最新持续控制候选：PID 17836 编译周期 5 完成、无错误，包 SHA256 `4d466478179774f7917a7e8adb2791077d9dee9cd1bf832c6a00d8f1603e2cb6`。`appearance_visibility` 为独立调试命令，尚未接入四分类菜单和存档。目标按 supporter 原生枚举定位，仅控制对应分支中的 Mesh 对象；钩住 DrawSelf 设置记录引擎后续请求，并在关闭隐藏时恢复。完整旧包备份 `pre-continuous-installed.cs`。

持续控制证据：`continuous-manba-body-select.json` 仅注册 BODY；`continuous-manba-body-inspect.json` 显示 HEAD/HAIR 使用原生网格且 DrawSelf=false，状态记录在 3018 次更新后 active。随后换回完整 manba 令头部实例地址改变，`continuous-rebuild-inspect.json` 确认新对象继续隐藏；`continuous-off-inspect.json` 确认关闭后恢复，跟踪数归零。原生装备 ID 未改变。临时身体测试 manifest 已删除，现为完整 manba_2 + 两倍武器，持久化/自动恢复开启、持续隐藏关闭。此为原生状态验证，不替代视觉、CG、读档和残影验收；正式声明配置仍待接入。

当前安装更新：四分类隐藏能力研究中，PID 17836 编译周期 4 已完成、无错误；包 SHA256 `e484424be4bc94c14414a38cbba3d85e195737d0f1a95d20df53b14b63369547`。新增只读部件显示检查和三秒有限显示开关探针，未把未完成的四分类协议接入旧 UI。部署前完整清理成功、备份 `pre-visibility-installed.cs`；探针结束后 `local.manba_2`、`local.weapon_double` 及本次运行的持久化/自动恢复已恢复。原生 DLL 未变化。

原生六对象 HEAD/HAIR/CLOAK/CLOAK_CLOSE/CLOAK_OPEN/GAUNTLET 的 DrawSelf 设置与精确恢复通过（两种披风子对象原值为 false，其他四项 true）。私有证据 `visibility-native-before.json`、`visibility-native-probe.json`。这仅证明原生接口短时可调用及读回，并不证明持续隐藏的视觉、CG、读档和物理表现。尚未移除 manba_2 的空 HEAD/HAIR 资源；下一步接入持续显示控制并进行该样例对照。

用户最新反馈“卡片已正常”：高亮修正版已通过人工对齐验收，取代下文此前等待确认的状态。下一项新任务是整理换装机制及怪猎荒野迁移研究文档；不代表已经开始或完成怪猎荒野适配。

卡片高亮修正：用户确认 V2 功能正常，但截图显示名称行高亮超出图片宽度。现已固定卡片名称宽度并移除横向半间距扩展；旧几何用例复现失败，修正版用例通过。清理重试完成后已安装包 `eb3a48eff4fb1c38bcc851fc5277e910e9216e605e0e4f74817618f4a6854b4c`，PID 17836 编译周期 3 完成、无错误；安装前记录的 manba_2、两倍武器及当次持久化/自动恢复开关均恢复。等待截图层面的对齐确认，不再等待“已恢复”。原生固定图片方框 DLL 尚未安装。

最新衣橱更新：按用户批准的 V2 设计部署，PID 17836 编译周期 2 已完成且无错误；包 SHA256 为 `52cead5fced1ad8ad7ced02e87e84e70f59e0655e9bf16ba55c2a583348ba755`。原 manba 服装、两倍武器和当次运行的持久化/自动恢复开关已恢复。用户明确仅需要图片预览，无图区域采用等尺寸文字占位。当前等待 V2 布局与单击/双击的人工反馈；不是此前旧独立菜单的验收结果。部署前 C# 备份为私有目录 `pre-v2-installed.cs`。

用户已反馈“mod 菜单工作正常”，独立衣橱基本操作记为人工通过；反馈未逐项覆盖图标、焦点丢失、手柄和卸载输入恢复，不扩大验收范围。游戏现为 PID 17836，新启动编译周期 1 无错误，卡片模式设置为 true。此前停机状态已结束。

槽位 4 原外观记录仍包含 `local.manba_2` 和 `local.weapon_double`，已再次私有备份。当前已成功清回原版，并通过调试命令开启本次运行的持久化与自动恢复，等待用户读取槽位 4；磁盘设置中的实验开关保持关闭。自动读档修复与原生双向同步仍未通过验收。

随后用户确认“恢复成功”。`resumed-load-events.json` 记录槽位 4 的 SUCCESS/NONE、正确身份及 `appearance_restore_finished`（issues 为空）；`resumed-auto-restore-inspect.json` 的 NORMAL 状态独立服装路径检查通过。本次从原版状态自动恢复服装与两倍武器通过人工验收，不推定所有连续读档、暂停时序或跨场景都已验证，也不认定先前超时根因已被证明。之后开启原生菜单单向同步实验，等待明确改选测试，未热重载。

## 游戏与安装状态

- 游戏进程 16848 收到正常关闭请求后退出，未强制终止；没有重新启动。
- 退出前两类外观均完成原生恢复与资源清理，外观记录写入、自动恢复、原生菜单同步均关闭。
- C# 包已安装并在原游戏进程完成编译周期 25，无编译错误。SHA256：`3dbaf4fa36ba8461cabbe9f9dd29637d1be1dd61b60ae12e6bc05ae2b1839f0c`。
- 游戏关闭后安装自定义中文 REF 输入/图标候选 `dinput8.dll`。SHA256：`4c018316ff972b27d15648548b8f48f5a9368f87d8d4a09163fe0ab7586b369e`。该 DLL 尚未启动实测。
- 设置文件使用 Slash（键盘 `/ ?` 所在键）、列表模式、三个实验开关关闭。启动时不会自动应用 MOD。

## 已验证与未验证

已有人工作证的既有能力：独立服装及正确纹理、普通状态与所测 CG 中保持、独立两倍武器、两类共存与分别取消、早期内嵌 REF 菜单。

本次自主验证通过：核心回归套件、C# 游戏运行引用编译、实际周期 25 热加载、设置文件写入、原生菜单观察钩子安装；REF Release 构建及图标 CPU/ImGui 图集测试。图集测试不覆盖 DirectX 显示。

未通过验收：独立衣橱窗口布局与输入拦截、PNG/JPEG 图标实机显示、重启恢复设置、自动读档恢复及跨场景生命周期。槽位 4 自动恢复曾超时；手动重试仅有模型路径成功证据。新增暂停计时、加载序列隔离及失败后禁止新快照等保护仍待复测。

原生菜单同步候选仅观察明确确认后取消对应 MOD 类别，未验证完整回调操作。MOD 条目、名称、图标及预览进入原生菜单未实现。不要用临时 MOD 模型编号覆盖原生存档装备编号。

## 人工回来后的顺序

1. 启动游戏进入可操作状态；先保持实验开关关闭。按 `/ ?` 所在键检查独立衣橱能否打开、关闭，鼠标可用，窗口打开时操作不穿透游戏，关闭后输入恢复。
2. 验证列表/卡片、搜索、详情、应用及分类取消；再检查 manba 服装与两倍武器的画面、CG 与返回。缺少图标的条目应有占位，不妨碍应用。
3. 确认基础界面可靠后，由开发调试配合开启存档观察，重复读取槽位 4，采集完整恢复日志和模型状态。不要先覆盖槽位 4；其正确的原始外观记录已备份。
4. 通过以上项目后，再推进原生菜单条目与预览映射；原生打开/关闭本身不能被当作用户明确改选。

Mesh 插件只整理了 [导出方案](OWOTS_WARDROBE_UI_AND_EXPORT_PLAN.md)，未修改其导入/导出代码。需要用户完善包结构、导入入口、图标来源和多部位映射选择后再实施。武器属性暂缓。

## 回退与私有证据

关闭游戏后可将原 DLL 备份复制回游戏根目录的 `dinput8.dll`：

`D:\CODE\re\_validation\owots-appearance-20260914\pre-wardrobe-native-dinput8.dll`

原 DLL SHA256：`21164c11a6d80c6ddfadd04d4cc9dc546b4f916a95734268a63445ec684adc8c`。

C# 周期 24 备份为同目录 `pre-settings-installed.cs`，如需回退将其复制为游戏 `reframework\plugins\source\OWOTSAppearanceLab.cs`。此版本同样不代表旧内嵌菜单；仅用于退回本次部署前的诊断环境。

同目录保留 `handoff-game-closed.json`、`handoff-native-install.json`、`handoff-clear.json`、`wardrobe-preferences-live.json`、`native-sync-hooks-live.json`、`persistence-first-records/` 等证据。私有游戏派生资源和存档不纳入源码发布。

## 2026-09-15 CG playback visibility recurrence
- Captured PID 63888 with existing read-only visibility_audit and inspect_part_visibility, private evidence cg-recur-173241 (use latest cg-recur-* directory if timestamp differs). User confirmed paused, playing, then paused in the same CG.
- Paused: all three sampled stages report zero visible observations. Playing: each callback reports one visible target among four pinned targets; LateUpdateBehavior.Post and PrepareRendering.Pre both see it. After pausing again: zero. UpdateBehavior.Post command snapshots still show all parts hidden. This is a frame-stage regression signal, not proof of an HQ asset or GPU cloth cause.
- Candidate adds a second DrawSelf=false enforcement in LateUpdateBehavior.Post on existing pinned targets only. It preserves native requested-state tracking via s_ownVisibilityWrite and leaves discovery/ownership/restoration in the existing Update path. Audit now separates late before/after writes and still observes PrepareRendering.Pre.
- Bundle candidate SHA256 9eab375639b8043817c31e0c1e4693588b37a78293dbc8a1d4eafee9a50c19b4; runtime-reference compilation passed. NOT installed or visually accepted. Must clear active native selections successfully before hot reload, restore exact captured wardrobe selections and persistence flags, then verify playback and cancellation. The user is preserving the paused CG scene.

### Candidate deployed and phase check
- Installed the above bundle after registry_clear retry completed; prior C# backed up to private cg-late-before-installed.cs. PID 63888 compile cycle 2: ok, zero errors.
- Body apply outlasted the client 25-second timeout but completed successfully with the same request ID at 09:41:35 UTC; completion response archived as cg-late-restore-body-completed.json. Weapon apply completed next. Exact manba_declared_test + weapon_double choices restored; persistence and automaticRestore both restored true.
- cg-late-audit-result.json: 1153 callbacks/4612 target observations. Late.BeforeHide saw 4 visible observations; Late.AfterHide and PrepareRendering.Pre saw zero, all errors zero. Game unpaused. This is a successful phase check, not yet CG visual acceptance; user asked whether CG is still playing or already ended. Cancellation/restoration regression remains to test.

### User acceptance
- User confirmed the recurring CG cloak now stays hidden with candidate 9eab3756. This accepts the reported CG case; other CG scenes and cancellation behavior are not implied. User requested returning to plugin development.

### Night static-only pause (user instruction)
- Stop runtime/human-dependent development until the user returns during daytime. No game operation performed in this static investigation.
- Cloak authoring blocked by verified GpuCloth schema CRC mismatch: file 425c28f8 vs bundled template 310efd6a. Need matching serialized layout; details and reproduction in RE-Mesh-Editor-main/docs/appearance-authoring.md. BOW 8226 and WEAPON 27540 import independently passed offline. Four-category export acceptance remains incomplete.
