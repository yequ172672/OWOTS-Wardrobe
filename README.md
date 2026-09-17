# Onimusha: Way of the Sword — Wardrobe

[简体中文](README-zh-CN.md) | **English**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20x64-lightgrey.svg)](#requirements)

> **Feedback & Releases**: [GitHub](https://github.com/yequ172672/OWOTS-Wardrobe) ｜ [Caimogu (Chinese)](https://www.caimogu.cc/post/2485977.html) ｜ [Releases](https://github.com/yequ172672/OWOTS-Wardrobe/releases) ｜ [Issues](https://github.com/yequ172672/OWOTS-Wardrobe/issues) ｜ [License](LICENSE)

A **multi-MOD outfit / weapon appearance** system for *Onimusha: Way of the Sword*. Appearances are installed as independent entries and can be switched or removed in-game, **without rewriting native equipment, attributes or the saved equipment identity**.

---

## Features

- **Multiple MODs coexist**: install several outfits / weapon appearances and switch or remove them independently in-game.
- **Independent assets**: each entry can reference its own meshes, materials, textures, skeleton and physics instead of overwriting native files.
- **Four categories**: Body / Cloak / Gauntlet / Weapon, with author-declared hiding and force-wear confirmation.
- **Every character instance**: the world actor, the Costume screen character and the system-menu character all mirror the appearance, including body-shape rebasing and declared hiding.
- **Built-in native entries**: the game's own outfits, weapons, gauntlets and cloaks are exposed as wardrobe entries and can be unlocked early; entries whose DLC assets are missing are refused instead of crashing.
- **Bilingual UI**: follows the system language automatically and can be forced in Settings.
- **Icons**: PNG / JPEG / BMP / TGA (missing icons fall back to a placeholder).
- **Save association**: appearance choices are recorded per save and restored on load (experimental).
- **Safe hot reload**: prepare in the wardrobe settings, then reload the C# source while keeping the current selection.
- **Update check**: compares the local version with the latest GitHub release on startup.

## Requirements

| Item | Notes |
| --- | --- |
| OS | Windows x64 |
| Runtime | .NET 10 x64 Runtime / Desktop Runtime |
| Dependency | Microsoft Visual C++ 2015–2022 x64 Redistributable |
| REFramework | The custom `dinput8.dll` shipped with this project (see below) |

> **Why a custom REFramework?** The system relies on three native capabilities: input capture for the standalone window (cursor release, game input suppression), PNG/JPEG/BMP/TGA icon loading, and a plugin unload guard. Upstream REFramework does not provide them. The plugin degrades gracefully when they are missing (placeholder icons, and the wardrobe hotkey also opens the REF menu for input), but the full experience needs the custom build.

## Installation

1. Close the game and any tool holding files in the game directory.
2. Extract the release package anywhere.
3. Run in Windows PowerShell 5.1 or PowerShell 7:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\tools\Install-OWOTSAppearance.ps1 -GameDirectory "D:\YourGameDir" -Force
   ```

   `-Force` backs up every file it replaces under `.owots-appearance-backups` in the game directory and never touches other plugins, Lua scripts or configuration.
4. Make sure **.NET 10 x64 Runtime** and the **VC++ 2015–2022 x64 Redistributable** are installed.
5. Launch the game. The first launch generates the SDK for your exact game build locally; this can take a while.
6. Once you are in a playable scene, press `/` (the physical key of `?`) to open the Wardrobe.

Uninstall:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\tools\Uninstall-OWOTSAppearance.ps1 -GameDirectory "D:\YourGameDir"
```

## Usage

- Default hotkey `/` (F6–F12 selectable in Settings), `Esc` closes the window.
- Single-click an entry to preview, double-click (or "Apply") to wear it.
- Settings include: interface language, record appearances with saves, auto-restore after load (experimental), follow explicit native-menu choices (experimental), independent skeleton, flicker-free switch, and safe hot reload.

## Authoring MODs

Use the bundled `mod-converter` to generate a `manifest.json` and independent assets, then merge the output `natives/` and `reframework/data/owots_appearance_lab/mods/<mod>/` into the game root. Copying only the manifest will miss the model resources.

```text
<GameDir>\reframework\data\owots_appearance_lab\mods\<mod>\manifest.json
```

## Project layout

| Directory | Purpose |
| --- | --- |
| `appearance-core` | Manifest registry, four-category composition, save sidecar, preferences and the lab bundler |
| `reframework` | In-game plugin source (`plugins/source/OWOTSAppearanceLab.cs`), built-in icons and the retirement marker |
| `mod-converter` | Loose/PAK appearance converter and diagnostic reports |
| `release-tools` | Reproducible test-release packaging, install, verify and rollback helpers |
| `special-adapters` | Dedicated scripted-MOD migrations (Scarlet, YoRHa 2B) |

## Building

- Managed plugin: `python appearance-core/build_lab.py --output <target.cs>`, deployed as `reframework/plugins/source/OWOTSAppearanceLab.cs`.
- Test release: `release-tools/Build-OWOTSAppearanceRelease.ps1` (needs PowerShell, Python 3, CMake / Visual Studio).
- Core regressions: `dotnet run --project appearance-core/tests/Appearance.Core.Tests.csproj -c Release`.

## Contributing

Contributions of any kind are welcome: bug reports, feature suggestions, pull requests, MOD samples and translations.

- **Bug reports**: include the game version, plugin version, the relevant `response.json` / logs under `reframework/data/owots_appearance_lab/`, and reproduction steps (which MODs, which scene, expected vs. actual).
- **Feature requests**: describe the use case and the expected behaviour so the implementation can be evaluated.
- **Pull requests**: keep changes focused, explain the motivation and how you verified them; changes to the shared core should come with the offline regressions (`dotnet run --project appearance-core/tests/Appearance.Core.Tests.csproj -c Release`); native changes should reference the REFramework branch and commit.
- **Before submitting**: make sure the change contains no game assets, saves, logs or third-party private MODs.

Feedback channels: [GitHub Issues](https://github.com/yequ172672/OWOTS-Wardrobe/issues) ｜ [Caimogu (Chinese)](https://www.caimogu.cc/post/2485977.html)

## Open-source references

| Project | Used for | License |
| --- | --- | --- |
| [REFramework](https://github.com/praydog/REFramework) (incl. REFramework.NET / csharp-api) | Plugin runtime, ImGui rendering, runtime C# plugin compilation | MIT |
| [REFramework-cn](https://github.com/yequ172672/REFramework-cn) | The custom fork used here: standalone-window input capture, icon loading ABI, unload guard | MIT |
| [Hexa.NET.ImGui](https://github.com/HexaEngine/Hexa.NET) | C# ImGui bindings | MIT |
| [dotnet/roslyn](https://github.com/dotnet/roslyn) | Runtime C# compilation | MIT |
| [RE-Engine-Lib](https://github.com/NSACloud/RE-Engine-Lib) (REE-Lib) | RSZ / resource types and PAK handling (converter) | MIT |
| [REasy](https://github.com/seifhassine/REasy) | RE Engine resource handling (converter) | MIT |
| [xxHash](https://github.com/uranium62/xxHash) / [ZstdSharp](https://github.com/oleg-st/ZstdSharp) | Hashing and compression (converter) | MIT |
| [stb_image](https://github.com/nothings/stb) | Icon decoding (PNG / JPEG / BMP / TGA) | Public Domain / MIT |
| [RE-Mesh-Editor](https://github.com/NSACloud/RE-Mesh-Editor) | Blender-side authoring and TEX decoding (offline tooling) | GPL |
| [DirectXTex / texconv](https://github.com/microsoft/DirectXTex) | TEX → PNG conversion (offline tooling) | MIT |

> RE-Mesh-Editor is GPL; this project only invokes its scripts in the offline authoring pipeline and does not bundle its code into the release. The full third-party list and license texts live in [release-tools/THIRD-PARTY-NOTICES.md](release-tools/THIRD-PARTY-NOTICES.md) and `mod-converter/licenses/`.

## License

Released under the **MIT** license, see [LICENSE](LICENSE). Third-party components and the game-asset boundary are documented in [THIRD-PARTY-NOTICES.md](release-tools/THIRD-PARTY-NOTICES.md).

> Note: `reframework/builtin-icons/` contains **native costume thumbnails** extracted from the game. They are game assets; use them locally only when you own the game, and verify your own rights before any public redistribution.

## Author & contact

- Author: **夜曲_flac**
- Bilibili: <https://space.bilibili.com/93825767>
- Discord: `yequflac`
- GitHub: <https://github.com/yequ172672>

## Disclaimer

This is an unofficial community project, not affiliated with or endorsed by Capcom. *Onimusha* and all related assets belong to their respective owners.
