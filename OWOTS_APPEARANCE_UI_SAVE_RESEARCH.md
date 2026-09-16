# 原生外观菜单与存档接入调查

2026-09-14。以下来自当前游戏生成类型元数据，除特别注明外尚未执行菜单或存档写入。需求仍以 OWOTS_APPEARANCE_SYSTEM_REQUIREMENTS.md 为准。

## 原生菜单

`app.GUI030106` 是服装选择方向的实际候选。它持有 `cCostumeList`、分类字典、预览模块、当前/此前选中数组及玩家服装设置。`GUI030600` 主要显示状态页服装信息，不能因为它包含 CostumeList 就当作选择入口。

`GUI030106.cCostumeList` 使用 `via.gui.FluentScrollGrid`，持有可变的 `IList<CostumeItemTable.cCostumeItemData>`，提供 setup、onUpdateItem、callback_Select、callback_Decide、applyToPreview。类型结构支持继续调查额外列表项，不足以证明扩展菜单已经可用，也不足以宣布原生 UI 不可扩展。

菜单条目同时关联 ItemID、PlayerWeaponsID、PlayerBodyID、CloakID、GauntletID、TextureID、显示条件和条件消息。名称、说明、锁定提示各有 Text 控件。Prefab 目录新增 ID 不等于这些物品、名称、图标和解锁引用已经注册。

`GUI030106.applyCostume`、`cPlayerCostumeSettings` 和 `SaveDataHelper_Cosmetic` 是下一步核查调用链的入口。尚未证明其实际装备和外观身份是否完全分离，因此不能把 MOD Prefab ID 写入原生装备设置。优先在原生列表和选择回调接入独立外观状态；若初期使用 REF 菜单，也应复用已验证的原生部件切换。

证据：工作区 `_validation/owots-appearance-20260914/native-costume-select-metadata.json`、`costume-menu-metadata.json`、`native-cosmetic-save-metadata.json`。

### 列表绑定与分类边界（离线复查）

`native-menu-binding-metadata.json` 来自当前生成程序集的离线查询，没有打开或修改游戏菜单。

- 原生 CATEGORY 为 PL_SWORD=0、PL_CLOAK=1、PL_GAUNTLET=2、PL_BODY=3、NPC_00=4、NPC_01=5，MAX=6；没有独立 HEAD/HAIR/BOW 分类。不能把运行时 PARTS_TYPE 数字直接用作菜单分类。多部件服装应由一个 MOD 条目映射完整部件集合，而不是要求用户分别选择头部与头发；具体展示位置仍待原生菜单实测。
- `SelectItem` 同时提供 ListIndex、GlobalIndex 和 GlobalIndex2D；`FluentScrollGrid` 的 ItemCount 是 Uint2，另有 SelectedIndex1D。`OnUpdateFSGItemArgs` 提供 AddedItemTbl 和 UnchangedItemTbl。存在多个索引坐标，必须观察滚动/重建后的回调实参再确定数据映射，不能直接把可见控件索引当作 MOD 注册表索引。
- 条目类型提供原生 ItemID、PlayerWeaponsID 等固定 ID 字段及 TextureID，没有发现自定义 MOD 字符串 ID 或名称文本字段。扩展菜单需维护独立的 MOD ID 映射，名称显示与预览也需适配；仅向列表加入 Prefab ID 不足以工作。
- 候选接入点仍是 cCostumeList.setup、onUpdateItem、callback_Select、callback_Decide、applyToPreview 和外层 applyCostume。这些方法的签名存在已证实，调用先后、写装备副作用和跳过回调后必要的 UI 收尾尚未证实。原生菜单尚未可操作时不强行解锁；CG 测试期间不安装这些钩子。

## 存档关联

### 明确确认与关闭提交的区别

callback_Decide=0x146688f50 使用最后一个 uint 参数直接索引 _DisplayItemList（+0x80），按 _SelectedCategory（+0xa0）将对应条目写入菜单暂存设置和 _SelectedCostumeID，随后更新输入控制。onClose=0x145491f80 则在清理预览后无条件调用 applyCostume（0x145492093）。因此“执行 applyCostume”不是“用户明确选择了新外观”的充分证据。

