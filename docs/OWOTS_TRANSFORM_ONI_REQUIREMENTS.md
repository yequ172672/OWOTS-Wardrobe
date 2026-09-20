# 鬼武者：剑之道 变身（Oni / 鬼化）外观扩展需求

版本：v0.3（2026-09-18 按实机验证结论收缩）
日期：2026-09-18
状态：已确认采用变身前预选、单次变身锁定外观；开发阶段允许直接重构，不要求旧版本兼容。

### 实现状态（2026-09-18）

- **S1 数据层已实现**：`WardrobeCategory.Transform`、schema 4 manifest（常态 `parts` / 变身 `roots`）、R4 求解、期望设置与本次快照分离、schema 4 sidecar（旧版本给出重建提示并保留备份）。核心回归覆盖域隔离、求解规则、快照隔离与旧格式拒绝。
- **S1 运行时界面已实现**：第五分类页签、内置 `native.transform.default` 原版条目；选择只更新期望设置并提示「下次变身生效」，不触发常态模型重建。
- **P0 实机验证已完成（2026-09-18）**：
  - P0-A 只读观察：Oni resident 对象在常态已实例化并跨鬼化复用（地址稳定）；`BODY/HEAD/HAIR_ONI_CHANGE` 为独立对象；鬼化不改变常态装备与模型 ID；`cPlayerCharacterEntity.OniSupporter` 提供 `IsOniModeOn`/能量与开始/结束事件。
  - P0-B 隐藏 Oni：隐藏可行且可持续（250ms 维持、退出无残留）；但游戏通过材质通道隐藏常态，单纯隐藏 Oni 无法「保持常态外观」，实测鬼化期间身体隐形。
  - P0-C resident 重载：`releasePlayerResidentModel` + `addPlayerResidentModel` 可安全调用，但**不会重建已实例化的 Oni 对象**；「运行时替换 resident prefab」路径不成立。
- **v0.3 范围收缩（用户决策）**：放弃「保持常态外观」策略并取消总闸。规则为：**选择了变身外观 → 鬼化使用该外观；未选择 → 使用游戏自带鬼化外观**。服装系统只更改鬼化外观，不控制鬼化显示本身。
- **P0-D 鬼化骨骼重定向（2026-09-20 实机验证成功）**：Oni 骨架与常态同拓扑（OniBody 子树匹配 2B 声明的 90/93 关节名）；`PollOniRebase` 在鬼化期间对 Oni 关节应用与常态相同的休止修正，退出时还原。用户确认常态与变身 2B 体型一致。详见 `_validation/transform-oni-20260918/P0-D-ONI-SKELETON-zh-CN.md`。
- **2026-09-20 暂缓决定（用户）**：运行时变身外观应用（live Oni mesh/material 替换）在实机测试中导致崩溃（`_validation/transform-oni-20260918/crash-20260920-runtime-swap.dmp`）与模型消失，已禁用；鬼化骨架重定向的 Transform 通道未见视觉生效（疑被 `via.motion.Motion` 802 关节系统覆盖，待改走 Motion 通道）。第五分类在 UI 中明确标记为「暂未支持」：选择会被保存，但不改变游戏内的鬼化外观。**全部实现代码保留**待下一轮；文件级硬替换已从游戏目录移除。
- **待验证**：把 MOD 外观应用到 live Oni 对象的具体通道（mesh/material 替换与 AfterImage 缓存刷新，或找到对象重建触发点）；`ModelPartsManager2.setPartsDisp` 的部件索引能力。
- **S2 部分实现**：转换器已发布 schema 4（常态四分类可用）；Oni 资源识别与 `category: transform` 发布仍待实现。
- 本文其余部分仍是需求与可行性记录；未标注完成的内容不表示已实现或已实机验证。

### 本轮已确认的范围

