# 鬼武者：剑之道外观系统测试包

这是给测试人员使用的 Windows 测试发行包，包含本项目编译的自定义 REFramework `dinput8.dll`、可在首次启动时生成游戏 SDK 的 C# 运行时，以及独立衣橱插件。包内不含游戏原始资源、生成的游戏 SDK、存档、日志或作者的私有 MOD。

## 安装

1. 退出游戏，并关闭会占用游戏目录文件的工具。
2. 将本目录完整解压到任意位置。
3. 用 Windows PowerShell 5.1 或 PowerShell 7 执行（两者均可）：

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\tools\Install-OWOTSAppearance.ps1 -GameDirectory "D:\你的游戏目录" -Force
   ```

   `-Force` 会先把要替换的每个文件备份到游戏目录下的 `.owots-appearance-backups`，不会覆盖其他 REFramework 插件、Lua 或配置。也可以先省略 `-Force` 做冲突检查。
4. 确认已安装 **.NET 10 x64 Desktop/Runtime** 和 **Microsoft Visual C++ 2015–2022 x64 Redistributable**。本包不携带整个 .NET runtime 或 VC++ runtime；官方获取地址见 `docs/THIRD-PARTY-NOTICES.md`。
5. 启动游戏。首次启动可能需要等待 REFramework.NET 生成与当前游戏版本对应的 SDK；这一步由本机完成，包内刻意没有携带其他机器生成的 SDK。
6. 进入可操作场景后按 `/`（问号键所在的物理按键）打开“外观衣橱”。

衣橱条目来自：

```text
<游戏目录>\reframework\data\owots_appearance_lab\mods\<mod目录>\manifest.json
```

本发行包只提供系统，不附带私有服装模型。请使用配套转换工具生成完整的游戏目录结构，然后把输出目录中的 `natives/`、`reframework/data/owots_appearance_lab/mods/<mod目录>/` 等内容合并到游戏根目录；只把 manifest 单独复制进去会缺少模型资源。

## 受控热重载

本候选版增加受控 C# 热重载。首次升级包含 REFramework.NET 运行时和 Lua，仍需退出游戏后安装；以后更新衣橱 C# 源码时，可先在衣橱设置中完成“准备安全热重载”，再使用 REFramework.NET 的 `Reload Scripts`，最后恢复重载前选择。没有准备完成时，运行时会拒绝卸载，保留当前插件。不要用 Lua 的 `Reset Scripts` 代替这个流程。实际重载与恢复效果仍需实机验收。

## 卸载与回滚

先退出游戏，再执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\tools\Uninstall-OWOTSAppearance.ps1 -GameDirectory "D:\你的游戏目录"
```

卸载器默认选择最近一次安装备份。它只删除仍与发行包哈希一致的文件；如果测试人员改过文件，卸载器会保留该文件并报告，避免误删新内容。指定备份目录可精确回滚：

```powershell
.\tools\Uninstall-OWOTSAppearance.ps1 -GameDirectory "D:\你的游戏目录" -BackupPath "D:\你的游戏目录\.owots-appearance-backups\20260915T000000Z"
```

## 校验

校验发行包文件：

```powershell
.\tools\Verify-OWOTSAppearance.ps1
```

校验已安装文件：

```powershell
.\tools\Verify-OWOTSAppearance.ps1 -GameDirectory "D:\你的游戏目录"
```

退出码为 `0` 表示通过，`1` 表示缺失、哈希不一致或参数错误。`release-manifest.json` 和 `SHA256SUMS.txt` 记录了本包实际文件哈希；不要把游戏目录里的 `generated`、`data/owots_appearance_lab/saves` 或日志复制回发行包。

## 独立骨架测试候选

系统包内置通用骨架控制器。转换后的身体服装可通过 `manifest.json` 的 `skeleton` 声明使用
私有骨架资源，不再需要每件衣服单独安装 Lua。首版仅支持已验证的原版 93 关节拓扑及休止位置变化，
不自动迁移 Scarlet 的额外角色组件或动画脚本。

安装器会备份并替换旧的 `yorha_2b_skeleton_adapter.lua` 为不执行操作的兼容标记，避免新旧控制器
同时修改骨架。需要重新转换的服装包提供资源和清单；仅更新系统不会给旧静态包补上骨架声明。
安装后完整重启游戏，不要重置或热重载脚本。首次应按配套验收说明检查基线、体型及换装恢复。
首次默认只读诊断；确认后勾选 REFramework 中的
`Enable wardrobe independent skeletons (experimental)`。该设置会保存，以后随支持的服装自动切换。
详细模式、状态文件和验收步骤见 `docs/OWOTS_INDEPENDENT_SKELETON.md`。

## 已验证范围

- `Appearance.Core.Tests`：manifest、四分类组合、sidecar 与选择语义通过。
- `REFCoreDeps` 编译回归：存在 SDK 时，运行时生成的枚举代理可被 C# 插件编译。
- `ManifestAcceptance`：当前衣橱注册表 harness 构建通过；转换工具实际输出包的解析验收以配套转换器报告为准。
- C# 衣橱 bundle 和内置 Lua 的实际 SHA256 见本包 `release-manifest.json`；历史版本的实机结果不代表新骨架功能已验收。
- 原生 Release：实际文件哈希记录在 `release-manifest.json`；这份发行包中的最新 native build 仍需测试人员在自己的环境启动确认。

衣橱切换、独立武器共存、取消和已记录的特定过场隐藏行为有本机实机证据；不同游戏版本、所有过场、输入设备、GPU 后端以及跨机器首次 SDK 生成仍应由测试人员按实际环境复测。通过编译或哈希校验不等于画面验收。

## 许可证与源码

许可证和上游组件说明见 `docs/LICENSE-*.txt`、`docs/THIRD-PARTY-NOTICES.md`。源码与构建提交信息记录在 `release-manifest.json`；再分发时请保留这些说明，并按对应上游许可证提供源码或源码获取地址。
