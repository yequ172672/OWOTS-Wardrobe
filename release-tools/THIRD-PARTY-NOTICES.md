# 第三方组件与源码获取说明

本发行包是用于测试的二进制组合包。下面列出的组件保留其上游版权和许可证；随包的许可证文本只覆盖本项目能够确认并随源码提供的部分。重新分发时请保留本文件、随包许可证文本和对应的上游源码地址。

| 组件 | 包内文件 | 许可证/来源 |
| --- | --- | --- |
| 自定义 REFramework native | `dinput8.dll` | 本地 `docs/LICENSE-REFramework.txt`；用户 fork：[yequ172672/REFramework-cn](https://github.com/yequ172672/REFramework-cn)，准确 commit/工作区状态由 `release-manifest.json` 记录；上游项目：[praydog/REFramework](https://github.com/praydog/REFramework) |
| REFramework.NET / Ijwhost | `reframework/plugins/REFramework.NET.dll`、`Ijwhost.dll`、runtimeconfig | 随 REFramework.NET nightly 提供；请以对应发行版中的许可证为准：[praydog/REFramework](https://github.com/praydog/REFramework/tree/master/csharp-api) |
| 本项目衣橱插件与共享核心 | `reframework/plugins/source/OWOTSAppearanceLab.cs` | MIT，见 `docs/LICENSE-RE-Engine-MCP.txt`；源码：[yequ172672/re-engine-mcp-CN](https://github.com/yequ172672/re-engine-mcp-CN) |
| REFCoreDeps / AssemblyGenerator | `reframework/plugins/managed/dependencies/*.dll` 中对应文件 | REFramework.NET/REFramework 上游组件；源码和许可证见 [praydog/REFramework](https://github.com/praydog/REFramework/tree/master/csharp-api) |
| Hexa.NET.ImGui / HexaGen.Runtime | `Hexa.NET.ImGui.dll`、`HexaGen.Runtime.dll` | MIT，完整文本见 `docs/LICENSE-Hexa.NET.txt`；许可证与源码：[Hexa.NET](https://github.com/HexaEngine/Hexa.NET) |
| Microsoft.CodeAnalysis / CSharp | Roslyn 编译器依赖（本次运行时包为 4.11.0 系列） | MIT，完整文本见 `docs/LICENSE-Microsoft-CodeAnalysis.txt`；许可证与源码：[dotnet/roslyn](https://github.com/dotnet/roslyn) |
| .NET host/runtime | `Ijwhost.dll` 及本机已有 .NET 10 runtime | .NET Runtime 许可证与源码：[dotnet/runtime](https://github.com/dotnet/runtime)；本包不携带整个 .NET runtime |

## 测试机前置运行时

本包不重新分发完整 .NET 或 Microsoft C/C++ 运行库。请从官方页面安装 x64 版本：

- [.NET 10 下载](https://dotnet.microsoft.com/download/dotnet/10.0)（至少 .NET 10 x64 Runtime；Desktop Runtime 也可；首次生成 SDK 仍由 REFramework.NET 在游戏目录完成）。
- [Visual C++ Redistributable for Visual Studio 2015–2022](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist)（x64）。

## 源码提供

本项目源码仓库和构建提交由 `release-manifest.json` 的 `source` 字段记录。可通过该仓库重新生成 C# bundle；native DLL 使用仓库中的 CMake/Visual Studio Release 配置构建。第三方二进制的版本取自用于本次构建与回归的 REFramework.NET runtime，发行者应同时保留上游许可证与源码获取地址。

## 游戏资产边界

本包没有重新分发 OnimushaWotS 的 `natives`、官方 PAK、生成的游戏程序集、用户存档、日志或任何私有服装模型。测试 MOD 的版权和分发许可由各 MOD 作者单独负责；转换工具只读取用户明确选择的输入目录。

例外（按用户 2026-09-17 决定）：`reframework/data/owots_appearance_lab/builtin-icons/` 内含从本机游戏 PAK 解包并转换的**原生服装缩略图**（32 张 256×256 PNG），用于在内置条目上显示游戏自带图标。这些图像是 OnimushaWotS 的游戏资产，仅应在用户拥有该游戏的前提下随本地测试包分发；公开分发前需自行确认版权与授权。其余游戏素材仍不随包分发。