- 鬼化是由玩家积攒资源后释放、具有时间限制的特殊状态；触发条件、资源消耗和持续时间由游戏管理。
- 不要求变身期间实时更换外观。变身前选定方案，单次变身使用固定方案；中途修改只影响下一次变身。
- 当前处于无正式用户的开发阶段，可以更改分类、manifest、存档与运行时架构；不保留旧格式读取、迁移、双写或旧接口适配作为交付要求。旧开发样本可以重新转换。
- 取消历史格式兼容不取消运行失败恢复：加载失败、死亡、读档和对象销毁时，仍须撤销本次外观接管并正确释放自有资源。

## 1. 目标

在现有四分类外观衣橱（身体 / 披风 / 护手 / 武器）之外，新增第五分类「变身」，让玩家可以：

1. 在变身前为 Oni 鬼化选择独立外观，与常态外观自由组合；
2. 选择后鬼化使用衣橱外观；未选择时使用游戏原生鬼化外观；服装系统不控制鬼化显示本身；
3. 让包含变身资源的 MOD 注册变身条目；
4. 把游戏默认 Oni 外观作为内置变身条目提供。

## 2. 调研结论

### 2.1 游戏侧（变身 = Oni 鬼化）

- [已确认] 鬼模型是**独立 resident prefab**，不是 PARTS_TYPE 部件：
  - `onibody.pfb` / `onihead.pfb` 位于 `natives/stm/gamedesign/action/player/_prefab/`（`OWOTS_STM_Release.list`）。
  - `app.PlayerResidentPrefabID.TYPE_Fixed`：`MAIN=13956, PLAYER_UI=16130, ONI_BODY=26881, ONI_HEAD=9209, SKILL_0_HALO=25946, SKILL_0_MASK=11718`（生成程序集反编译）。
  - `app.PlayerPartsDef.PARTS_TYPE` 无 ONI 槽位（`BODY…BOW, MAX=13`）。
- [静态证据] `app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT` 含 `BODY_ONI_CHANGE / HEAD_ONI_CHANGE / HAIR_ONI_CHANGE`；枚举成员存在不等于已确认实机对象的创建与销毁时机。
- [静态证据] 生成程序集提供以下方法包装，属于待验证的接管入口；不能据此断言 resident 可被安全替换：
  - `app.PlayerManager.addPlayerResidentModel(PlayerResidentPrefabID.TYPE_Fixed, GameObject, object)`
  - `app.PlayerManager.releasePlayerResidentModel(PlayerResidentPrefabID.TYPE_Fixed)`
  - `app.PlayerManager.changePlayerModel(IList<PlayerPartsDef.cChangeArgument>)` 与 `changePlayerModel(PARTS_TYPE,int,GameObject,GameObject,bool,object)`
  - `app.cPlayerOniSupporter.requestOniChange / startOniChange / setOniChangeOn / setOniChangeEnd / requestStopOniChange / isOniChangeModeOn / updateVisiblePlayerModel / updatePlayerModelMaterial`
  - `app.cPlayerGameObjectSupporter.changeGameObjectVisible / setVisiblePlayerModelBoth / isNeedOniModel / convertResidentPrefabTypeToGameObjectType`
  - 以上均在 `REFramework.NET.application.dll` 生成接口中（本机已反编译核对）。
