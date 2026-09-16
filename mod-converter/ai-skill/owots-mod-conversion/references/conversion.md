# 普通转换：执行与验收

## 输入与目录

1. 记录工具版本/哈希、游戏候选证据及源文件 SHA-256。不要把游戏整个上传或解包。
2. 建立独立工作目录，例如用户工具目录下新建 `jobs/<时间和随机标识>`，但确保其不在
   输入 MOD 目录中，也不在游戏安装中。保留每次尝试的报告。
3. `.pak` 直接作为输入；ZIP 先用随包 Expand 脚本检查/展开。RAR/7z 需已有可信工具；
   不运行压缩包自己的解压器。检查路径穿越、链接、重名和规模后再提取。
4. 松散根应能直接看到 `natives`，或本身是游戏相对资源树。不要把外层包装文件夹名称
   当成游戏资源路径。候选根、多个 PAK、互斥有帽/无帽或 normal/HQ 不明确时先拆分选择。
   即使只选一个子文件夹，也要先审查整包是否有共用插件或脚本；不得借此绕开动态检测。
   展开结果 `dynamicFiles` 非空时，转入 `special-mods.md`；不得直接取 `pakFiles[0]`
   当成普通 MOD。独立 PAK 的扫描结果不覆盖它外层的脚本依赖。
   如果清单中有 `.fbxskel`，先确认只有一个候选且它是 v7 完整 93 关节角色骨架；转换器会继续核对原始 `/90` 的名称顺序、父层级、旋转、缩放和 segment-scaling 标志，并要求选定 BODY PFB 图中存在 MOD-owned mesh。

## 参数

调用发布版 `OWOTS-ModConverter.exe --cli <命令>`。PowerShell 用变量传路径，不拼接
用户内容为命令字符串。对 windowed EXE 使用 `| Out-Null` 等管道等待退出，再读取
`$LASTEXITCODE` 和报告。必要时用已验证的进程调用 API 等待，不猜测启动即完成。

```powershell
& $exe --cli inspect --input $inputMod --report $inspectReport | Out-Null
# 读取 JSON 后才转换；不要以 inspect 成功冒充产物验收。
& $exe --cli convert --input $inputMod --output $newOutput --id $uniqueId --game-root $game | Out-Null
```

唯一 ID 使用简短稳定的 ASCII 字母/数字/下划线，各变体不同；用户指定 ID 时保留其意图。
原生索引能唯一识别 PFB 时无需手填。多部位计划见工具源码/帮助：

```json
{"parts":[{"part":"BODY","prefab":"GameDesign/.../body.pfb","catalog":"gamedesign/.../body.user","nativeId":123}]}
```

这是格式示例，路径与 ID 不能直接使用。真实对应关系从随包
`source/runtime/owots_native_parts.json` 和实际原始 catalog 获得。
每项必须有 part/prefab/catalog；nativeId 可省略，由真实 catalog 按 PFB 唯一匹配。
`--parts-plan` 与单部位选择参数互斥，同一计划只能包含同一衣橱分类。
body 可以有 BODY/HEAD/HAIR；披风、护手、武器分别是独立分类。

## 根据错误决定下一步

