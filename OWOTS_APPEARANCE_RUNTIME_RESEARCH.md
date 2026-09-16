# OWOTS 外观系统运行时调查

日期：2026-09-14。需求以 OWOTS_APPEARANCE_SYSTEM_REQUIREMENTS.md 为准。

## 已验证

- 基于用户中文版 REFramework 的 C# 运行时修复已安装并重启验证。SDK 安装后触发的引用集合问题已修复：全部插件编译状态 ok，错误 0，40 个 MCP 工具可用。源码修复位于相邻 REFramework-cn/csharp-api/REFCoreDeps/Compiler.cs；原 DLL 已备份到工作区 _validation。
- OWOTSAppearanceLab.cs 在 UpdateBehavior.Post 上处理 PID 与唯一请求 ID 绑定的探针。没有调用装备、属性或存档写入接口。
- `app.cPlayerCatalogHolder.getPlayerPartsList` 返回可修改字典。BODY=0，WEAPON=6。
- BODY 临时增加 ID 900001，引用原 ID 7482 的 Prefab：字典插入成功，原生 `PlayerManager.isExistsPrefab` 返回 true；finally 删除成功，条目数 9 → 10 → 9。
- WEAPON 临时增加 ID 900002，引用原 ID 27565 的 Prefab：插入、原生查找、删除均成功，最终条目数恢复为 9。
- 两项探针执行前后角色装备 ID 相同：body=16365，weapon=27531，head=4202，hair=8657，gauntlet=1368，cloak=15318。此证据只说明目录探针没有改变装备，不等于完成外观切换或验证武器所有属性。
- 独立 `mods/owots_appearance_lab/body_catalog.user` 通过 `CreateUserData("app.user_data.PlayerPartsList", path)` 成功反序列化；其中一条 Prefab 引用指向独立 MOD 路径，Exist=true。
- 对该独立 Prefab 设置 Standby=true 后，跨帧检查得到 Ready=true、Valid=true。探针随后设置 Standby=false 并释放自己持有的 UserData 引用，没有实例化场景对象。由此验证额外 UserData 和额外 Prefab 可以通过当前 REF 的通用松散文件加载路径加载，无需修改 C++ loader。
- 样本只移动了 Prefab 本身，其内部网格、材质、骨骼和物理依然是原生引用，不把这一结果扩大为全部独立资产已验证。
- 编译器已增加可运行回归测试 `REFramework-cn/csharp-api/REFCoreDeps/tests/CompilerRegression.csproj`。使用游戏部署的 Roslyn DLL 测试生产引用选择方法，运行时生成的枚举代理及消费它的插件均编译成功。

原始证据在工作区 `_validation/owots-appearance-20260914/body-registration.json`、`weapon-registration.json`、`catalog-title-screen.json`。不把游戏资源加入源码仓库。

额外资源证据：`independent-userdata.json`、`independent-prefab-load.json`。实验资产及生成脚本仅保留在 `_validation/owots-appearance-20260914`，游戏部署位置为 `natives/stm/mods/owots_appearance_lab`，没有覆盖原生路径。

## 尚未验证

### 现成 MOD 的独立化与直接绑定失败（2026-09-14 后续）

- 输入为用户提供的 `D:\mod\2_re\guiwuze\manba_2\modOutput\manba_2`，原目录未改动。独立测试副本在 `_validation/owots-appearance-20260914/manba-independent`，16 个资产文件已部署到游戏内专用 MOD 路径，没有覆盖原生资源。
- 包含身体/头部/头发 mesh、mdf2，以及两张纹理的普通/streaming 文件；原包没有独立骨骼或物理文件。通过相同长度的 UTF-16 路径替换保留二进制偏移，转换报告记录每个输入/输出 SHA256。此工具是私有测试配方，不宣称是通用 MOD 转换器。
- 身体 Prefab 和头发 Prefab 的预加载均得到 Ready/Valid=true。冷加载头部时首次 CreateUserData 返回的目录数组尚未填充；探针已改为跨帧等待，未预热的头发目录验证通过。头部仍需完成最终预加载复测。
- 实际 Body、Head、Hair 是当前 Player_00 的 Transform 子对象。Context.Parts 中部分对象已无组件，不应直接使用这些旧部件引用作为换装目标。Transform.Children 的通用枚举包装报 Method not found，已改用 Child/Next 有界遍历。
- 六参数 `PlayerManager.changePlayerModel` 与列表重载不同；列表重载的反汇编显示其走装备状态写入流程，不适合作为纯外观接口直接调用。工作区保留原生调用点和反汇编供后续调查。
- **直接 setMesh + Material 实验失败，不能算换装成功。** 三个组件回读到了独立 MOD 路径且装备 ID 不变，但约 9 毫秒后游戏崩溃。故障栈位于 `app.AfterImageMaterialParamRecorder.record`（游戏 RVA 0x4A46D74），由 AfterImageController.recordTransform/updateMain 触发。完整日志、转储和接口返回已保存为 `manba-direct-bind-crash.log/.dmp` 和 `manba-direct-bind-before-exit.json`。
- 直接绑定命令现已禁用，防止重放已知失败路径。没有修改存档、解锁标记或剧情状态。下一步调查原生模型切换生命周期及残影材质缓存，而不是把直接 setter 返回成功当成视觉验收。
- 可用的候选接口包括 AfterImageController.onChangeModelStart/onChangeModelFinish、reloadAfterImages、refreshMeshTree、initMaterialInfoSetUp，以及 AfterImageMaterialParamRecorder.init(app.MeshSetting)。调用顺序与所需材质/模型管理器刷新尚未证实，不应仅按方法名猜测后宣布修复。

