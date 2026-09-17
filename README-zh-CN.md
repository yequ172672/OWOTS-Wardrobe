# 鬼武者：剑之道 · 外观衣橱系统

**简体中文** | [English](README.md)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20x64-lightgrey.svg)](#环境要求)

> **反馈与发布**：[GitHub](https://github.com/yequ172672/OWOTS-Wardrobe) ｜ [踩蘑菇（中文）](https://www.caimogu.cc/post/2485977.html) ｜ [Releases](https://github.com/yequ172672/OWOTS-Wardrobe/releases) ｜ [问题反馈](https://github.com/yequ172672/OWOTS-Wardrobe/issues) ｜ [开源协议](LICENSE)

为《鬼武者：剑之道》(Onimusha: Way of the Sword) 提供的**多 MOD 服装 / 武器外观**系统：把外观作为独立条目安装，在游戏内随时切换或取消，**不改写原生实际装备、属性与存档装备身份**。

---

## 功能特性

- **多 MOD 共存**：多套服装 / 武器外观同时安装、游戏内切换、独立取消。
- **独立资产**：每个条目可引用自己的网格、材质、纹理、骨骼与物理资源，不必覆盖原生文件。
- **四分类管理**：身体 / 披风 / 护手 / 武器；支持作者声明隐藏与强制穿戴确认。
- **角色全覆盖**：世界角色、更换装扮菜单角色、系统主菜单角色同步外观、体型重定基与声明隐藏。
- **内置原生条目**：把游戏自带服装 / 武器 / 护手 / 披风纳入系统，可提前解锁；DLC 资产缺失时自动拒绝穿戴，避免闪退。
- **中英双语界面**：跟随系统语言自动切换，也可在设置中手动指定。
- **图标支持**：PNG / JPEG / BMP / TGA（缺图自动占位）。
- **存档关联**：外观选择随存档记录与读档自动恢复（实验特性）。
- **安全热重载**：在衣橱设置中准备后热重载 C# 源码，保留当前选择。
- **自动更新检查**：启动时对比 GitHub 最新 Release。

## 环境要求

| 项目 | 说明 |
| --- | --- |
| 系统 | Windows x64 |
| 运行时 | .NET 10 x64 Runtime / Desktop Runtime |
| 依赖 | Microsoft Visual C++ 2015–2022 x64 Redistributable |
| REFramework | 本仓库配套的自定义 `dinput8.dll`（见下） |

> **为什么需要自定义 REFramework？** 系统依赖三项原生能力：独立窗口的输入捕获（解锁光标、屏蔽游戏输入）、PNG/JPEG/BMP/TGA 图标加载接口、以及插件安全卸载守卫。官方原版 REFramework 缺少这些能力；缺失时插件会自动降级（图标显示占位、按热键时同时打开 REF 菜单以获取输入），但完整体验需要配套构建。

## 安装

1. 退出游戏，并关闭会占用游戏目录文件的工具。
2. 将发行包完整解压到任意位置。
3. 使用 Windows PowerShell 5.1 或 PowerShell 7 执行：

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\tools\Install-OWOTSAppearance.ps1 -GameDirectory "D:\你的游戏目录" -Force
   ```

   `-Force` 会先把要替换的文件备份到游戏目录下的 `.owots-appearance-backups`，不会覆盖其他插件、Lua 或配置。
4. 确认已安装 **.NET 10 x64 Runtime** 与 **VC++ 2015–2022 x64 Redistributable**。
5. 启动游戏。首次启动会由本机生成与当前游戏版本对应的 SDK，请耐心等待。
6. 进入可操作场景后，按 `/`（问号键所在物理按键）打开「外观衣橱」。

卸载：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\tools\Uninstall-OWOTSAppearance.ps1 -GameDirectory "D:\你的游戏目录"
```

## 使用

- 默认热键 `/`（可在设置中改为 F6–F12），`Esc` 关闭窗口。
- 单击条目预览、双击应用；也可点击「应用此外观」。
- 设置中可切换：界面语言、跟随存档记录外观、读档自动恢复（实验）、跟随原生菜单选择（实验）、独立骨架体型、无闪烁切换、安全热重载。

## MOD 制作

使用本仓库的 `mod-converter` 生成 `manifest.json` 与独立资源，然后把输出目录中的 `natives/` 与 `reframework/data/owots_appearance_lab/mods/<mod目录>/` 合并进游戏根目录。仅复制 manifest 会缺少模型资源。

```text
<游戏目录>\reframework\data\owots_appearance_lab\mods\<mod目录>\manifest.json
```

## 项目结构

| 目录 | 说明 |
| --- | --- |
| `appearance-core` | 清单解析、四分类组合、存档 sidecar、偏好设置与 bundle 构建 |
| `reframework` | 游戏内插件源码（`plugins/source/OWOTSAppearanceLab.cs`）、内置图标与退役标记 |
| `mod-converter` | 松散文件 / PAK 外观转换器与诊断报告 |
| `release-tools` | 测试发行打包、安装、校验与回滚脚本 |
| `special-adapters` | 专用脚本化 MOD 迁移（Scarlet、YoRHa 2B） |

## 构建

- 托管插件：`python appearance-core/build_lab.py --output <目标.cs>`，产物部署为 `reframework/plugins/source/OWOTSAppearanceLab.cs`。
- 测试发行包：`release-tools/Build-OWOTSAppearanceRelease.ps1`（需 PowerShell、Python 3、CMake / Visual Studio）。
- 核心回归：`dotnet run --project appearance-core/tests/Appearance.Core.Tests.csproj -c Release`。

## 参与贡献

欢迎任何形式的贡献：反馈问题、提出功能建议、提交 Pull Request，或补充 MOD 样例与翻译。

- **问题反馈**：请附上游戏版本、插件版本、`reframework/data/owots_appearance_lab/` 下相关的 `response.json` / 日志，以及复现步骤（装了什么 MOD、在哪个场景、期望与实际结果）。
- **功能建议**：在 Issue 中说明使用场景与期望行为，便于评估实现方式。
- **Pull Request**：请保持改动聚焦、说明动机与验证方式；涉及共享核心的改动请附带离线回归（`dotnet run --project appearance-core/tests/Appearance.Core.Tests.csproj -c Release`）；涉及原生层改动的请注明对应的 REFramework 分支与 commit。
- **提交前请确认**：不包含游戏原始资源、存档、日志或他人私有 MOD。

反馈入口：[GitHub Issues](https://github.com/yequ172672/OWOTS-Wardrobe/issues) ｜ [踩蘑菇（中文）](https://www.caimogu.cc/post/2485977.html)

## 引用的开源项目

| 项目 | 用途 | 许可证 |
| --- | --- | --- |
| [REFramework](https://github.com/praydog/REFramework)（含 REFramework.NET / csharp-api） | 插件运行时、ImGui 渲染、运行时 C# 插件编译 | MIT |
| [REFramework-cn](https://github.com/yequ172672/REFramework-cn) | 本项目使用的自定义分支：独立窗口输入捕获、图标加载接口、卸载守卫 | MIT |
| [Hexa.NET.ImGui](https://github.com/HexaEngine/Hexa.NET) | C# 侧 ImGui 绑定 | MIT |
| [dotnet/roslyn](https://github.com/dotnet/roslyn) | 运行时 C# 编译 | MIT |
| [RE-Engine-Lib](https://github.com/NSACloud/RE-Engine-Lib)（REE-Lib） | RSZ / 资源类型与 PAK 处理（转换器） | MIT |
| [REasy](https://github.com/seifhassine/REasy) | RE Engine 资源处理（转换器） | MIT |
| [xxHash](https://github.com/uranium62/xxHash) / [ZstdSharp](https://github.com/oleg-st/ZstdSharp) | 哈希与压缩（转换器） | MIT |
| [stb_image](https://github.com/nothings/stb) | 图标解码（PNG / JPEG / BMP / TGA） | Public Domain / MIT |
| [RE-Mesh-Editor](https://github.com/NSACloud/RE-Mesh-Editor) | Blender 侧资源制作与 TEX 解码（离线工具） | GPL |
| [DirectXTex / texconv](https://github.com/microsoft/DirectXTex) | TEX → PNG 转换（离线工具） | MIT |

> RE-Mesh-Editor 采用 GPL，本项目仅在离线制作流程中调用其脚本，未将其代码打包进发行物。完整的第三方组件清单与许可证文本见 [release-tools/THIRD-PARTY-NOTICES.md](release-tools/THIRD-PARTY-NOTICES.md) 与 `mod-converter/licenses/`。

## 开源协议

本项目以 **MIT** 协议开源，见 [LICENSE](LICENSE)。第三方组件与游戏资产边界说明见 [THIRD-PARTY-NOTICES.md](release-tools/THIRD-PARTY-NOTICES.md)。

> 注意：`reframework/builtin-icons/` 内含从游戏解包的**原生服装缩略图**，属于游戏素材；仅在拥有该游戏的前提下随本地测试包使用，公开分发前请自行确认授权。

## 作者与联系

- 作者：**夜曲_flac**
- Bilibili：<https://space.bilibili.com/93825767>
- Discord：`yequflac`
- GitHub：<https://github.com/yequ172672>

## 免责声明

本项目为非官方社区作品，与 Capcom 及其关联公司无任何隶属或背书关系。《鬼武者》《Onimusha》及相关素材版权归其各自所有者所有。