源码候选 NativeCostumeSelections 只记录打开会话内的明确确认，原生应用后消费类别标记一次。CATEGORY 0 对应武器，1/2/3 对应服装，NPC 4/5 排除。native_menu_sync 默认关闭；启用后钩子只捕获标量，更新线程排队调用已有安全分类取消流程。不调用原生装备 setter；关闭功能或开始新读档清除旧标记。未部署、未实测；这仅实现原生确认到 MOD 覆盖取消的候选方向，不代表 MOD 条目已显示在原生菜单中。

### 原生服装提交与默认映射（只读反汇编）

当前进程只读方法表定位 GUI030106.applyCostume=0x1454926e0。它从 _PlayerCostumeSettings(+0x1f0) 读取六个字段，构建部位 6/5/4/0/3/12 的请求，然后调用 PlayerManager.changePlayerModel 的列表重载(0x145492ec0)。后者按部位调用 setEquipBodyID、setEquipHairID、setEquipGauntletID、setEquipCloakID、setEquipWeaponsID、setEquipBowID，写入保存设置的相应字段；此外主菜单应用还会处理 NPC 和原始护手设置。因此不直接调用整个 applyCostume 作为单个 MOD 外观的通用入口。

cPlayerCostumeSettings.updateFromCurrentSettings=0x145329bf0 从数据偏移 f4/fc/100/104/108/118 等读取原生外观设置，并将部分默认值映射为具体预览值，例如 Body 0x3fed→0x1d3a、Sword 0x6b8b→0x6b94、Hair 0x21d1→0x483。这解释了默认外观设置 ID 与实际模型 ID 可能不同，不能仅凭不相等推断角色对象改变。

setEquipBodyID(0x145493070) 和 setEquipWeaponsID(0x1454931b0) 还经过 findCosmeticIdFromPlayerParts 与可用物品查询，并有回退值。未知临时 MOD ID 不适合作为原生存档持久身份。同步需维护独立 MOD 映射并处理菜单选中/展示/确认流程，而不是把临时 Prefab ID 直接写入这些字段。证据为 native-costume-、native-costume-submit-、native-costume-setter- 方法表及反汇编；未执行这些写入函数。

`app.SaveDataManager` 提供系统/用户存档根对象、存档任务、用户与自动存档槽集合，并分别暴露保存运行状态。`cSaveDataRoot` 持有用户存档数组；`cUserSaveParamList` 区分 EquipEquipments、PlayerStatus、UserSystemParam 等数据。

`cUserSystemParam.UniqueID` 是可调查的关联字段，当前仅确认其存在。必须验证新游戏、另存、自动存档轮转、重新读档、新周目中的语义，不能单凭名称认定其全局唯一或等同存档槽。

后续应记录成功读档/保存事件的槽位与用户身份，再比较 UniqueID 的稳定性。确认可靠键后再实现关联记录；不以当前角色内存地址、最近修改文件或单个全局 JSON 代替不同存档的隔离。原生序列化扩展也尚未证明，不能写入猜测的空白字段。

证据：`save-manager-metadata.json`、`save-identity-metadata.json`、`native-cosmetic-save-metadata.json`。当前无存档修改。

### 当前身份基线与完成事件边界

`save-association-baseline.json` 已通过只读字段路径读取当前 `SaveDataManager._UserSaveData._Data._UserSystemParam.UniqueID`，以及系统数据的 LastTouchedSaveSlot、LastUserIndex、LatestAutoSave。当前 UniqueID 非零，最近操作槽为 101，用户索引为 0，自动槽编号为 0；这是一份现场基线，不证明这些字段的跨存档语义。

`UniqueID` 实际类型为 UInt32，并非 GUID。系统的 LastTouchedSaveSlot 为 Int16，LastUserIndex/LatestAutoSave 为 SByte；不能仅凭字段名字把“最近操作”当作当前加载来源，也不能把 LatestAutoSave 数字直接当作完整存档槽。需要结合 slot2offset、slot2AutoSaveOffset 和原生槽枚举确认映射。

保存/读取请求回调数据 `ace.SaveDataManagerBase.cSaveDataRequestCallbackData` 提供 Result、Error、DetailResult、TargetData，未包含独立槽号。接入时必须将请求阶段的槽号与对应完成回调关联，只有成功结果才提交该槽的外观记录。自动保存任务 `cSaveTask` 有 _SavedSlot、_VolatileOnly、_Target、_State、_AutoSaveFinished：易失保存与实际落盘需要区分，不能以请求发起或 IsFinished 单一字段判定持久化成功。

