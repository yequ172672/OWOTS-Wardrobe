# Portable AI workflow

## Subdirectories
| Directory | Purpose |
| --- | --- |
| `owots-mod-conversion` | Standard skill plus referenced deterministic Windows helpers |

## Common Patterns
- Ship the complete folder with AI-START.md at the converter root.
- Use paths from the receiving user's machine, never developer-local paths.
- Do not bundle MOD/game assets or auto-execute code discovered in MOD archives.