### 生命周期实验与恢复失败

- 为直接绑定包裹 `onChangeModelStart/onChangeModelFinish` 后，进程存活超过 15 秒，但用户确认 MOD 覆盖的模型部位消失。控制器持续停在 `WAIT_MONTAGE`，没有回到 `MAIN`。这不是成功的换装，不能以存活或资源路径回读作为视觉验收。
- 恢复三个原始资源引用后，接口返回 restored=3，但随后游戏在 `ace.MeshSettingCore.updateBoundary` / `MeshBoundary.getSphere` / cloth 更新链崩溃。根因尚未确定；不能据此断言是骨骼不兼容或旧资源引用被释放。
- 证据保存在 `_validation/owots-appearance-20260914/manba-lifecycle-bind.json`、`after-lifecycle-bind.json`、`lifecycle-later.json`、`restore-after-invisible.json` 和 `manba-restore-crash.log/.dmp`。两个直接绑定入口均已禁用，插件卸载不再自动执行已知失败的恢复路径。
- 第二次崩溃后重启，`after-second-restart.json` 确认 PID 79512 的身体、头部和头发引用原生资源，残影状态为 MAIN，原生装备 ID 不变。这是运行时状态恢复证据，尚无用户画面复核。
- 下一步沿原生 Prefab 替换及其完成回调调查模型注册、Montage 和材质/物理更新；不通过强制残影状态或骨骼检查掩盖失败。

### 原生调用者已定位

- 通过已加载映像的 TDB 编码偏移只读扫描，再用 REF 方法元数据反查，确认六参数 `changePlayerModel` 的三个调用者。证据：`loaded-caller-methods.json`、`callers-resolved.json`。
- `0x140AD5660` = `app.PlayerUICharacter.createPartsModel`，`0x145254C40` = `app.PlayerUICharacter.requestChangeModel`，两者属于菜单预览。
- `0x14770DA30` = **`app.cPlayerGameObjectSupporter.requestChangeModelCore(List<cChangeArgument>)`**，是实际角色方向的候选。实例访问链为 `PlayerManager.getControllingPlayerInfo().CharacterEntity.GameObjectSupporter`。
- 该类还提供 `onChangeModel`、`checkModelChange`、`initSetting`、`collectModelMaterialManager`、可见性更新及完成状态。已找到接口不代表已确认其副作用或完成调用；必须继续核对原生流程是否修改实际装备和属性。
- 上述地址只对应本次游戏构建，不能作为可分发插件的硬编码集成接口。
- 完整流程进一步确认：`requestChangeModelCore` 调用 `CharacterUtil.onChangeModelStart(GameObject)`，使用带原生完成回调的六参数换装；`onChangeModel` 调用可见性更新、`initSetting`、`CharacterUtil.onChangeModelFinish`、`PlayerManager.releaseNoUsePrefab`。此前单独调用 AfterImage 的开始/结束遗漏了角色级流程。
- `checkModelChange` 比较 `_ModelIDs` 与 `PlayerManager.getCurrentEquipID` 的结果；独立 MOD ID 即使首次应用成功，也需处理原生自动恢复的行为。不能通过改实际装备 ID 达成纯外观需求。

### 请求对象构造实验