证据为 `save-association-metadata.json`、`save-association-schemas.json`、`save-callback-metadata.json`。本轮没有发起保存/读档，没有修改存档字段，也未安装保存钩子；下一步需观察一次实际保存与一次读取的事件关联，验证后再选择原生扩展或 sidecar。

### 当前构建的存档槽与读档完成顺序（只读反汇编）

本节证据来自仍在运行的 PID 16848。读取进程内存前核对 TDB 82、类型/方法计数及已知 getCurrentEquipID 函数地址；未调用保存或读档 API，未写进程内存。私有证据为 `save-method-addresses.json`、`save-*.asm.txt` 和 `save-result-enums.json`。地址只适用于当前构建。

| 函数 | 当前实现 |
| --- | --- |
| slot2offset，0x140433800–0x140433819 | 手动槽 1–20 映射数组下标 0–19；槽 101 映射下标 20；其他输入返回 -1 |
| slot2AutoSaveOffset，0x1474f5220 | 返回 slot - 101；函数本身不校验槽是否合法 |
| isAutoSaveSlot，0x1474f5440 | 只有 101 返回 true |
| isUserSaveSlot，0x1474f5450 | 只有 1–20 返回 true |
| getLatestAutoSaveSlot / getNextAutoSaveSlot，0x145b9c9d0 | 两个方法共享实现，均直接返回 101 |

因此当前构建不应按通用“多自动槽轮转”猜测关联方式；基线 LastTouchedSaveSlot=101 对应自动槽，LatestAutoSave=0 不能直接作为完整槽号。槽号仍不足以区分同槽覆盖后的不同游戏进度，UniqueID 的语义仍需实测。

`requestUserLoadCore`（0x145539670）在 0x1455398a8 / 0x1455399e5 调用传入委托，随后才在 0x1455398b3 检查结果与错误；成功且无错误的分支继续更新用户数据，在 0x14553993d 写入 LastTouchedSaveSlot。生成枚举确认 SUCCESS=1、ERROR_TYPE.NONE=0，FAILURE=2、CANCEL=3。

这意味着**成功回调进入时不能立即把当前用户根对象或最近槽字段视作已经切换完成**。下一阶段观察器应在请求进入时记录该次槽号，记录对应完成结果，并在请求返回后的游戏更新阶段采集用户身份；外观恢复还需等待新角色及目录就绪。回调与请求关联、无回调调用、嵌套请求和新角色生命周期仍需验证，不把本段反汇编等同于已完成存档恢复。

`requestManualUserLoad` 尾部转入同一 core 函数，但传入的是包装委托。因此不能仅按上层原始委托地址匹配 core 完成事件。优先研究 core 请求范围与实际回调数据的关联，避免把不相干的保存回调当作读档完成。

已增加实验命令 `trace_save_loads`：`enabled` 控制记录，`clear` 在返回已有记录后清空缓冲。只记录请求槽号、管理器/委托地址标量、线程、时间和匹配的请求返回事件；缓冲最多 256 项。此命令不解释 void 返回寄存器，不持有原生对象，不自动读档或恢复外观；尚缺完成结果关联。使用当前游戏 runtime 引用集编译通过。

观察版已在成功清除两类外观后部署，游戏编译周期 17 完成、错误数 0。`save-observer-enabled.json` 确认钩子启用，尚无实际读档事件；随后重新选择 manba_2 和 weapon_double 均完成，原生实际装备 ID 与部署前一致。证据为 `pre-save-observer-clear.json`、`save-observer-outfit-restore.json`、`save-observer-weapon-restore.json`。安装成功不是读档事件或恢复功能验收。

进一步定位到回调数据 `.ctor`（TDB 方法 0x14a836a04，函数 0x1409ef9c0）。指令分别将 result/error/detail 写入 +0x20/+0x18/+0x1c，与实时类型字段一致；第四个显式参数为 TargetData。HTTP 类型菜单过滤构造函数，不能以菜单未显示为由认定其不存在。证据为 `save-result-method-addresses.json`、`save-result-.ctor-0x14a836a04.asm.txt` 和 `save-result-live-type.json`。

