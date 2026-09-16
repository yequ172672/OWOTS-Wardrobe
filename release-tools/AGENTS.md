# Test release packaging

## Key Files
| File | Purpose |
| --- | --- |
| `Build-OWOTSAppearanceRelease.ps1` | Build native Release, bundle the core, collect allowlisted managed dependencies, licenses and file hashes |
| `Install-OWOTSAppearance.ps1` | Preflight target paths, preserve originals, install with transaction records and rollback on failure |
| `Uninstall-OWOTSAppearance.ps1` | Preflight backup integrity and restore only unchanged owned files |
| `Verify-OWOTSAppearance.ps1` | Check distribution and optionally installed files against the release manifest |
| `README-zh-CN.md` | Tester setup, runtime prerequisites, install/uninstall and bounded acceptance claims |
| `THIRD-PARTY-NOTICES.md` | Component provenance and runtime download references |
| `LICENSE-OWOTS-Appearance.txt` | Reference to the full project license distributed with the package |
| `LICENSE-Hexa.NET.txt` | MIT notice for the bundled Hexa components |
| `LICENSE-Microsoft-CodeAnalysis.txt` | MIT notice for the bundled Roslyn components |

## Dependencies
- Build: PowerShell, Python 3, CMake/Visual Studio and the explicit compatible REFramework.NET dependency source directory.
- `-ManagedRuntimeDll` overrides only the managed runtime DLL with a freshly built candidate; package and test it before installing, instead of first overwriting the game dependency. Other runtime dependencies retain the verified allowlist.
- Player: Windows x64, .NET 10 x64 runtime and the Visual C++ x64 redistributable; no SDK is included or required for installation.
- PowerShell source files use UTF-8 BOM for Windows PowerShell 5.1 compatibility.

## For AI Agents
- Package outputs belong under workspace `_validation/releases`; never copy arbitrary game directory contents.
- Do not ship generated game SDK assemblies, private MODs, saves, game resources, or logs. First-run SDK generation happens locally on the tester's machine.
- Every changed install must have a transaction record, even a fresh installation with no originals. Preserve pre-existing identical files on uninstall.
- The runtime release no longer ships the wardrobe skeleton Lua (retired 2026-09-16; the independent skeleton is built into the plugin). It still ships the inert `yorha_2b_skeleton_adapter.lua` retirement marker at its original autorun path. Use normal backup/rollback records for both; installation requires a closed game and full restart, never a live script reset. Skeleton-equipped MOD resources remain in separate converted packages.
- Validate backup bytes before uninstall writes; preserve post-install user modifications. Reject target reparse points, duplicate install paths and path escapes.
- Refuse installation/uninstallation while the selected game executable is running. Do not install release candidates into the live game as part of packaging.
- 2026-09-15: actual core/compiler checks, current generated-SDK bundle compile, archive/hash validation and ten isolated Windows PowerShell 5.1 installer scenarios passed. Native release and cross-machine first-run behavior still need tester verification.