- [已确认] 每个体型有 `app.user_data.PlayerModelVisualSettingParam.cBodySetting.IsInvisibleOniModel`（运行时存在；离线 `rszoniwots.json` 模板缺该字段）。
- [静态证据] `app.PlayerDef.ONI_TYPE = ALL / EYE / ARM / LEG / MAX`，并存在 `cPlayerOniSupporter`、`app.motion_track.PlayerOniChange` 与 `pl_oni` 特效库（32 个 `19_pl_oni_*.efx`）。枚举对应的部位、时序及状态关系由 P0 观察确认，不把枚举值作为衣橱外观分类。
- [静态证据] 已检查的 `cBodySetting` 包含布尔 `IsInvisibleOniModel`，未找到 Oni 模型 ID；已有文件清单和 resident ID 指向一对鬼模型。尚不能据此排除游戏内部其他选择逻辑。
- [已确认] 原生服装菜单 `app.GUI030106.CATEGORY` 为 `INVALID/PL_SWORD/PL_CLOAK/PL_GAUNTLET/PL_BODY/NPC_00/NPC_01/MAX`，**没有 Oni 栏位**，玩家无法在原生菜单选择鬼外观。
- [已确认] MOD 已可自带 `onibody.pfb / onihead.pfb`：2B 包内 `onibody.pfb` 已把绑定换成 `Vyaomo_V_00.mesh`（`_validation/2b-skeleton-static-audit-20260915/worker-inspect/custom_onibody.result.json`）；当前转换器把它判为未消费资源，运行时未接管。
- [实机未验证] 鬼化时常态 `BODY/HEAD/HAIR` 是隐藏还是被替换；`*_ONI_CHANGE` 是否由 `onibody/onihead.pfb` 实例化；外部写入可见性是否会被每帧逻辑重置。
- [静态证据] `onihead.pfb` 同时引用 `ch001_50/10` 的头部与 `ch001_50/20` 的头发模型；已有解析记录包含 `OniHead`、`OniHair` 两个 GameObject。因此三个可见目标不等于三个独立 prefab。
- [实机未验证] 是否能在变身前或安全的进入阶段准备/接入 MOD resident，并由下一次鬼化使用；需要接管的时间点和是否必须预先替换缓存均未知。两个 PFB 没有直接引用 `fbxskel`，骨架来源也待验证。
- [已知风险] 早期在现有对象上直接 `setMesh + Material` 的实验约 9ms 后崩溃（`app.AfterImageMaterialParamRecorder.record`，见 `docs/OWOTS_APPEARANCE_RUNTIME_RESEARCH.md`）。优先验证 resident 生命周期通道，不以直接重绑网格作为默认实现；普通 `changePlayerModel(PARTS_TYPE, …)` 不能直接视作 Oni 接口。

### 2.2 衣橱侧（四分类现状与改动面）

- 分类枚举：`appearance-core/WardrobeComposition.cs:10` `WardrobeCategory { Body, Cloak, Gauntlet, Weapon }`。
- 每类部位白名单：`WardrobeComposition.cs:31-37`；固定优先级：`:29-30`。
- 应用是纯外观：MOD catalog → `AddNativePart` / `BeginOutfit`（`OWOTSAppearanceLab.cs:3801-3863`），不写原生装备/属性。
- 内置条目：`RefreshNativeEntries`（`OWOTSAppearanceLab.cs:2535-2665`），源 `app.user_data.CostumeItemTable._ItemList`；名称 `NativeItemName`（`:2522`）；图标 `tex_<cat>_NN_imlm4.png`（`:2659`）。
- `cBodySetting` 已读取：`IsInvisibleHead`、`IsVisibleCloak`、`FixHairID`、`FixGauntletID`（`:2445-2458, 2496-2500, 2622-2632`）；**未读取 `IsInvisibleOniModel`**。
- 隐藏原生部件的白名单 `s_visibilityParts = HEAD, HAIR, CLOAK, CLOAK_CLOSE, CLOAK_OPEN, GAUNTLET`（`:2188`，校验在 `:2215`）——**不含 ONI 对象**，需扩展。
- 标题旁开关先例：披风/护手 `显示##<category>` 复选框（`:1028-1036`）。
- 分类请求解析硬编码四个字符串（`:1996`）；共享高亮/隐藏/强制确认只认 Cloak/Gauntlet（`:2009`）。
- 存档：`WardrobeSaveStore.Freeze` 硬编码 `Requested.Count != 4`（`appearance-core/WardrobeSaveStore.cs:27`）；版本按 `Equipment == null ? 2 : 3`（`:104`）。
- 旧投影 `AppearanceKind { Outfit, Weapon }`：`appearance-core/AppearanceRegistry.cs:10`。可在此次重构中移除；不为第五分类增加新的旧投影桥接。
- `WardrobeSelections.FromLegacy` 会把非武器分类关联到旧服装，`SyncActiveMods` 也含类似投影；不应只修改枚举和 `Count == 4`。这些路径可删除或直接重写，无须承担旧档迁移。
- 当前 manifest 部位强制包含 catalog/PFB，且提供的部位不能被自身隐藏；该结构不适合直接表达 resident 根与内部隐藏目标。`WardrobeRegistry.ApplyModInfo` 目前只处理 schema 2，也不能直接作为新协议的现成覆盖层。
- `MotionRebase` 持续按常态 BODY 修正角色骨架，尚无鬼化状态域判断；必须验证进入鬼化时的骨架归属，并保证同一骨架同时只有一个外观方案负责修正。
- 当前转换器没有 Oni 专属条目识别与发布流程。