观察器新增 `result_prepared`：只在当前线程的 core 读档请求范围内复制上述四项，不将其他保存调用混入，也不保留原生对象。该事件代表构造出的回调数据，仍早于回调执行及用户数据更新；需结合随后同序号 returned 事件与实际用户身份核对。当前 runtime 编译通过，实际读档触发尚未验收。

结果观察版已部署，编译周期 18 完成且错误数为 0；`save-result-enabled.json` 确认构造函数与请求钩子安装成功、事件暂为空。`pre-save-result-clear.json` 确认部署前已清除两类 MOD，当前保持原生外观，等待用户正常菜单读档以验证完整事件链。此次未自动发起读档，不应把等待状态误记为 MOD 外观恢复成功。

### 用户读档事件验收

用户确认已完成读档。`save-result-user-load.json` 捕获同线程 7、同 sequence=1 的完整顺序：request(slot=101) → result_prepared(result=1,error=0,detail=0) → returned，时间为 2026-09-14 12:22:29 UTC。这次正常菜单读取确实经过所观察的 core 与构造函数；没有触发系统主动读档。

`post-user-load-identity.json` 从单例重新遍历字段，确认 UniqueID=196596286、LastTouchedSaveSlot=101、LastUserIndex=0，和此前基线一致；系统参数对象地址发生变化，因此不能缓存该对象地址作为存档身份。游戏回到 Stage201/Area201_002，未暂停。`post-user-load-inspect.json` 保存角色状态。

此次验证证明一个实际自动槽成功读取的事件关联与随后身份采样可行，不证明失败/取消、新周目、不同槽或覆盖槽的隔离行为。尚未写入外观 sidecar，也未实现自动恢复；测试时两类外观已清除。

### 原生保存完成回调调查

只读 TDB 与函数检查找到 requestSaveBase=0x1404de480，以及 `<requestUserSaveCore>b__0`=0x1446ca430。实时类型显示其承载对象为 `app.SaveDataManager.<>c__DisplayClass100_0`，含 cb、saveFileDetailCb、subtitle、detail 四个字段；包装回调先转发数据对象，再读取其中 Result/Error 转发详细回调。

requestUserSaveCore 在 0x1404de0fa 写最近槽字段，随后在 0x1404de164 才进入 requestSaveBase，所以最近槽变化不是完成证明。requestSaveBase 在一个布尔分支直接构造 SUCCESS 数据并调用回调，另一分支进入更底层 0x1404de960。原生手动保存调用点 0x145352922–0x145352931 将四个布尔参数全部置零；其他分支语义及实际落盘仍须结合现场保存事件确认。

源码候选已扩展 trace_save_loads，记录 save_request 的槽号和四个布尔参数，尝试在请求范围内观察上述闭包构造，并以闭包地址关联后续 save_callback。仅保存标量及有界诊断映射，未写 sidecar。当前 runtime 编译通过，尚未部署；闭包构造是否实际调用（而非被分配路径绕过）、跨线程回调和无落盘分支均待实测，不将此候选称为已完成保存关联。证据为 save-completion-method-addresses.json、save-completion-*.asm.txt、save-four-field-closures.json。

### 槽 3 实测与观察器修正

用户确认手动保存至槽 3。save-slot3-events.json 记录 save_request(slot=3, flags=[0,0,0,0]) 与 save_returned；未捕获 save_callback，现有构造钩子关联未通过。save-slot3-file/hash.json 显示原生存档文件于 12:38:16.442 UTC 更新，SHA256 与保存前不同；请求时间为 12:38:16.387 UTC。此证据支持实际文件写入，不能替代缺失的完成回调关联。

新候选改在 requestSaveBase 入口读取活跃回调委托的调用列表，以匹配的完成函数取得真实闭包目标，不再依赖 `.ctor` 被调用。委托布局来自已读原生调用循环：+0x10 计数，+0x18 目标，+0x20 函数，每项 24 字节；限制计数并匹配通过 TDB 取得的实际函数，异常只记录诊断。候选 runtime 编译通过，SHA256=87ac33e3b2ce06af1fef4dc5cc0f7b0f678a4255abaf1a95c042d16b85e4ddae。

部署前清理因游戏暂停超时（pre-save-bound-clear.json），资源已保留，未覆盖已安装插件。等待恢复游戏后重试清理；此时仍为编译周期 20 的旧观察器。不得强制释放或在暂停时直接热覆盖。

