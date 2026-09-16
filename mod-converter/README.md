# OWOTS 普通 MOD → 衣橱 MOD 转换器

这是一个面向普通玩家的离线转换器。它把已经解出的常规松散文件 MOD，或普通 KPKA `.pak`，整理为 OWOTS 四分类衣橱包：`body`、`cloak`、`gauntlet`、`weapon`。

## 最简单的用法

1. 解压发行 ZIP，保留 `OWOTS-ModConverter.exe` 和 `OWOTS_STM_Release.list` 在同一个目录。
2. 双击 EXE，选择 MOD 文件夹或 PAK，然后选择输出的父目录。
3. “游戏原始安装目录”选择 Steam 中的 `OnimushaWotS` 游戏根目录。**不需要提前解包游戏**；工具会从原始 PAK 定向读取所需依赖。
4. 点击“只读检查”查看输入情况，再点击“开始转换”。遇到不能自动确定的部位/变体，报告会说明需要提供的信息。

EXE 已内置 Python、定向解包程序、RSZ 元数据与格式读写器；玩家不需要安装 Python 或 Blender。结构化资源读写器需要系统安装 **.NET 10 x64 Runtime**（与配套衣橱系统相同）。开发者可在 `source` 目录使用 Python 3.11+、`requirements.txt` 和 `convert_mod.cmd`；见该目录的 `SOURCE-RUN.txt`。

本次 `manba_2.pak` 的原始 PFB 与随包 RSZ 模板存在 CRC 差异。默认转换会停止；只有在高级选项中主动勾选 CRC 实验写回才会生成测试包。程序会重读并验证改写结果，但这不代表游戏内画面已经验证。

命令行等价写法：

```powershell
python mod_converter.py inspect --input "D:\mods\my-mod"
python mod_converter.py convert --input "D:\mods\my-mod" --output "D:\out\my-mod-wardrobe" --game-root "D:\gametest\steamapps\common\OnimushaWotS"
# 含完整 93 关节独立角色骨架的 body 变体可把它绑定到同一条目
python mod_converter.py convert --input "D:\mods\my-2b" --output "D:\out\my-2b-wardrobe" --category body --id my-2b --hide-part CLOAK --game-root "D:\gametest\steamapps\common\OnimushaWotS"
# 无窗口脚本入口（发行版 EXE 也支持同样的 --cli 前缀）
python converter_gui.py --cli convert --input "D:\mods\my-mod" --output "D:\out\my-mod-wardrobe" --game-root "D:\gametest\steamapps\common\OnimushaWotS"
```

输出目录是可合并到游戏目录的根目录，包含：

```text
reframework/data/owots_appearance_lab/mods/<id>/manifest.json
natives/stm/mods/<id>/...                 独立资源
natives/stm/streaming/mods/<id>/...       高清纹理 companion（如果存在）
conversion-report.json                    机器可读报告
CONVERSION-REPORT.md                      中文报告
```

`manifest.json` 使用 schema 2。资源路径去掉数值版本后缀，物理文件仍保留游戏要求的版本号。每个独立资源使用稳定 hash 目录，避免不同 MOD 覆盖同名资源。

如果 body 输入只有一个 v7 `FBXSKEL`，且它是和原始 `/90` 角色骨架同名、同父层级、同旋转/缩放及 segment-scaling 标志的完整 93 关节文件，依赖图还包含 MOD-owned BODY mesh，转换器会在 manifest 写入 `skeleton`。其中的 `.fbxskel` 和 BODY mesh 都会复制到该 MOD 的私有目录，`jointNames` 保持文件顺序，`bindPositions` 取自源文件。源骨架的绑定位置可以改变；新增关节、脚本驱动的 actor 扩展、多个候选骨架和 Scarlet 的 264 关节骨架仍需专用适配器。