## 3. 需求草案

### R1 第五分类「变身」

- 新增第五个分类按钮与条目列表，界面名「变身」，协议暂用 `category: "transform"`，游戏适配层使用 Oni 命名。
- 变身条目描述一套可解析的变身外观，资源根按 `ONI_BODY / ONI_HEAD` 两个 resident prefab 管理；头、头发等是内部可见性目标，不重复实例化 `onihead.pfb`。
- 不要求作者提供全部模型。身体、头、头发或纹理的局部替换都允许，未修改内容引用原版。完整性指最终依赖可解析，不指输入包必须包含全部文件。
- 变身分类拥有独立选择、独立存档项、独立显示/隐藏域；不提供常态 body/cloak/gauntlet/weapon 槽，常态分类也不提供鬼槽。

### R2 变身条目的隐藏声明

- 变身条目支持声明隐藏头发、头；「兜」作为期望的可选目标，只有确认存在可单独控制的对象或渲染目标后才开放。
- 隐藏只在**鬼化状态域**内生效：变身条目的 hideParts 不影响常态外观；常态四分类的 hideParts 也不破坏鬼模型。
- 资源根的提供与内部目标的隐藏分别表达，避免「必须提供头」与「允许隐藏头」在配置校验中冲突。不能直接把鬼化 HEAD/HAIR 混入常态的同名隐藏集合。
- 解析规则在 P0 与转换器适配中确定；若「兜」与其他部分处于不可分离网格中，明确报告不能独立隐藏，不通过猜测子网格或强行删除实现。

### R3 MOD 识别与转换

- 从原版 `onibody/onihead` 沿 Mod 覆盖后的依赖图识别修改，包括只替换依赖 mesh/mdf2/tex、没有自带 PFB 的输入。按实际资产生成变身条目；原版与 Mod 合并后仍缺必要依赖才拒绝。
- 没有修改变身资源的 Mod 不生成变身条目，也不自动推断作者意图。
- 保留现有原则：不读取来源 Mod 的描述、文档或脚本来推断行为；规则声明来自明确的服装系统配置，转换器只迁移模型及附属资产。

### R4 变身外观选择与单次锁定

求解规则；在一次变身开始时求解并锁定：

| 变身选择 | 本次变身行为 |
| --- | --- |
| 已选择 | 使用选中的变身外观；选中内置原版条目也属于显式选择 |
| 未选择 | 使用游戏原生鬼化外观 |

- 不提供总闸或显示控制；服装系统只更改鬼化外观，不介入游戏原生的鬼化触发、显示与结束。
- 变身前允许选择和准备外观，不要求重启游戏。锁定边界为进入鬼化时最早可验证的安全时间点。
- 从进入阶段到结束清理完成，本次使用的变身条目、隐藏目标和骨架配置保持固定。
- 鬼化中选择另一个变身外观，只更新下一次的期望设置；当前变身不替换模型、不重新绑定、不销毁在用资源。界面此时仅提示「下次变身生效」。
- 为避免常态体型方案在途中变化，本版建议将鬼化期间的常态衣橱外观修改也排队到结束后应用；不拦截游戏自身装备切换或改变玩法逻辑。
- 变身结束后，恢复常态衣橱处理，准备下一次选择；下一次开始才应用新的变身方案。

### R5 内置变身条目