候选随后加强关联：按实际委托目标的确切闭包类型匹配，由特定完成方法钩子接收结果；函数地址只记录为诊断，以免钩子跳板改变函数指针时漏掉关联。关闭观察时清空待处理映射，不再记录之后到达的旧完成事件。当前重新编译候选 SHA256=7310f41a88817f8addb912ae328d3bc854631e346ef91e4711797e69d6218457，尚未部署；前述候选哈希已被此版本取代。

用户恢复运行后，pre-save-bound-clear-resumed.json 清理完成；该候选已部署，编译周期 21 完成、无错误，实际安装文件哈希吻合。save-bound-enabled.json 确认观察启用，save-bound-outfit/weapon.json 确认两类外观重新选择完成。等待下一次用户保存以验收真实回调绑定，不把钩子安装成功视为完成事件验证。

保存完成观察版已部署，编译周期 20 完成、错误数 0，save-completion-enabled.json 确认钩子启用。服装和两倍武器重新应用完成，正在等待用户手动保存。已依据当前 Steam 安装清单定位本游戏数据文件，只读采集保存前大小、更新时间和哈希（pre-manual-save-files/hash.json），用于辅助验证磁盘写入；不以文件名或时间推断当前逻辑槽位，不修改该文件。

### 槽 4 与自动保存回调验收

用户确认保存槽 4。save-slot4-events.json 的 sequence=3 完整记录 save_request(slot=4,flags=[0,0,0,0]) → save_callback_bound(matched=1) → save_returned → save_callback(result=1,error=0,detail=0)。回调晚于请求返回约 74 毫秒，证明绑定实际委托目标的修正可覆盖这次异步手动保存。

同一记录同时出现两组自动保存配对：slot=101 的 [0,0,1,0] 请求同步回调成功，随后 [0,1,0,0] 请求返回后异步回调成功。结合 requestSaveBase 的分支代码，第三个布尔参数置 1 对应不进入底层写入的准备阶段，随后第二个置 1、第三个置 0 的请求才进入异步保存。实现记录提交时不能用准备阶段的 SUCCESS；还需保留准备时的外观快照，不能在稍后的落盘阶段重新读取已变化的 UI 选择。

此次没有启用 sidecar 写入。后续接入应在请求阶段绑定身份和已应用外观，在匹配成功结果后由游戏更新阶段写入；失败/取消不提交，自动准备记录只用于后续落盘阶段。瞬时的 LastTouchedSaveSlot 不用来替代已捕获的请求槽号。

### 新游戏身份生成与复制

只读方法表与生成元数据的完整方法集合对应后，定位用户系统参数 setupForNewGame=0x146696ce0、copyFrom=0x1404dbd00。前者将 GameOverCount(+0x54) 清零，更新随机状态，并在 0x146696d32 将生成的非零 32 位值写入 UniqueID(+0x50)。后者在 0x1404dbd68–0x1404dbd6b 将源 UniqueID 原样复制到目标。

这支持将 UniqueID 视作新游戏流程生成、随数据复制保留的标识，而非存档槽号。它不是数学上全局唯一的 GUID，也不能单独区分同一流程的不同槽；现有组合键继续包含用户与槽。新周目是否走该初始化、何时触发同槽覆盖，仍不能仅由这一函数推出。证据为 save-identity-method-addresses.json、save-user-param-method-addresses.json 与对应 setupForNewGame/copyFrom 函数体；没有启动新游戏或修改当前进度。

### 独立记录存储组件（未接入运行时）

AppearanceSaveStore 已实现版本化记录，显式键为 UserIndex + Slot + UniqueID，内容仅为 Outfit/Weapon MOD ID。相同槽不同身份、相同身份不同槽/用户各自隔离；未知版本、内嵌键不匹配和损坏 JSON 返回错误，不默默当作空选择。写入先刷新临时文件，再在同目录替换目标记录。记录不依赖当前 MOD 是否安装，也不保存原生装备属性。

真实临时文件测试已覆盖往返读取、单类取消、键隔离、损坏文件、版本/身份拒绝；打包后的 runtime 引用编译通过。本组件尚未被游戏适配器调用、未部署启用，不代表已完成 A8。成功保存事件与快照时机、同槽覆盖/新周目身份语义、场景可恢复条件仍须落实；不能仅凭离线隔离测试宣布实际游戏存档不会串用。

### 外观记录提交接入（实测待完成）