- 创建 List 成功，但 `cChangeArgument.REFType.CreateInstance(0)` 返回空。第二次普通构造尝试后，日志报告 VMContext 已被此前异常污染，随后在引用释放处崩溃；尚未调用 `requestChangeModelCore`，不属于 Prefab 换装结果。证据：`native-request-allocation.json`、`native-request-allocation-crash.log/.dmp`。
- 源码显示 `CreateInstance(0)` 直接走游戏 Activator；`CreateInstance(1)` 是 REF 的 simplify 分配分支。后续改用简化分配并明确填写 PartsType/ID，先单独验证构造/释放，再测试换装。不能把空返回当作完全隔离了原生异常。
- 简化分配实测成功：列表 Count=1、PartsType=BODY、ID=7482 回读正确；释放后存活超过 15 秒。证据 `native-request-simplify-allocation.json`。
- 随后调用原生 `requestChangeModelCore` 重建同一个身体资源：Body 对象从 `0x1027A19A50` 变为 `0x21D114FB20`，结束后 changing=false、AfterImage=MAIN、装备 ID 不变，存活超过 15 秒。证据 `native-body-refresh-simplify.json`、`after-native-refresh.json`；用户画面复核仍待回复。

### 外观 ID 与实际装备分离的运行时探针

- 给 BODY 额外注册 900001（先引用原生 Prefab）。仅在当前 supporter 的 `checkModelChange` 调用范围内，用 hook 改写 `getCurrentEquipID(BODY)` 的返回值；其余调用保持原生结果，未写实际装备字段。
- 实测选中后 supporter.bodyModelId=900001 持续超过 15 秒，changing=false、AfterImage=MAIN，实际 body=16365、weapon=27531 等装备 ID 不变。证据 `scoped-body-alias-select.json`、`scoped-body-alias-inspect.json`。
- 取消覆盖后，原生流程恢复 bodyModelId=7482；完成后删除临时条目，BODY 目录数量回到 9。证据 `scoped-body-alias-clear.json`、`scoped-body-alias-unregister.json`、`scoped-body-alias-restored.json`。
- 这是单部件、单角色实例的开发探针，尚未覆盖场景切换、热重载清理、多 MOD、武器属性和存档。测试期间先取消并完成注销，再部署下一版插件，避免遗留临时条目。
- 独立路径、内部引用原生网格的 Prefab 完成相同选择/取消流程，新 Body 实例生成，状态回到空闲/MAIN，注销成功。证据 `independent-native-body-select.json`、`independent-native-body-inspect.json`、`independent-native-body-unregister.json`。
- 随后只应用 manba_2 的独立身体 Prefab：Body 新对象 `0x14E2E690`，mesh/mdf2 都引用 `mods/owots/manba_2______________/00/`，bodyModelId=900001，changing=false、AfterImage=MAIN，进程 PID 16848 存活超过 15 秒。证据 `manba-native-body-select.json`、`manba-native-body-inspect.json`。**当前仍待用户确认实际身体显示、贴图和动作；不据路径和状态宣布视觉成功。** 头部、头发未切换。

### 整套服装探针

- `probe_full_outfit_select` 预加载独立 BODY/HEAD/HAIR 的三个 Prefab，全部 Ready/Valid 后注册 900001/900003/900004，再统一发布选择。原生模型检查负责构造原生换装请求；不写实际装备字段。
- `full-outfit-select.json`、`full-outfit-inspect.json` 证明三个模型 ID 均保持为额外 ID，Body/Head/Hair mesh 指向独立路径，changing=false、AfterImage=MAIN、装备 ID 不变，进程存活超过 15 秒。`full-outfit-materials.json` 的三个身体纹理绑定检查通过。
- 整套取消后，模型 ID 恢复为 BODY=7482、HEAD=25571、HAIR=1155，三个目录条目数恢复为 9/1/3，临时条目已删除。证据 `full-outfit-unregister.json`、`full-outfit-restored.json`。取消结果最初只报告单身体 alias 的 registered 标记，该显示问题已修正，目录快照才是此轮清理的实际证据。
- 整套最终画面和动作仍待用户确认；这不是多 MOD 注册/UI/存档功能完成。预加载中断可以清理并回应失败；已选中状态的插件热重载/场景清理仍需后续实现，测试部署前必须先取消并完成注销。
- 重新应用后，`full-outfit-resource-bindings.json` 确认 Body/Hair 的 ChainAsset 分别指向 `mods/owots/manba_4______________/00/ch001_00_00.chain2` 和 `/20/ch001_00_20.chain2`，两者 Setuped=true。此处验证独立物理资源路径绑定及初始化；文件内容来自原生副本，不代表任意自定义物理行为已验收。