- 把游戏默认 Oni 外观（`onibody` + `onihead`，HQ 变体若存在）注册为内置变身条目，与 MOD 条目在同一 UI 展示。
- 名称优先复用可确认的游戏本地化消息；没有对应条目时使用插件自身的「原版鬼化」本地化文本。图标可使用内置占位图，不作为功能验证门槛。

### R6 存档与恢复

- 建议将五分类期望选择保存到衣橱 sidecar，随对应游戏存档恢复。当前变身的对象、资源句柄和锁定快照只属于运行时，不写入 sidecar。
- 可直接定义新格式，旧 `v1/v2/v3` 配置和 sidecar 无须读取、迁移、双写或兼容；旧开发配置可以重新生成。具体版本号在新协议定稿时分配。
- 旧格式不支持时给出重建配置提示，不自动读取为新格式，也不自动删除历史文件。此项不涉及修改或删除原生游戏存档。
- 读档造成角色重建时丢弃旧运行时快照、撤销自有接管。若新角色已处于鬼化中，且没有可确认的安全接入点，本版允许保持原生表现直到本次结束，下次鬼化再应用选择。
- 新实现不依赖 `AppearanceKind` 二分类或旧 outfit/weapon 投影；相关路径可直接替换。当前资源有效性检查和失败清理仍需保留。

### R7 运行边界

- 纯外观：不写原生装备、属性、能量、玩法数值或原生存档。
- 沿用现有本地化（`T(zh,en)` + `s_chineseUi`）、错误提示、生命周期与失败回退规范；切换/读档/场景重建/过场后不残留半套资产。
- 变身资源、触发条件、持续时间和结束由游戏管理。正式功能不调用 `requestOniChange` 来强制触发、延长、取消或重置鬼化；验证使用玩家正常触发流程。
- 外观未准备好时，不能阻塞游戏变身、补充能量或重新触发；本次使用原生外观并提示原因，期望选择保留到下次。方案仍在加载时不在鬼化中途补上。

### R8 转换器与文档

- 转换器新增变身文件识别、依赖闭合、变换/骨架处理与 `category: transform` 发布；更新 `OWOTS_MOD_AUTHORING.md`、schema 说明与 Mesh 工作区类别文档。
- 探针结论、失败证据与验收记录按现有约定放入工作区 `_validation/`。

## 4. 协议与架构建议

### 4.1 数据表达

- 新 manifest 可以按分类使用不同的资源结构：常态描述原生部件，`transform` 描述 `ONI_BODY / ONI_HEAD` resident 根及鬼化域内的隐藏目标。最终字段名在 P0 确认对象映射后定稿，不沿用 `catalog + PARTS_TYPE` 来伪造鬼槽。
- 不再提供常态身体的「保持外观」声明或总闸；披风、护手和武器不参与变身。
- 求解统一为 R4 规则：有显式变身选择 → 该选择；未选择 → 游戏原生。
- 声明与部位隐藏使用同一份正式配置作为权威来源。若保留 INI 编辑入口，应重写为新配置的明确覆盖层；不要求复用旧 schema 2 的覆盖实现，也不扫描来源 Mod 的普通 modinfo 内容来推断规则。
- 类别名暂用 `transform`，期望选择随衣橱 sidecar 保存。这些是设计默认值，不是阻止 P0 只读观察的待答问题。

### 4.2 期望设置与本次变身分离

| 状态 | 允许的外观处理 |
| --- | --- |
| 常态 / 准备中 | 接收期望设置并准备私有资源；过期加载结果不能覆盖更新后的选择。只在已验证的安全窗口接入 resident |
| 开始变身 | 按游戏事件锁定本次方案；准备不足则本次使用原生方案，不延迟或重触发游戏变身 |
| 鬼化中 | 维持锁定方案，响应游戏自身的可见性/材质阶段；界面修改进入下一次期望设置，不换当前模型 |
| 结束 / 清理 | 退出本次接管，恢复常态外观处理，清理本次自有资源，再准备下一次方案 |