新增 AppearanceSaveTransactions 与 runtime appearance_persistence 命令。请求进入时读取用户索引、请求槽号、当前 UniqueID 和不可变菜单选择快照；已验证的准备分支只保留快照，匹配落盘分支成功回调才排队写入。游戏 UpdateBehavior.Post 执行 sidecar IO。准备之后切换外观不改变该次已准备的快照；重复完成、失败/取消、迟到的旧准备事件有离线回归覆盖。未知原生分支和换装过程中的新快照记录跳过原因。

该版本已在清理后部署，编译周期 22 完成、无错误，文件 SHA256=8cf2af2f829566fe6b335dc2c41078cf745536ce0a07a723bf90a7c498643db4。persistence-outfit/weapon.json 确认恢复两类选择，persistence-enabled.json 确认写入已启用。等待用户保存后检查实际 sidecar 内容；automaticRestore 明确为 false。文件位置为实验数据目录 saves，未修改原生存档格式。

### 读档身份与恢复预览候选

源码现将 requestUserLoadCore 的槽号与 result_prepared 关联；只有恰好一个成功结果且请求已返回，才重新读取用户身份并生成 loaded_identity。appearance_restore_preview 使用这一已观察的键读取 sidecar，再经 AppearanceRestorePlan 分组解析，不调用换装。不以 LastTouchedSaveSlot 代替请求槽号；没有本会话成功读档、身份变更或记录错误均明确返回不可用/错误。

候选 runtime 编译通过，SHA256=0bf40c3a145ec45e77757144ebe008f5240906a1f64777f42f2995cf808293a9。尚未部署，以保留周期 22 正在等待的保存写入测试；此候选也不是自动外观恢复的完成版本。

### 自动恢复调度候选（未部署）

源码新增成功读档后排队恢复：等待角色与目录可用，依次清理旧选择、恢复服装、恢复武器，并等待原生模型 ID 更新后报告结束。加载错误按类别继续处理，旧资源清理失败则停止新增应用；身份变化停止旧任务，场景等待上限 60 秒。REF 菜单在恢复期间显示忙碌与结果提示，内部步骤不覆盖诊断命令响应文件。

appearance_persistence 可额外设置 automaticRestore=true，默认关闭；appearance_restore 可重试本会话已观察的成功读档键。关闭持久化也关闭自动恢复。读档或恢复期间不采样新的原生外观覆盖既有记录，已准备的保存仍沿用原快照。

bundled-auto-restore 编译通过，SHA256=fe4312ef810cd8aab146adf208bf2480460abd8292e9c1878fc720762b70ab43，未部署。当前仍保留周期 22 写入版以等待保存实测。恢复后缺失 MOD 的记录保留与后续新保存之间的策略、连续读档/多阶段重建、原生 UI 和最终视觉验收仍需完善；不能把编译通过等同于自动恢复通过。

### 缺失 MOD 选择保留候选（未部署）

恢复计划因 MOD 缺失而暂用原版时，UnavailableAppearanceIntent 保留该类别原有 ID；同一用户与 UniqueID 后续保存到原槽或其他槽，继续记录这一选择。用户主动选择或取消该类别后清除保留值，另一类别不受影响；已有有效选择优先。下一次成功读档重置保留上下文，避免跨流程串用。

对应离线行为回归与 runtime 引用编译已通过，最新候选 bundle SHA256=23b4368490b3bad2c7596aa6166848ed53817f323e86432e3a1662a93d6a5c6a。该候选仍未部署。13:08 UTC 回读周期 22：写入已启用，状态仍为等待游戏保存成功，事件为空且未发现 sidecar 文件。此前槽 4 的成功回调属于观察版测试，不能当作写入版已成功的证据。

### 首次真实写入通过，自动恢复版已部署

用户再次覆盖槽位 4 后，persistence-slot4-events.json 记录 sequence=1 的 WriteCurrent 快照、异步 SUCCESS/NONE 回调及 appearance_committed。随后自动槽 101 先 Prepare 再 WritePrepared，只有后者完成后提交。实际读取两个 JSON 文件，均为 SchemaVersion=1、UserIndex=0、UniqueId=196596286，分别 Slot=4/101，Outfit=local.manba_2、Weapon=local.weapon_double。私有副本保存在 persistence-first-records。这证明此次手动及自动分支实际写入了记录；尚不证明读档自动恢复。

