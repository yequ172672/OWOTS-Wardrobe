# OWOTS conversion skill maintenance

## Key Files
| File | Purpose |
| --- | --- |
| `SKILL.md` | Main portable workflow and routing |
| `scripts/Find-OWOTSGame.ps1` | Bounded, read-only Steam/game discovery and release-tool validation |

## Subdirectories
| Directory | Purpose |
| --- | --- |
| `agents` | Optional host UI metadata |
| `references` | Ordinary conversion and dedicated scripted-MOD adaptation guidance |
| `scripts` | Read-only Steam discovery, bounded ZIP expansion and reviewed static packaging |

## Dependencies
- Windows PowerShell 5.1 or newer; .NET compression APIs for ZIP helpers.
- Released OWOTS converter EXE and sibling path list; .NET 10 x64 for its worker.

## Common Patterns
- Test scripts with isolated fixtures and genuine read-only game discovery.
- Separate ordinary success from explicit reviewed experimental output.
- Preserve user authorization and do not infer local disk access from an uploaded document.