没有独立 `FBXSKEL`、但作者把体型写在 BODY mesh 内嵌骨架里时，转换器同样会在 manifest 写入
`skeleton`：`jointNames` 取自原始 `/90` 基线，**不写 `bindPositions`、也不写 `resource`**，
运行时改为读取当前生效 BODY mesh 的休止姿态。两条来源（独立骨架文件 / mesh）互斥：有通过校验
的独立骨架文件时以它为准；独立骨架文件非法、歧义或拓扑不支持时仍然报错，不会静默改走 mesh。

## 输入和参考目录

* 松散输入可以是含 `natives/stm` 的目录，也可以是只含游戏相对路径的解包目录。大小写差异会归一化匹配，但同一逻辑资源若内容不同会报错。
* 普通 PAK 的路径是 hash。工具优先读取 PAK 内的 `__MANIFEST/MANIFEST.TXT`，并使用 EXE 旁的 `OWOTS_STM_Release.list`；源码运行可回退到 `runtime/` 中的列表。也可以显式传 `--hash-list` 或作者提供的 `--hash-map`。未解析的 hash 永远阻止转换，绝不会凭扩展名猜路径。
* 支持未压缩、DEFLATE 和 Zstandard（源码运行需 `pip install -r requirements.txt`；EXE 已携带）。PAK 条目、压缩后长度、边界和可用 checksum 信息都会检查。
* `--game-root` 是只读原始 Steam 安装目录。发行版会使用旁边的 `OWOTS_STM_Release.list` 和内置按需 PAK 读取器，从原始 PAK 验证并提取依赖；不会扫描或修改安装目录旁的 loose 覆盖文件。`--game-extract` 是高级选项，用于明确指定已解包 `natives/stm` 参考目录。
* 若只能提供不完整的参考目录，可显式使用 `--allow-unverified-game-assets`；这属于实验路径，报告会列出每个未验证依赖，普通转换默认阻止缺失依赖。
* 没有 PFB 的原生 mesh/MDF 替换会根据内置真实 prefab/catalog/native-id 索引自动匹配，再检查 PFB 的实际依赖。仅纹理替换、非原生命名或多个候选可能需要在高级选项提供 PFB/catalog/native-id，工具不会猜选。

当普通 mesh MOD 没有包含原始 PFB/catalog，而参考目录里存在多个版本时，可以明确指定：

```powershell
python mod_converter.py convert --input "D:\mods\mesh-replace" --output "D:\out\wardrobe" `
  --category body --part BODY `
  --prefab "GameDesign/Action/Player/_Prefab/PartsList/Body/ch001_00_00.pfb" `
  --catalog "GameDesign/System/CatalogData/PlayerBodyPartsList_1st.user" `
  --native-id 7482 --game-extract "D:\read-only\natives"
```

## 通过 AI 对话转换

把发行包根目录的 `AI-START.md` 拖入 AI 对话，并保留 EXE、列表和 `ai-skill` 文件夹。
本地 AI 会按文档探测 Steam 游戏目录，再接收 MOD、检查、转换和交付 ZIP；纯网页聊天
需要用户执行本地命令或换用可访问本机的 AI。上传文档本身不会授予硬盘访问权限。
支持标准 skills 的 AI 可安装 `ai-skill/owots-mod-conversion`，工具目录仍需单独定位。

普通资源走通用转换器；Lua、动态骨骼、动作或原生插件类 MOD 则由 AI 按专用迁移流程
分析与编写独立适配器，不能保证一键迁移任意脚本。不会把静态转换成功当作动态功能已保留。

## 安全和已知边界

多部位静态变体可使用 `--parts-plan plan.json`，代替 `--part/--prefab/--catalog/--native-id`。
计划格式为 `{"parts":[{"part":"BODY","prefab":"实际路径.pfb","catalog":"原生目录.user","nativeId":7482},{"part":"HEAD","prefab":"实际头部路径.pfb","catalog":"原生头部目录.user"}]}`。
发布衣橱包时每个部位都需要 `catalog`；`nativeId` 可省略，此时按 PFB 唯一匹配目录行。
每个部位仍经过相同的目录一致性校验。同一个计划只能包含一个衣橱分类，不能重复部位。
该选项用于已明确配套关系的资源，不会自动恢复原 MOD 的脚本行为。

