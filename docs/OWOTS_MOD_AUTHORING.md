# 外观 MOD 制作与适配指南 / Wardrobe MOD Authoring & Adaptation Guide

[中文](#中文) | [English](#english)

---

## 中文

### 1. 你不需要改变自己的工作流程

**只要你的 MOD 本来就能在游戏里正常显示**（松散文件或普通 KPKA PAK 都可以），你不需要重新做网格、改材质或调整骨骼。你要做的只有一步：**用转换器把它转成"衣橱包"**。

转换器会读取你现有的 MOD，自动分析资源依赖，输出一个可被衣橱系统识别的独立条目。你的原始 MOD 目录始终**只读**，不会被修改。

### 2. 使用转换器

- **图形界面**：双击发行版 `OWOTS-ModConverter.exe`；源码方式可运行 `python converter_gui.py` 或 `convert_mod.cmd`。
- 步骤：
  1. 设置**游戏目录**；**输出目录可留空**，默认保存到每个输入 Mod 旁边，设置后则统一保存到指定目录。
  2. 拖入 Mod 文件夹、ZIP、RAR、7z 或普通 PAK，自动识别并转换。
  3. 完成后生成 `原名称-衣橱.zip`，点击**打开位置**找到它。同名文件自动加编号，只有遇到问题时才需要查看原因。
- 界面语言跟随系统自动切换（中文系统显示中文，其余显示英文）。

### 3. 安装转换结果

转换成功后的 ZIP 解压内容：

```text
<输出目录>/
├─ natives/stm/...                                   # 独立资产（网格/材质/纹理/物理等）
└─ reframework/data/owots_appearance_lab/mods/<id>/
   ├─ manifest.json                                  # 衣橱条目描述
   └─ ...
```

解压 ZIP，把其中的 `natives` 和 `reframework` **按相同结构合并进游戏根目录**，然后在游戏里按热键（默认 `/`）打开衣橱，点“刷新已安装外观”，你的条目就会出现。

### 4. manifest 契约（转换器自动生成，通常不用手改）

| 字段 | 说明 |
| --- | --- |
| `schemaVersion` | 当前为 `4`；旧版配置需要重新转换，运行时不再读取 |
| `id` | 稳定标识（小写、点分，例如 `author.hat`） |
| `name` / `description` / `author` | 展示信息 |
| `category` | `body` / `cloak` / `gauntlet` / `weapon` / `transform` |
| `parts[]` | 常态分类：每项 `{ part, catalog, prefab }`；一个服装条目可提供多个部位 |
| `roots[]` | 仅 `transform` 分类：每项 `{ root, prefab }`，可选 `catalog`；`root` 为 `ONI_BODY` 或 `ONI_HEAD` |
| `rules.hideParts` | 常态：要隐藏的原生部位（例如身体条目隐藏 `CLOAK`）；`transform`：鬼化域内要隐藏的目标（`HEAD` / `HAIR`）；不能隐藏自己提供的部位 |
| `rules.incompatibleCategories` | 与哪些分类互斥（`transform` 条目不可声明） |
| `rules.equip` | 身体条目的默认配件：`{"cloak":"配件ID","gauntlet":"配件ID"}`，两项均可省略 |
| `icon` | 可选，相对 manifest 的 PNG/JPEG/BMP/TGA |
| `skeleton` | 可选，同拓扑独立骨架声明（见下） |

### 5. 部位与分类

- 四分类：**身体 / 披风 / 护手 / 武器**；第五分类：**变身**（协议名 `transform`）。
- 部位名：`BODY`、`BODY_SUB`、`HEAD`、`HAIR`、`CLOAK`、`GAUNTLET`、`WEAPON`、`SHEATH`、`WEAPON_SUB`、`SHEATH_SUB`、`BOW`。
- 变身条目使用 `roots` 而不是 `parts`：`ONI_BODY` 对应 `onibody.pfb`，`ONI_HEAD` 对应 `onihead.pfb`（头部与头发都在后者内部）。可只提供其中一个根，未修改的部分引用原版；`rules.hideParts` 只在该域内生效，可隐藏 `HEAD` / `HAIR`，不会影响常态外观。
- 变身外观在鬼化前选定，单次鬼化期间锁定；中途修改只对下一次生效。变身资源、触发与持续时间由游戏管理。
- 你的 MOD 提供哪些部位由**资源依赖图**决定：转换器会跟随你的 PFB 图，直到触达 MOD 自己的网格/材质；不相关或未消费的输入会被报告而不是静默丢弃。
- 一个条目可以提供同一分类的多个部位（例如 `BODY` + `HEAD` + `HAIR`）；转换器根据资源归属自动分组。可见披风、护手分别注册，身体通过 `rules.equip` 声明默认穿戴。
- 玩家后来手选的配件覆盖默认穿戴。取消/切换身体仅撤回尚未手改的默认配件，恢复其之前选择；重新明确穿戴身体会重新应用默认配件。隐藏和互斥规则仍然有效。

### 6. 可选：独立骨架（体型）

如果你替换了角色体型（例如整体比例变化的服装），转换器会尝试声明一个**同拓扑骨架**：

- 若你提供了符合原版 93 关节名称与顺序的 rig 文件，会以该文件为准；
- 否则在 BODY 网格独立且基线可用时，仅声明 `jointNames`（无 `bindPositions`），运行时读取**当前装备身体网格自身的休止姿势**。

说明：**系统不做骨骼兼容性验证、不修复、不转换、不做动画重定向**——请自行确保资产符合游戏限制。

### 7. 常见阻塞与处理

新版窗口直接显示实际问题，不提供高级实验开关。以下详细选项表仅适用于保留的旧单条目 CLI；不要为特殊骨架或脚本强行打开兼容选项。批量流程保留 PFB 路径片段之外的全部原始字节，不要求用户接受 CRC 实验写回。

| 报告代码方向 | 含义 | 处理 |
| --- | --- | --- |
| 资源版本不匹配 | 文件格式版本与当前 OWOTS 读写器不符 | 提供对应版本资源，不要只改后缀 |
| 未消费资源（`UNCONSUMED_MOD_RESOURCE`） | 报告 `details` 会说明具体原因：与已发布资源字节相同、属于未选择的其它变体、或四分类之外/无 partslist PFB 归属 | 按原因处理；确认确实不需要的多余资源，可用“排除不可达资源”让转换器逐条列明原因后排除 |
| 已排除不可达资源（`PRUNED_UNREACHABLE_RESOURCE`） | 显式排除项，不是错误 | 核对原因与数量，确认没有漏掉你要的部位 |
| 同一部位多个原生变体 | 例如披风可见/不可见是两套 body 变体 | 用“部位计划”只选一套，不要把变体合并成一个条目 |
| 随包模板不匹配（`RSZ_TEMPLATE_LAYOUT_MISMATCH` / `RSZ_TEMPLATE_CRC_OVERRIDE_REQUIRED`） | 转换器的 RSZ 模板与该资源类版本不一致（不是你的 MOD 的问题） | 布局不匹配无法靠放宽校验修复；CRC 差异需要你在高级选项里显式接受实验写回 |
| CRC mismatch | 结构化资源写回前校验不一致 | 默认拒绝；确认风险后可用“允许 CRC mismatch”实验选项 |
| PAK 加密 / 分块目录 | 普通 MOD 转换不支持 | 用可信工具先解包为松散文件 |
| 动态脚本 / 原生插件 | 静态衣橱包不携带 Lua/DLL 行为 | 使用“静态转换”实验选项并自行承担行为差异 |

关于 `rules.hideParts`：转换器会按原生体型可见性规则自动隐藏对应部位（例如披风不可见的体型
隐藏 `CLOAK`），报告会写明 `bodyId` 与自动隐藏项；本条目自己提供的部位不会被隐藏。

### 8. 工作原理（简述）

- 运行时把条目里的 Prefab 以**合成 ID** 注入玩家部件目录，并通过原生换装流程切换；**不写原生实际装备、属性或存档装备身份**。
- 世界角色、更换装扮菜单角色与系统主菜单角色会同步外观、声明隐藏与体型。
- 选择可随存档记录并在读档后恢复（实验特性）。

更完整的实现细节与验证边界见：`docs/OWOTS_APPEARANCE_ARCHITECTURE_AND_MHWILDS_PORTING.md`、`docs/OWOTS_APPEARANCE_RUNTIME_RESEARCH.md`、`docs/OWOTS_INDEPENDENT_SKELETON.md`。

### 9. 返回主仓库

- [README（中文）](../README-zh-CN.md) ｜ [README (English)](../README.md) ｜ [反馈（踩蘑菇）](https://www.caimogu.cc/post/2485977.html) ｜ [GitHub Issues](https://github.com/yequ172672/OWOTS-Wardrobe/issues)

---

## English

### 1. You do not need to change your workflow

**If your MOD already shows up correctly in game** (loose files or a plain KPKA PAK both work), you do not need to rebuild meshes, redo materials or adjust rigs. There is exactly one extra step: **convert it into a wardrobe package**.

The converter reads your existing MOD, works out the resource dependency graph, and emits an independent entry the wardrobe understands. Your source MOD directory is **always read-only** and is never modified.

### 2. Using the converter

- **GUI**: run the released `OWOTS-ModConverter.exe`, or from source `python converter_gui.py` / `convert_mod.cmd`.
- Steps:
  1. Choose the **game folder**. Leave the optional **output folder** empty to save beside each input, or choose one folder for all results.
  2. Drop folders, ZIP, RAR, 7z or ordinary PAK files to convert automatically.
  3. The result is `original-name-衣橱.zip`; click **Open folder** to find it. Existing names receive a number. Reasons are shown when a problem occurs.
- The interface follows the system language automatically (Chinese on Chinese systems, English otherwise).

### 3. Installing the result

```text
<output>/
├─ natives/stm/...                                   # private assets (mesh/material/texture/physics)
└─ reframework/data/owots_appearance_lab/mods/<id>/
   ├─ manifest.json                                  # wardrobe entry description
   └─ ...
```

Extract the ZIP and merge its `natives` and `reframework` folders into the game root using the **same structure**, then press the wardrobe hotkey (default `/`) in game and click "Refresh installed appearances".

### 4. manifest contract (generated by the converter; usually no manual edits)

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Currently `4`; older declarations must be re-converted and are no longer read |
| `id` | Stable id (lowercase, dotted, e.g. `author.hat`) |
| `name` / `description` / `author` | Display metadata |
| `category` | `body` / `cloak` / `gauntlet` / `weapon` / `transform` |
| `parts[]` | Normal categories: each `{ part, catalog, prefab }`; one outfit entry may provide several parts |
| `roots[]` | `transform` only: each `{ root, prefab }` with an optional `catalog`; `root` is `ONI_BODY` or `ONI_HEAD` |
| `rules.hideParts` | Normal: native parts this entry hides (e.g. a body hides `CLOAK`); `transform`: in-domain targets (`HEAD` / `HAIR`); never its own provided parts |
| `rules.incompatibleCategories` | Categories this entry conflicts with (not allowed on `transform`) |
| `rules.equip` | Body defaults: `{"cloak":"entry.id","gauntlet":"entry.id"}`, either optional |
| `icon` | Optional PNG/JPEG/BMP/TGA relative to the manifest |
| `skeleton` | Optional same-topology standalone rig declaration (below) |

### 5. Parts and categories

- Four normal categories: **Body / Cloak / Gauntlet / Weapon**; the fifth category is **Transform** (protocol name `transform`).
- Part names: `BODY`, `BODY_SUB`, `HEAD`, `HAIR`, `CLOAK`, `GAUNTLET`, `WEAPON`, `SHEATH`, `WEAPON_SUB`, `SHEATH_SUB`, `BOW`.
- Transform entries declare `roots` instead of `parts`: `ONI_BODY` is `onibody.pfb` and `ONI_HEAD` is `onihead.pfb` (it contains both the head and hair meshes). Either root may be omitted; unmodified content references the original. `rules.hideParts` applies inside that domain only (`HEAD` / `HAIR`) and never affects the normal-state appearance.
- The transform appearance is selected before a transformation and frozen for its duration; mid-transformation changes apply to the next one. Resources, triggering and duration stay under game control.
- Which parts your MOD provides is decided by the **dependency graph**: the converter follows your PFB graph until it reaches MOD-owned meshes/materials; unrelated or unconsumed inputs are reported, never silently dropped.
- One entry can provide several parts in the same category (`BODY` + `HEAD` + `HAIR`). The converter groups them by resource ownership. Visible cloaks and gauntlets remain separately registered; body `rules.equip` selects their defaults.
- Later manual accessory choices override those defaults. Cancelling/changing the body restores only untouched defaults. Explicitly wearing the body again reapplies its defaults; hiding and conflict rules still apply.

### 6. Optional: standalone rig (body shape)

If you replace the character's body shape, the converter tries to declare a **same-topology rig**:

- If you supply a rig file matching the stock 93-joint names and order, it wins;
- Otherwise, when the BODY mesh is private and the baseline is available, it declares only `jointNames` (no `bindPositions`), and the runtime reads the **equipped body mesh's own rest pose**.

Note: **the system does not validate skeleton compatibility, does not fix or convert rigs and does not retarget animation** — you are responsible for keeping assets within the game's limits.

### 7. Common blocks and how to handle them

The new player window shows actual problems without experimental controls. The detailed option table below describes the retained single-entry CLI only. Do not force special rigs/scripts through compatibility options. The batch workflow preserves PFB bytes outside equal-size path spans and does not request a CRC override.

| Area | Meaning | Action |
| --- | --- | --- |
| Resource version mismatch | Format version not accepted by the current OWOTS reader | Provide the matching version; renaming the suffix is not conversion |
| Unconsumed resources (`UNCONSUMED_MOD_RESOURCE`) | The report `details` names the reason: byte-identical to a published resource, part of a variant you did not select, or outside the four categories / owned by no partslist PFB | Act on the reason; when the extra resources are genuinely unwanted, let the converter itemise and exclude them with the prune option |
| Pruned unreachable resources (`PRUNED_UNREACHABLE_RESOURCE`) | Explicitly excluded, not a failure | Check the reasons and the count so no part you wanted was dropped |
| Several native variants for one part | e.g. cloak-visible and cloak-less are two body variants | Pick one with a parts plan; never merge variants into one entry |
| Bundled template mismatch (`RSZ_TEMPLATE_LAYOUT_MISMATCH` / `RSZ_TEMPLATE_CRC_OVERRIDE_REQUIRED`) | The converter's RSZ template does not match this resource's class version (not a defect in your MOD) | A layout mismatch cannot be fixed by relaxing checks; a CRC difference needs you to accept the experimental write-back in the advanced options |
| CRC mismatch | Structured-resource write-back failed its checksum check | Rejected by default; opt in with the experimental CRC option if you accept the risk |
| Encrypted / chunked PAK | Not supported for normal MOD conversion | Unpack to loose files with a trusted tool first |
| Dynamic scripts / native plugins | A static wardrobe package does not carry Lua/DLL behavior | Use the experimental static conversion option and accept the difference |

On `rules.hideParts`: the converter derives hidden parts from the native body visibility rules
(for example a cloak-less body hides `CLOAK`) and records the `bodyId` and the derived parts in the
report; a part the entry itself provides is never hidden.

### 8. How it works (short version)

- At runtime the entry's prefabs are injected into the player parts catalog under **synthetic IDs** and swapped through the native model-change flow; **no native equipment, attributes or saved equipment identity is written**.
- The world actor, the Costume screen character and the system-menu character all mirror the appearance, declared hiding and body shape.
- Choices can be recorded per save and restored on load (experimental).

Full implementation details and verified boundaries: `docs/OWOTS_APPEARANCE_ARCHITECTURE_AND_MHWILDS_PORTING.md`, `docs/OWOTS_APPEARANCE_RUNTIME_RESEARCH.md`, `docs/OWOTS_INDEPENDENT_SKELETON.md`.

### 9. Back to the repository

- [README (English)](../README.md) ｜ [README（中文）](../README-zh-CN.md) ｜ [Feedback (GitHub)](https://github.com/yequ172672/OWOTS-Wardrobe/issues) ｜ [Caimogu (Chinese)](https://www.caimogu.cc/post/2485977.html)