### 用户视觉反馈：网格成功，材质不符

- 用户确认独立身体网格正常显示，但材质仍像原版衣服的颜色/纹理。由此确认身体网格路径独立化与原生替换的可见效果；材质验收失败，不能视为整体 MOD 成功。
- 实际组件 MDF ResourcePath 指向独立路径，离线 MDF 解析也显示 Cloth_Top 主贴图指向已部署的独立纹理。路径正确不能证明渲染器最终绑定了这些纹理；增加只读 `inspect_body_materials` 比较运行时材料槽及纹理引用。
- 只读快照 `manba-body-runtime-materials.json` 显示 MDF Ready/Linked=true，Cloth_Top 的部分空纹理设置保留了 MOD 值，但 BaseDielectricMap、NormalRoughnessOcclusionMap、WrinkleBlend_ALBDMap 被绑定为原生路径；用户补充原始替换型 MOD 也曾出现修改 MDF 路径不生效的现象。
- Prefab 仍引用 `Art/Model/Character/ch0/ch001_00/00/ch001_00_00_mmi.user`，该 ModelMaterialInfo 包含原版颜色、法线、褶皱及颜色变化纹理。仅修改 MDF 不能独立化这组材质管理引用。
- 创建独立 MMI 副本（替换 5 处对应纹理路径），新版本 Prefab 改写 2 处 MMI 引用，使用新的 `mods/owots_appearance_lab/manba_3/` Prefab/catalog 避免旧资源缓存。保留此前网格/MDF/纹理文件不变，未覆盖原生 MMI。私有脚本 `prepare_manba_mmi_probe.py` 记录新增 3 个文件的 SHA256。
- 应用新 Prefab 后，`manba-mmi-runtime-materials.json` 确认上述三个纹理绑定全部变为独立 MOD 路径。此对照证明本次原版纹理绑定来自 MMI 层；不能扩大为所有游戏/所有 MDF 路径问题的原因。`manba-mmi-select.json` 证明请求完成且游戏存活。修订版最终画面仍等待用户确认。
- `check_material_override.py` 对旧运行时快照失败、对新快照通过，覆盖运行时仍绑定原版纹理的症状；它不能代替贴图内容、颜色、光泽或动作的视觉验收。
- 用户强调“类似回退机制”只是对原替换型 MOD 的观察，具体行为尚不确定。不得将其记录为已证实的引擎加载失败回退规则，也不能据此认定必须覆盖原版纹理。本次独立化测试支持 MMI 覆盖纹理绑定的结论；原替换型 MOD 的历史问题未单独复现。最新只读复查 `material-user-caveat-recheck.json` 的三个关键纹理绑定仍为 MOD 独立路径，检查通过；最终画面继续等待实机确认。

### 未完成项目

- 新目录 ID 出现在原生菜单、名称与图标解析、解锁/选择条件。
- 独立 mesh/material/skeleton/physics 路径的加载、Prefab 实例化和实际画面。
- 模型切换能否独立于实际装备 ID，以及后续原生换装、场景切换是否会覆盖外观。
- 存档关联、多个 MOD 的持久注册、卸载和恢复。

## 实现方向

原生 Prefab 目录支持运行时扩展已有实测依据，可以继续优先研究原生路径。目录 ID、原生物品 ID、实际装备 ID、外观 MOD ID 应分开管理。纯外观 MOD 不写原生武器属性；不验证骨骼，也不做动画重定向。

`via.Prefab` 在本游戏反射中只有 Path/ResourcePath getter，没有 set_Path。已验证独立 UserData 反序列化 Prefab 引用的替代路径，不必为缺失 setter 立即修改 REF。后续 MOD 可提供目录 UserData，再由系统分配运行时目录 ID；仍需处理名称、物品表、UI 和存档的各自约束。

## 描述文件注册接入实测
- `appearance-core/build_lab.py` 将共用注册解析器嵌入单文件插件；游戏内编译周期 10 完成，compiling=false、errorCount=0。源码与生成部署文件分离，避免维护两个解析器。
- `registry-live-list.json` 从安装目录 manifest.json 识别 `local.manba_2` 的 BODY/HEAD/HAIR；`registry-live-select.json` 按描述文件准确的 Prefab 路径加载，临时模型 ID 为 900033/900035/900036。`registry-live-inspect.json` 确认这些 ID 保持且 changing=false；`registry-live-materials.json` 三项纹理绑定检查通过。
- `registry-live-clear.json`、`registry-live-unregister.json`、`registry-live-restored.json` 证明取消后恢复原模型 ID 7482/25571/1155，目录计数恢复 9/1/3；选择与恢复期间实际装备 ID 完全相同。这不是伤害或防御判定测试。
- `registry-live-reapply.json` 再次按相同 MOD ID 应用成功，留在游戏内供视觉验收。当前临时 ID 只对会话有效；未来存档必须保存 MOD ID。
- 当前仍须取消并释放上一条目后再选下一条目。多个真实 MOD 直接互切、服装与武器同时独立选择、原生/REF 菜单、跨场景与卸载清理、存档关联尚未完成；核心解析测试不能替代这些实机验收。

