# Special adapter guide

## Subdirectories

| Directory | Purpose |
| --- | --- |
| `scarlet` | Opt-in Scarlet wardrobe dynamic adapter and offline host-contract tests |
| `yorha-2b` | Opt-in 2B actor skeleton bridge candidate and companion-package validation |

## Boundaries

- Adapters in this directory are separate from `mod-converter` and the shared OWOTS appearance runtime.
- Keep the original Scarlet MOD, the game installation and native DLLs read-only. Do not execute or bundle the original Lua/DLL.
- An adapter may provide pure managed orchestration and a narrow host contract; game-thread/native bindings belong to the integrating runtime.
- Dynamic behavior must fail closed when the exact wardrobe selection, private resource identity, actor owner or native signature is not verified.