* 输入目录、原始游戏目录和源 MOD 都不会修改；输出必须是不存在的新目录。目录中的符号链接、脚本、DLL、REFramework 插件和未知元数据不会盲目携带，原因会写进报告。
* PFB、USER、MDF2、MESH、TEX、FBXSKEL 输入必须使用当前 OWOTS 支持的数值版本后缀。其他游戏或旧格式需先用对应编辑工具转换，不能只改文件名伪装成兼容资源。
* 手动配置必须让原生 catalog 的部位和所选行 PFB 一致；原生 ID 留空时按 PFB 唯一匹配。未消费的模型、材质、纹理默认阻止发布，只有命令行显式 `--allow-unconsumed-resources` 才允许输出不完整的实验包。
* PFB/USER 的依赖必须经过 AppearanceRsz 读回验证；MDF2 经过严格 MDF parser/writer 读回验证。`app.MeshSetting` 或 `app.ChainSetting` CRC mismatch 默认会在报告中显示并阻止写回；只有用户显式勾选/传 `--allow-crc-mismatch` 才会使用实验路径。
* normal 和 `streaming` 高清纹理作为同来源的一对处理，不会用低清文件覆盖高清 companion，也不会把不同来源的 base/streaming 混搭。对结构完整且分辨率更高的 companion，工具默认直接使用其原始字节提升 base；决定和拒绝原因记录在 `texturePromotions` 报告统计中。
* `WOTSPK01`/`WOTSPV03` 专用加密封套会在扫描阶段硬阻止。其标准目录中的截图、说明或可见小条目不会被当成模型成功转换；请向作者索取未加密/已解包版本或合法的解密映射。
* 一个已通过 v1 校验的 93 关节 FBXSKEL 可以随 body 条目私有化；这只覆盖绑定位置变化，不覆盖动作重定向、额外关节、约束或脚本行为。原生脚本、固定 RVA 插件、动作驱动和动态约束仍不属于静态 manifest。含 Lua/DLL/autorun 的 MOD 默认阻止转换；确认接受静态模型范围时，显式使用 `--experimental-static-only`，报告会列出省略的动态文件和不等价范围。
* 身体、头发和头部是同一个 `body` 衣橱条目的不同部位。检测到多个互相冲突的原生变体时会分开报告，不能把 hat/no-hat 或 normal/HQ 变体合并成一个 PFB。

## 报告和退出码

`inspect` 是只读诊断：成功返回 0，发现阻止性问题返回 2。可用 `--report path.json` 将检查结果写入新文件。`convert` 成功返回 0；失败时新输出目录只会有 blocked 报告，不会有 manifest 或半成品资源；已有目录不会被修改，冲突报告会写到新的旁侧目录。也可以用 `converter_gui.py --cli convert ...` 无窗口执行。优先查看 `CONVERSION_BLOCKED`、`PAK_HASH_UNRESOLVED`、`NATIVE_PART_AMBIGUOUS`、`NATIVE_PART_NO_MATCH`、`DYNAMIC_BEHAVIOR_UNSUPPORTED`、`CRC_MISMATCH` 和 `GAME_ASSET_UNVERIFIED`。

真实回归记录（不随发行包携带测试 MOD 或游戏资产）位于工作区 `_validation/mod-converter-20260915` 和 `_validation/wardrobe-skeleton-20260916`：标准 `manba_2.pak` 与其已解包目录使用相同转换管线，2B base/alternate 的 93 关节骨架写入私有资源和 manifest，保护型 2B PAK 得到硬阻断报告，Scarlet 的 native/Lua 动态部分以及 264 关节 actor 骨架仍明确保留为不支持范围。