## 单次请求的外观过渡实测
- 新增跨帧恢复阶段：registry_select 校验描述文件后撤销当前选择，等待原生模型恢复并注销旧资源，再预加载新条目。registry_clear 一次请求完成恢复和注销。恢复超时保留旧资源，允许稍后重试；新资源失败时当前为原生外观，尚无上一 MOD 自动回滚。
- 编译周期 12 完成且 errorCount=0。`transition-a.json` → `transition-b.json` → `transition-a2.json` 完成 manba_2、独立原生身体对照、manba_2 的往返。`transition-b-inspect.json` 的 BODY=900065，HEAD/HAIR 已恢复原生，头发与头部目录也无旧 MOD 条目；实际装备 ID 不变。
- `transition-a2-materials.json` 的三项纹理检查通过。`transition-clear.json`、`transition-cleared-inspect.json` 确认单请求取消后原生模型 ID 和 9/1/3 目录计数全部恢复。第二条目是原生资产对照，不是第二套用户制作的 MOD，不能据此宣称多套作者 MOD 已完成视觉验收。

## 用户实机验收与 CG 测试交接
- 用户确认 MOD 与原版往返切换正常，MOD 纹理显示正常。本轮普通游玩场景的外观切换与纹理视觉验收通过；不扩展为 CG、所有动作或跨场景验收。
- 按用户要求保持 manba_2，暂停换装命令和插件部署。只读 `pre-cg-registry.json` 确认 activeModId=local.manba_2；`pre-cg-inspect.json` 保留进入 CG 测试前的模型状态。
- 用户接下来测试 CG 动画期间是否维持 MOD；结果待反馈，不作成功假设。

## CG/HQ 回退：实机失败已复现
- 用户确认普通场景切换/纹理正常，但进入 CG 后显示原版，已暂停 CG 允许调试。`cg-paused-inspect.json` 与 `pre-cg-inspect.json` 的根对象同为 0x102869E160，supporter 选择仍为 900033/900035/900036；状态从 NORMAL 转为 HQ，实际 Body/Head/Hair 网格为原版，材质为 *_event_00.mdf2。不能再以 supporter 模型 ID 未变化作为 CG 外观保持的证据。
- `check_cg_appearance.py cg-paused-inspect.json` 失败，三部件均为原版路径；同脚本对 pre-cg-inspect.json 通过。此检查比较实际网格引用，不代替视觉与动作验收。
- 元数据确认 cPlayerCatalogHolder.getPlayerPartsListHQ、PlayerManager.loadPrefabHQ/changePlayerModelHQ 和 supporter.requestChangeAllModelHQ/checkChangeModelHQ 存在。`cg-model-id-arrays.json` 只读回读 PlayerManager._ModelHQIDs 的 BODY/HEAD/HAIR 为 7482/25571/1155，普通 manager._ModelIDs 亦为原版；与 supporter 中的 MOD ID 不同。优先调查 HQ 的独立选择/加载链；尚未修改 HQ 字段、目录或调用切换方法，不能宣称已修复。

## HQ 调用链及候选修订（未部署）
- `dump_hq_methods.py` 只读解析当前进程 TDB82，按源码的字符串池掩码取方法名称，并以已知 getCurrentEquipID=0x144B7ACD0 验证地址解码。输出 `cg-hq-method-addresses.json` 与 cg-*.asm.txt；未修改内存。
- changePlayerModelHQ=0x144FD3880 在 0x144FD3925 调用 getCurrentEquipID，HQ=true 时在 0x144FD3940 调用 getPlayerPartsListHQ，再按返回 ID 查询目录。requestChangeAllModelHQ=0x144FD3440 在已有 HQ 标记等于请求值时直接返回；不应重复请求 true 并将无变化当作修复成功。
- 候选源码在 requestChangeAllModelHQ 的同一 supporter 作用域沿用现有模型 ID 钩子，并为每个 MOD 部件向 HQ 目录添加同一独立 Prefab；碰撞检查和释放覆盖两个目录。`bundled-hq/OWOTSAppearanceLab.cs` 编译 runtime:success=True，尚未部署、尚未验证 CG 效果。专用 HQ Prefab 描述尚未实现。
- 暂停 CG 中执行 registry_clear，8 秒后原生恢复未完成，见 `cg-pre-hq-deploy-clear.json`。选择映射已撤销，旧目录项和资源仍保留；进程 16848 存活。没有热重载。已请用户结束 CG 返回可操作状态，之后必须重试清理成功再部署；当前不能宣称 MOD 会在退出 CG 后自动恢复选择。