关闭写入后 registry_clear 完成，再部署 SHA256=23b4368490b3bad2c7596aa6166848ed53817f323e86432e3a1662a93d6a5c6a；编译周期 23 无错误。auto-restore-enabled.json 确认 enabled 与 automaticRestore 均为 true。当前保持原版外观，等待用户读取槽位 4 验证自动应用；不要把编译或开关状态当作实际恢复证据。连续读档的旧任务替换逻辑仍需完善。

### 连续读档任务隔离候选（未部署）

AppearanceLoadCoordinator 为每次原生读档绑定独立票据。新请求立即废弃旧的待恢复请求和可重试身份；旧回调迟到不能覆盖新请求，即使槽号与 UniqueID 完全相同也不能继续上一轮恢复。PollRestore 在当前原生步骤结束后检查票据，再决定是否推进后续类别；不在读档钩子中直接释放资源。

离线回归覆盖同槽重复读档、迟到/重复完成、开始新读档但未成功时禁止沿用旧身份，以及显式重试。runtime 引用编译通过。候选 SHA256=e1f216c3e9d9aa3db859a5ed3027d8d92c5b1702dd320f54ac4593541fc2123b，未部署；原生多阶段操作与连续场景重建仍需实测。13:13 UTC 当前游戏 PID 16848 的周期 23 仍能响应，尚无新的读档事件。

### 槽位 4 自动恢复失败与自主重试

用户反馈读档未恢复。auto-restore-slot4-failure-events.json 显示读取及身份关联成功，随后恢复在 60 秒等待中超时。restore-timeout-inspect.json 显示已登记服装三部位 ID，但实际模型仍为原生；因此错误提示“等待角色可用”过于笼统，不能据此判断角色不存在。

13:24 UTC 在同一游戏进程自主执行 appearance_restore 重试后，restore-retry-events.json 出现无 issues 的完成记录。restore-retry-inspect.json 通过身体/头部/头发 MOD 路径检查，未获视觉确认。期间自动保存曾将服装单类快照写入槽 101；槽 4 原记录仍用于重试。现已关闭持久化。

源码候选新增：恢复失败后阻止新快照写入，直到恢复完成；角色 supporter 在阶段之间变化时重新进入已有安全清理流程，并输出当前/登记对象地址和恢复阶段。尚需部署和复现原始读档场景验证，不能把稳定场景重试成功当作首次读档问题已解决。

### 暂停等待保护候选

原恢复版按墙钟计算 60 秒，并在暂停状态下仍可登记外观而等待模型 ID 更新。新增 AppearanceOperationClock：通过 PauseManager.IsMenuPause 排除菜单暂停时间，自动恢复的清理/预加载子步骤同步延长期限，暂停时不推进原生模型操作。离线测试覆盖超过 2 分钟暂停后继续计时，runtime 引用编译通过，尚未部署。

上次失败期间没有逐帧暂停状态证据，因此这只能作为已识别的计时缺陷修正，不能断言原失败由暂停导致。仍需读取槽位 4 并观察阶段、角色地址和实际网格来验证首次自动恢复。

## 整套独立资产测试包

私有目录 `_validation/owots-appearance-20260914/manba-full-independent` 包含 35 个文件和草案描述文件 `manifest.draft.json`。它沿身体、头部、头发 Prefab 的局部依赖复制 19 个 `.jcns`、`.chain2`、材质管理与模型部件配置资源，并修改对应引用。作者原有网格/MDF/纹理继续使用独立路径；允许复用未提供替代的公共纹理和公共配置。

离线检查验证 35 个 SHA256 和 64 处包内独立资源引用。没有检查骨骼名称、层级、绑定或动画兼容性。复制的约束和物理文件仍是原生内容，这证明包的资源组织已经独立，不证明修改过的骨骼/物理内容在运行时已经验收。

后续该整套包已部署，并通过整套选择、取消和重新应用的运行时检查；Body/Hair 的独立 Chain2 路径已回读且完成初始化。用户已确认普通游玩时 MOD/原版互换和 MOD 纹理正常；CG 保持性正在测试，详见 OWOTS_APPEARANCE_RUNTIME_RESEARCH.md。描述文件已接入 appearance-core 注册与运行时加载，尚无原生菜单或存档集成。不要把私有原生派生资产提交到公开源码仓库。