- 本次快照包含选中条目、隐藏目标、骨架来源和在用资源所有权。后续配置修改、资源重扫或加载完成回调不能改写该快照。
- P0 已证明 resident 在常态即已实例化并跨鬼化复用；资源准备时机不受限于鬼化开始瞬间。把 MOD 资源应用到 live Oni 对象的通道仍待验证（mesh/material 替换或对象重建触发点）。
- 常态与鬼化分别生成应用计划，统一协调角色生命周期。允许删除旧双分类投影，并重构 registry、保存与执行路径；无需让 Oni 穿过常态 `BeginOutfit`。
- 保留现有声明穿戴及手动附件覆盖的产品行为，实现结构可以重写。正常变身结束后恢复常态计划；死亡或读档导致对象销毁时，只清理仍有效的自有引用，不访问旧角色对象。
- 若常态与 Oni 共用角色骨架，须在进入/退出边界明确移交修正责任；若使用不同骨架，则分别绑定到实际对象。不能让常态 BODY 的 `MotionRebase` 无条件影响 Oni。
- 不为进入前预选追加新限制：不要求每换一个变身外观都重启游戏，不要求同一次鬼化中实现 A → B 的热替换。

## 5. 已确定范围与待验证事项

- 用户已确定：变身前预选，中途修改不生效；允许破坏旧协议并直接重构；放弃「保持常态外观」与总闸，只保留「选中变身外观 / 未选中用游戏原生」两种行为。
- 本版设计建议：中途修改保留为下次设置；常态衣橱修改在鬼化期间排队；期望选择随 sidecar 保存；求解使用 R4 的统一规则。
- 仍待技术验证：把 MOD 外观应用到 live Oni 对象的安全通道（含 AfterImage 缓存刷新）、`ModelPartsManager2.setPartsDisp` 的部件索引能力、头/头发/兜的独立隐藏；鬼化骨骼重定向已实机验证，退出还原随现有 rebase 机制执行。
- 未要求：鬼化期间热切换、保持常态外观、旧格式迁移、旧插件兼容、原生服装菜单的第五页签、能量或持续时间控制。

## 6. P0 实机验证计划

原始游戏资源只读，诊断证据落工作区 `_validation/`。只读观察与受控状态修改分别记录，不能把隐藏/注入/释放称为只读操作。验证通过玩家正常积攒资源并触发鬼化，不使用强制变身调用代替正常时序。

### P0-A 只读观察

1. 对比常态、进入、鬼化持续、退出和结束后的 `BODY_ONI_CHANGE / HEAD_ONI_CHANGE / HAIR_ONI_CHANGE`：对象身份、资源路径、父子关系、可见性与有效性。
2. 找到 resident 何时准备/缓存、何时实例化、是否跨多次鬼化复用；确认下一次外观能在何时接入。
3. 观察常态 BODY/HEAD/HAIR、披风、护手和武器的归属，以及 `updateVisiblePlayerModel / updatePlayerModelMaterial / setVisiblePlayerModelBoth` 的覆盖顺序。
4. 核对鬼化时骨架来源、`IsInvisibleOniModel` 与常态体型修正的关系；枚举或布尔字段存在仅作为观察线索。

### P0 已完成结论（2026-09-18）

- **P0-A 只读观察（完成）**：Oni resident 对象常态已实例化、地址跨鬼化稳定；`BODY/HEAD/HAIR_ONI_CHANGE` 为独立对象，头/发可分别控制；鬼化不改变常态装备与模型 ID。详见 `_validation/transform-oni-20260918/P0-A-FINDINGS-zh-CN.md`。
- **P0-B 隐藏测试（完成）**：隐藏 Oni 可行且可持续、退出无残留；但游戏通过材质通道隐藏常态，「保持常态外观」不可行——v0.3 已放弃该策略。详见 `P0-B-FINDINGS-zh-CN.md`。
- **P0-C resident 重载（完成）**：`releasePlayerResidentModel` / `addPlayerResidentModel` 可安全调用，但不重建已实例化的 Oni 对象；「运行时替换 resident prefab」路径不成立。详见 `P0-C2-RESIDENT-FINDINGS-zh-CN.md`。