## HQ v2 部署与普通场景回归
- 只读 `hq-wait-inspect.json` 确认游戏已返回 NORMAL 且旧模型恢复；`hq-deploy-clear.json` 完成旧资源注销。备份为 pre-hq-installed-lab.cs。
- 继续反汇编发现 updateLoadModelHQ 会以 getCurrentEquipID 检查并释放不匹配的 HQ Prefab。v2 将该预加载/保留阶段也纳入选中 PlayerManager 的外观 ID 作用域。convertEquipBodyID=0x144B7AE70 会查询普通身体目录；已有自定义 ID 可由该目录识别，不需写原生装备或强改 HQ 标志。
- 安装 bundle SHA256=77ae0349f531f79b4998047d35c77604bdca89df60a58834a39044b42d7be93d，游戏内编译周期 14 完成，compiling=false、errorCount=0。`hq-v2-select.json` 重新应用 manba_2，原装备 ID 不变，进程存活；`hq-v2-normal-inspect.json` 实际三部件网格检查通过，状态 NORMAL。
- 已请求用户再次进入 CG 验证。此时仅普通场景回归通过，HQ 场景效果尚未验收；跨玩家/跨场景的作用域归属与资源清理仍须完善。

## HQ/CG 首次修订验收通过
- 用户明确反馈“cg正常,已变为mod”。同时 `hq-v2-retest-observation.json` 的状态为 HQ，实际 Body/Head/Hair 都是独立 MOD 网格；`check_cg_appearance.py` 对该 HQ 快照通过，补齐此前只有 NORMAL 成功的证据。
- 此次 CG 外观保持通过用户视觉确认与运行时路径双重检查；仍需验证 CG 结束后的返回操作、其他剧情场景、跨场景及资源清理，不推广为全部 CG 和所有动作均通过。
- 当前保持已安装 HQ v2，不热重载、不换装，等待用户结束本段剧情后的反馈。

## CG 材质与返回边界复查
- `hq-return-observation.json` 捕获时仍是 HQ，三个 MOD 网格检查通过；文件名中的 return 仅代表检查意图，不能作为已退出 CG 的证据。
- `hq-v2-materials.json` 的颜色、法线和褶皱颜色纹理绑定检查通过，补齐 HQ 状态下的实际材质引用证据。
- 进一步确认 updateLoadModelHQ 在 HQ 引用计数非正时也会请求释放目录 Prefab，0x14058C870 对应 requestRelease；该调用会创建释放请求，不能直接等同于立即卸载已实例化网格。当前普通/HQ 目录共用 MOD Prefab，后续应实际检查退出 CG、再次进入及取消外观的资源存续；未据此擅自屏蔽原生释放。

## CG 返回验收与武器对照样本
- 用户确认退出后常规状态正常，依旧保持 MOD。`hq-return-confirmed.json` 补充返回后的运行时状态；结合 CG 中用户确认，当前这段剧情的进入、保持和返回外观验收完成。尚不代表所有剧情或所有战斗动作已覆盖。
- 离线生成 `weapon-controls` 两组武器对照，源目录模型 ID 为 27540 与 27565，分别提供 WEAPON/SHEATH/WEAPON_SUB/SHEATH_SUB。18 个文件包含独立 Prefab/catalog 与两份描述文件，conversion.json 记录来源和 SHA256。两份描述均通过核心解析测试。
- 对照样本只独立化 Prefab/catalog 路径，内部仍引用原生网格/材质；没有注册属性、没有检查骨骼，没有安装或应用到游戏。它们用于后续武器切换/实际装备属性保持测试，不代表独立作者武器 MOD 已验收。

