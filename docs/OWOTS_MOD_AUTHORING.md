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
  1. **输入 MOD**：选择你的松散 MOD 目录，或普通 `.pak` 文件。
  2. **输出目录**：选择父目录，工具会建议一个新的子目录（不会覆盖已存在目录）。
  3. **游戏原始安装目录**（可选）：指向 Steam 游戏根目录，工具可**按需只读解包**缺少的依赖资源。
  4. 点击 **开始转换**；也可先点 **只读检查** 只看依赖与风险，不生成包。
- 界面语言跟随系统自动切换（中文系统显示中文，其余显示英文）。

### 3. 安装转换结果

转换成功后会得到：

```text
<输出目录>/
├─ natives/stm/...                                   # 独立资产（网格/材质/纹理/物理等）
└─ reframework/data/owots_appearance_lab/mods/<id>/
   ├─ manifest.json                                  # 衣橱条目描述
   └─ ...
```

把输出目录里的内容**按相同结构合并进游戏根目录**，然后在游戏里按热键（默认 `/`）打开衣橱，点“刷新已安装外观”，你的条目就会出现。

### 4. manifest 契约（转换器自动生成，通常不用手改）

| 字段 | 说明 |
| --- | --- |
| `schemaVersion` | 固定 `2` |
| `id` | 稳定标识（小写、点分，例如 `author.hat`） |
| `name` / `description` / `author` | 展示信息 |
| `category` | `body` / `cloak` / `gauntlet` / `weapon` |
| `parts[]` | 每项 `{ part, catalog, prefab }`；一个服装条目可提供多个部位 |
| `rules.hideParts` | 本条目要求隐藏的原生部位（例如披风类 MOD 隐藏 `CLOAK`） |
| `rules.incompatibleCategories` | 与哪些分类互斥 |
| `icon` | 可选，相对 manifest 的 PNG/JPEG/BMP/TGA |
| `skeleton` | 可选，同拓扑独立骨架声明（见下） |

### 5. 部位与分类

- 四分类：**身体 / 披风 / 护手 / 武器**。
- 部位名：`BODY`、`BODY_SUB`、`HEAD`、`HAIR`、`CLOAK`、`GAUNTLET`、`WEAPON`、`SHEATH`、`WEAPON_SUB`、`SHEATH_SUB`、`BOW`。
- 你的 MOD 提供哪些部位由**资源依赖图**决定：转换器会跟随你的 PFB 图，直到触达 MOD 自己的网格/材质；不相关或未消费的输入会被报告而不是静默丢弃。
- 一个条目可以同时提供同一分类的多个部位（例如 `BODY` + `HEAD` + `HAIR`）：用高级选项里的**“部位计划”**，
  先点“只读检查”，再点“从只读检查结果填入全部候选”，然后删掉不需要的变体行。转换器不会替你挑变体。

### 6. 可选：独立骨架（体型）

如果你替换了角色体型（例如整体比例变化的服装），转换器会尝试声明一个**同拓扑骨架**：

- 若你提供了符合原版 93 关节名称与顺序的 rig 文件，会以该文件为准；
- 否则在 BODY 网格独立且基线可用时，仅声明 `jointNames`（无 `bindPositions`），运行时读取**当前装备身体网格自身的休止姿势**。

说明：**系统不做骨骼兼容性验证、不修复、不转换、不做动画重定向**——请自行确保资产符合游戏限制。

### 7. 常见阻塞与处理

转换失败时会生成 `conversion-report.json` 与 `CONVERSION-REPORT.md`（GUI 的报告面板也会显示摘要）。常见阻塞：

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
  1. **Input MOD**: pick your loose MOD folder or a plain `.pak`.
  2. **Output folder**: pick a parent folder; the tool suggests a new subfolder (existing folders are never overwritten).
  3. **Original game install** (optional): point at the Steam game root so missing dependencies can be **read-only unpacked on demand**.
  4. Click **Start conversion**; **Inspect (read-only)** reports dependencies and risks without producing a package.
- The interface follows the system language automatically (Chinese on Chinese systems, English otherwise).

### 3. Installing the result

```text
<output>/
├─ natives/stm/...                                   # private assets (mesh/material/texture/physics)
└─ reframework/data/owots_appearance_lab/mods/<id>/
   ├─ manifest.json                                  # wardrobe entry description
   └─ ...
```

Merge the output folder into the game root using the **same structure**, then press the wardrobe hotkey (default `/`) in game and click "Refresh installed appearances".

### 4. manifest contract (generated by the converter; usually no manual edits)

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Always `2` |
| `id` | Stable id (lowercase, dotted, e.g. `author.hat`) |
| `name` / `description` / `author` | Display metadata |
| `category` | `body` / `cloak` / `gauntlet` / `weapon` |
| `parts[]` | Each `{ part, catalog, prefab }`; one outfit entry may provide several parts |
| `rules.hideParts` | Native parts this entry hides (e.g. a cloak MOD hides `CLOAK`) |
| `rules.incompatibleCategories` | Categories this entry conflicts with |
| `icon` | Optional PNG/JPEG/BMP/TGA relative to the manifest |
| `skeleton` | Optional same-topology standalone rig declaration (below) |

### 5. Parts and categories

- Four categories: **Body / Cloak / Gauntlet / Weapon**.
- Part names: `BODY`, `BODY_SUB`, `HEAD`, `HAIR`, `CLOAK`, `GAUNTLET`, `WEAPON`, `SHEATH`, `WEAPON_SUB`, `SHEATH_SUB`, `BOW`.
- Which parts your MOD provides is decided by the **dependency graph**: the converter follows your PFB graph until it reaches MOD-owned meshes/materials; unrelated or unconsumed inputs are reported, never silently dropped.
- One entry may provide several parts of the same category (for example `BODY` + `HEAD` + `HAIR`): use the
  **parts plan** in the advanced options, click Inspect first, then "Fill every candidate from the last
  inspection", and delete the variant rows you do not want. The converter never picks a variant for you.

### 6. Optional: standalone rig (body shape)

If you replace the character's body shape, the converter tries to declare a **same-topology rig**:

- If you supply a rig file matching the stock 93-joint names and order, it wins;
- Otherwise, when the BODY mesh is private and the baseline is available, it declares only `jointNames` (no `bindPositions`), and the runtime reads the **equipped body mesh's own rest pose**.

Note: **the system does not validate skeleton compatibility, does not fix or convert rigs and does not retarget animation** — you are responsible for keeping assets within the game's limits.

### 7. Common blocks and how to handle them

A failed conversion writes `conversion-report.json` and `CONVERSION-REPORT.md` (the GUI report pane shows a summary too).

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