### P0-C 剩余验证（MOD 外观应用）

- 把 MOD 外观应用到 live Oni 对象的通道：mesh/material 替换（含 AfterImage 缓存刷新）或对象重建触发点。
- 跨次 A/B：选 A 触发鬼化使用 A；中途改选不影响本次；下次使用新选择。
- 资源未就绪、缺资产、死亡、读档与场景重建：不阻塞游戏变身、不改变玩法状态、不留下半套对象；恢复原版引用时不得误释放游戏拥有的对象。
- 检查动作、蒙皮、材质阶段、Chain2、残影和退出后的骨架恢复。

**门槛**：MOD 外观应用通道未通过实机验证前，不得作为已完成运行时功能发布；单纯的接口/数据层重构可独立进行。

## 7. 分阶段交付

- **S0 最小验证**：完成 P0-A，分项验证 P0-B/P0-C，确定状态边界、resident 所有权和骨架责任。
- **S1 新协议/数据层**：重构分类、规则、registry 与 sidecar；分离常态部件和鬼化 resident。移除不再需要的旧投影与迁移分支，验证期望设置/本次快照的隔离。
- **S2 转换器**：沿 Oni 依赖图识别完整、局部及纯纹理替换，补齐原版引用，保留不确定占位，按新协议发布并去重。
- **S3 运行时与 UI**：进入前准备、单次锁定、结束恢复、待下次设置和第五分类界面；提供简短的「下次变身生效」提示。
- **S4 验收与文档**：常态 × 变身组合、跨次 A/B、连续多次变身、资源未就绪、死亡/读档/场景重建、骨架恢复与自有资源释放；同步更新各级 AGENTS.md。

## 8. 风险与处理

1. 取消中途热替换显著缩小复杂度，但进入前 resident 接入仍需证明。若游戏不支持可靠接入，说明具体阻碍，再讨论范围调整，不自行降级为必须重启的文件级替换。
2. 离线 RSZ 模板缺字段：优先使用现有路径保留式处理和运行时只读证据，不按缺失模板序列化未知字段；生成接口存在也不代表调用时序已经安全。
3. 两个 PFB 不直接引用 `fbxskel`，不能推断它们没有骨架或沿用普通 BODY 的体型合同；拓扑、姿态和修正归属需要独立验证。
4. 旧格式兼容不在范围内；当前新格式的配置校验、玩法隔离、失败恢复和退出清理仍是验收要求。
5. 游戏没有原生 Oni 服装栏位，本需求只实现 REF 衣橱 UI。默认文字/图标不阻塞模型与生命周期验证。

## 9. 证据索引

- 生成程序集：`D:\gametest\steamapps\common\OnimushaWotS\reframework\plugins\managed\generated\REFramework.NET.application.dll`（`app.PlayerResidentPrefabID`、`app.PlayerManager`、`app.cPlayerOniSupporter`、`app.cPlayerGameObjectSupporter`、`app.user_data.PlayerModelVisualSettingParam`）。
- 游戏文件清单：`mod-converter/runtime/OWOTS_STM_Release.list`（`onibody.pfb.18`、`onihead.pfb.18`、`playeronichangeparam.user.3`、`playervisualparam.user.3`、`pl_oni`）。
- 鬼模型 PFB 绑定：`_validation/2b-skeleton-static-audit-20260915/worker-inspect/game_onibody.result.json`、`game_onihead.result.json`、`custom_onibody.result.json`。
- 体型规则：`mod-converter/runtime/owots_body_rules.json`（`IsInvisibleOniModel`）。
- 类型布局：`mod-converter/runtime/rszoniwots.json`（注意：运行时类字段多为空，`cBodySetting` 缺 3 个字段）。
- 现有四分类实现：`appearance-core/WardrobeComposition.cs`、`WardrobeSaveStore.cs`、`reframework/plugins/source/OWOTSAppearanceLab.cs`。