## 服装/武器分组候选与两倍武器样本
- 运行时代码已分离在用部件与预加载部件，按 outfit/weapon 撤销和释放，成功后合并部件映射。registry_clear 可带 kind，仅取消对应组；registry_list 增加 outfit/weapon 独立选择。预加载失败只清理本次新资源。bundled-groups 编译通过，尚未部署或实机验证；当前游戏继续使用已验收的 HQ v2。
- 用户要求显眼的两倍原版网格对照。私有 `prepare_weapon_double.py` 从原版常用武器的四部件 Prefab 提取四份 mesh，将顶点坐标和几何包围范围乘 2，保留文件布局、材质、骨骼变换与权重；所有改动在独立 mods/owots/w2 路径。未进行骨骼兼容性检查，未改碰撞/攻击属性。
- `weapon-double` 生成 13 个安装用文件及私有原始提取备份。重新解析确认四份顶点缓冲精确为原版 2 倍、LOD 数量不变，结果在 scale-verification.json；描述文件 local.weapon_double 解析通过。尚未安装/应用，视觉尺寸与动作待验证。准备脚本使用本地 Mesh Editor 读取器及新安装的 NumPy，仅作为离线工具依赖。

## 分组版部署等待暂停解除
- 尝试旧版 registry_clear，见 groups-predeploy-clear.json，8 秒内未完成。只读 groups-clear-pending-inspect.json 仍为 NORMAL、旧 MOD 网格存在且选择映射已撤销；GET /api/gameinfo 明确 isPaused=true。未替换插件，未强制清空仍在用资源。已请用户取消暂停，待原生恢复后重试清理。
- 已安装 22 个独立武器对照文件（原大小 A 与两倍网格），逐文件校验 SHA256，见 weapon-fixtures-install.json。只安装独立资源与描述文件，没有应用武器选择，也未改原生装备/属性。当前游戏仍为 HQ v2，分组版等待部署。
- 分组实机验收应覆盖：先 manba_2 再 weapon_double；切换 weapon_control_a 保持服装；仅 registry_clear kind=weapon 恢复原武器并保持服装；反方向取消 outfit 保持武器；加载失败不得清除另一组。实际装备 ID 之外，仍需补充伤害/防御参数或行为对照，不能仅凭 ID 不变宣称属性验证完成。

## 分组版与两倍武器实机验证
- 用户恢复待机后，groups-predeploy-clear-retry.json 清理成功。备份 pre-groups-installed-lab.cs，安装 bundled-groups（SHA256 b3e507d7ba6a9d32ea439fe3476fef32a4cc05e327005e91cdf6e1a54a5bf013），游戏编译周期 15 完成、无错误。
- groups-outfit-select.json 与 groups-weapon-double-select.json 同时保持服装 900033/900035/900036 和武器 900071..900074。groups-both-inspect.json 实际读取四个两倍网格和三个 manba 网格。用户明确确认“成功了,武器变大两倍”，武器尺寸视觉验收通过；未据此认定攻击/防御属性已通过。
- groups-weapon-a-select/inspect.json 切回原大小对照；groups-weapon-clear.json 和 groups-weapon-cleared-inspect.json 仅取消 weapon。前后三个服装对象地址和网格路径完全相同、实际装备 ID 相同，武器四个目录计数均恢复 9，无两倍网格残留。
- groups-weapon-double-reapply.json 已再次应用两倍武器，当前保留 manba_2+两倍武器。反向仅取消服装、失败隔离、武器属性及动作对照、UI 和存档仍待完成。

## 反向取消与失败隔离实测
- groups-reverse-before.json → groups-outfit-clear.json → groups-outfit-cleared-inspect.json：只取消 outfit 后原生服装 ID 恢复，四个两倍武器对象地址/网格保持不变，实际装备 ID 相同；groups-outfit-reapply.json 恢复 manba_2。
- 临时合法 weapon 描述引用存在的 catalog，但指定不存在的 Prefab，触发真实 15 秒预加载失败。groups-missing-prefab-result.json 明确 ok=false；groups-failure-before/after.json 确认三个服装对象地址、网格与实际装备 ID 不变，武器目录计数均恢复 9。失败不会保留之前的武器外观，会留在该组原生外观；另一组不受影响。
- 临时 manifest 已移除，groups-post-failure-reapply.json 重新应用两倍武器。当前为 manba_2 + 两倍武器。源码错误提示由含糊的 selection unchanged 改为 no new selection applied，避免暗示失败自动回滚；此文字修改尚未单独部署。