| 报告现象 | 正确处理 |
| --- | --- |
| 找不到 .NET/worker | 检查当前版本依赖和工具包完整性；不要求用户安装开发 Python |
| PAK_HASH_UNRESOLVED | 核对列表、包内清单/作者映射；只接受能验证 hash 的路径，不凭材质名命名 |
| PAK_PROTECTED_CUSTOM | 专用加密分支；普通 EXE 不保证解密，需要独立有依据的分析或已解包来源 |
| NATIVE_PART_AMBIGUOUS / PFB_CANDIDATE_AMBIGUOUS | 分清变体、部位与配套关系，提供显式计划；不要取第一个候选 |
| CATALOG_ROLE_MISMATCH / CATALOG_PREFAB_MISMATCH | 修正 part/catalog/PFB 对应关系，不弱化检查 |
| GAME_ASSET_MISSING / REQUIRED_DEPENDENCY_MISSING | 核对游戏目录/更新版本/真实依赖；不自动允许未验证资源 |
| CRC_MISMATCH | 查模板与实际布局；仅对有结构读回证据且符合用户实验范围的候选使用例外 |
| charCount too large / worker 解析失败 | 可能是错误字段布局；改 CRC 或跳过字段不是修复 |
| UNCONSUMED_MOD_RESOURCE | 分类解释备用变体、其他部位、缺根或不支持行为；不要静默丢资源 |
| ACTOR_SKELETON_INVALID / ACTOR_SKELETON_TOPOLOGY_UNSUPPORTED / ACTOR_SKELETON_AMBIGUOUS | FBXSKEL 不是唯一可解析的 93 关节候选；修复输入或把扩展 actor 行为转入专用适配 |
| ACTOR_SKELETON_TRANSFORM_UNSUPPORTED / ACTOR_SKELETON_TOPOLOGY_MISMATCH | 与原始 `/90` 的旋转、缩放、名称顺序或父层级不一致；v1 只允许绑定位置变化 |
| ACTOR_SKELETON_BODY_MESH_REQUIRED / ACTOR_SKELETON_BODY_REQUIRED / ACTOR_SKELETON_BASELINE_MISSING | 只能将骨架和同一 body 条目的 MOD-owned BODY mesh 一起发布，并提供原始 `/90` 参考 |
| ACTOR_SKELETON_ADAPTER_REQUIRED | 仅当旧的直接审计路径没有运行 actor 骨架分析时出现；静态部位图不能代替角色根骨架 |
| DYNAMIC_BEHAVIOR_UNSUPPORTED | 转 special-mods 流程；用户只想静态候选时明确列出省略行为 |

每次失败读首个有意义的错误及其上下文，解决有证据的原因后使用新输出目录重试。
同一错误且无新证据时，不循环堆叠实验参数。普通成功包必须无 error、无未验证依赖，
并覆盖所选变体的必要资源；报告 warning 仍需逐类解释。

## 打包与交付

```powershell
& "$skill\scripts\Pack-OWOTSMod.ps1" -ConvertedRoot $newOutput -Archive $newZip
```

助手核对 converted 状态、静态包范围、清单引用和唯一 ID，再打包并输出 JSON 摘要。含独立骨架时，
还要核对 `manifest.skeleton` 的资源路径都指向 `mods/<id>/` 私有资源、有完整 93 个 `jointNames`，
并确认报告没有骨架错误。体型来源有两种，转换器会自动判断：
- 作者提供通过校验的独立 `FBXSKEL`：`bindPositions` 取自源文件，`resource`/`bodyMesh` 指向私有目录，
  报告含 `ACTOR_SKELETON_VERIFIED`；
- 体型写在 BODY mesh 内嵌骨架里：只用基线的 `jointNames`，**没有 `bindPositions`/`resource`**，
  运行时读取 mesh 休止（报告含 `ACTOR_SKELETON_MESH_SOURCE`）。
它不会证明游戏内视觉效果。进一步确认网格数据未被裁减、高清纹理和 streaming 保留、
PFB/USER/MDF 写回检查通过。需要时用随工具源码做只读核验，不把 game 安装作为输出目录。

助手默认拒绝含实验警告的结果。只有用户任务已接受该实验范围且你已核实具体证据时，
可传 `-ReviewedExperimentalReason '实际核实的原因与尚未完成的测试'`；ZIP 会附实验说明，
JSON 返回 `packaged_experimental`。不要为了打包成功填写虚假的通用理由或删除原报告警告。

交付 ZIP 与转换报告，概述条目、部位、变体、原作者、已做测试及未做游戏测试。
平台支持附件时发附件，否则提供实际本地链接/路径。不要虚构下载地址。
安装说明提示需要配套衣橱运行时，不同时启用原替换 MOD；默认不替用户安装。