## REF 菜单首版部署
- 新增“鬼武者外观系统”折叠面板，分别列出服装和武器，显示当前选择，提供各组恢复按钮、刷新及错误反馈。ImGuiDrawUI 只读取不可变 CLR 快照并通过单请求队列提交操作；原生加载仍由 UpdateBehavior.Post 完成。
- UI 请求 ID 与文件请求去重隔离，启动时记录已有 request.json ID，避免 UI 操作或重载后重放旧外部指令。
- ui-predeploy-clear.json 完成资源清理，备份 pre-ui-installed-lab.cs；安装 bundle SHA256=7f9a41f39e6ee0598536dd7558bf636ac2ce4d4f263853d0bd879399ae4e9dcd，编译周期 16 完成、无错误。ui-outfit-restore.json 与 ui-weapon-restore.json 恢复 manba_2+两倍武器。
- 已请求用户确认菜单文字/布局及按钮操作。这些恢复命令通过诊断通道执行，不能作为 UI 点击验收。尚未观察菜单截图或用户操作结果；原生菜单、存档和武器属性仍待推进。

## REF 菜单用户验收
- 用户明确反馈“测试完毕,ref中的ui正常生效”。REF 菜单显示与操作生效的实机验收通过；此前按钮路由与诊断通道的区别已保留在记录中。
- 当前已具备用户可直接操作的服装/武器外观菜单，原生菜单接入仍是优先研究方向，不把 REF 可用等同于原生菜单已扩展。存档关联、武器属性保持、跨场景资源归属与更多 MOD 样本仍未完成。

## 目录所有权修正候选（尚未部署）

源码检查发现 ReleaseParts 在释放已注册部件时重新获取当前 Manager().Catalog；场景重建若更换目录，就可能清理了不同容器，而不是原来插入的容器。修正为每个部件在注册时持有实际 normal/HQ 字典的 Globalize 引用，并捕获相应移除操作；仅当条目仍指向该部件的 Prefab 时移除。条目被其他代码改写时报告错误并保留资源，不删除其他所有者的条目。

释放过程逐项清除注册标记及已释放持有者，允许部分成功后的重试。生成候选位于 bundled-catalog-ownership，SHA256=384541e4dc8dc06b7be90b83df19696064bc1a69c0d548a5963b6131038c56f8；当前游戏 runtime 引用编译通过。为保留正在等待用户读档的观察器，候选未热部署，尚无运行时引用计数和换场景验收。

此修正不等同于完整场景恢复：释放前仍须确认原生使用方不再引用外观，旧的单身体诊断探针另有清理逻辑。新角色重新注册及选择恢复仍待完成。

### 目录所有权修正版部署与基本回归

用户正常读档记录已保存后，完成 pre-catalog-ownership-clear 并部署上述候选，游戏编译周期 19 完成、错误数 0。catalog-ownership-outfit/weapon/clear/restore-outfit/restore-weapon.json 记录两类选择、全部取消、重新选择均完成，原生实际装备 ID 保持一致。

catalog-ownership-final-inspect.json 经实际场景 Body/Head/Hair 网格路径检查通过，状态 NORMAL；这不是新增用户视觉验收。当前重新启用 manba_2 与两倍武器。上述操作在读档后通过诊断命令执行，不能作为自动保存/恢复验收，也尚未覆盖“MOD 正在使用时旧目录被替换”的场景。

## 角色销毁状态调查

supporter-lifecycle-addresses.json 定位 setup=0x14548d600、destroy=0x14770cb00、onRespawn=0x14770d580。destroy 在 0x14770cc91 设置 +0x18 为 true，实时继承字段确认该字段是 _IsDestroy。onRespawn 仅清零 +0xb0 的 _CloakBlendRate 和 +0xd8 的 _IsCloakOpenKeep，不能当作整体角色重建完成信号。

候选源码新增 UsableSupporter：在存活检测之外拒绝 _IsDestroy=true 的 supporter，用于换装及清理前检查。runtime 编译通过，随保存回调修正候选待部署；尚未实测销毁期间操作，也不能因此认定可立即释放所有资源。证据为 supporter-lifecycle-*.asm.txt、supporter-lifecycle-fields.json。

进一步候选将注册 MOD 时的 supporter 作为 Globalize 持有者保存。控制角色改变时，清理还要确认旧 supporter 的原生 _IsDestroy，不能仅依据新角色 _ModelIDs 不含 MOD ID 就释放旧资源。最后一组清理完成后释放此持有者。bundled-supporter-owner runtime 编译通过，SHA256=ee46cd6703f542de4a101e0eb1fda4a206e85b982a2f2e5e556b19da2c770478；尚未部署或实测新旧角色交接，不宣称完整场景恢复已完成。
