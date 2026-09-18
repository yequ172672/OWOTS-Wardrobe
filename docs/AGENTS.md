# Wardrobe documentation guide

## Key Files
| File | Purpose |
| --- | --- |
| `OWOTS_CONVERTER_REDESIGN.md` | Converter design history with an implementation-status preface; separate implemented rules from remaining proposals |
| `OWOTS_CONVERTER_IMPLEMENTATION.md` | 2026-09-18 implementation scope, duplicate appearance grouping, rotation fallback, executable/core acceptance and development package hashes |
| `OWOTS_CONVERTER_PROTOTYPE.html` | Offline interactive converter UI design; all plan/output actions are explicitly simulated |
| `OWOTS_MOD_AUTHORING.md` | Current user-facing authoring and manifest guide |
| `OWOTS_INDEPENDENT_SKELETON.md` | Existing independent actor skeleton contract and verification limits |
| `OWOTS_FOUR_CATEGORY_WORKSPACE_REQUIREMENTS.md` | Four-category wardrobe and export requirements |
| `OWOTS_WARDROBE_UI_AND_EXPORT_PLAN.md` | Existing wardrobe UI and export plan |
| `OWOTS_APPEARANCE_*.md` | Appearance requirements, architecture, runtime/save research, user guide and historical handoff |
| `OWOTS_ASSET_LOADING_RESEARCH.md` | Asset loading and resource lifecycle research |
| `AGENTS.md` | Documentation and prototype maintenance rules |

## Subdirectories
None.

## Dependencies
- Documentation is Markdown; the converter design prototype is self-contained HTML/CSS/JavaScript with no network or package dependencies.
- Private sample assets and diagnostic artifacts live under workspace `_validation/`, outside this source repository.

## For AI Agents
- Separate proposed behavior from current implementation and from live-verified behavior. Schema 3 `rules.equip` is implemented and core-tested with manual accessory overrides; it does not allow body to provide cross-category parts. The runtime bundle compiles; live validation remains distinct. The old complex HTML prototype is superseded by the minimal native GUI. Common mods are the target; special rigs/scripts are diagnosed without forced compatibility.
- Do not infer sample behavior from its title or description. The 2026-09-18 sample study used asset structures only and disabled source Mod metadata parsing.
- Rotation-only mismatch in an unreferenced 93-joint rig now selects BODY mesh rest automatically, following the user's earlier successful AI-START conversion. Keep topology/scale validation and the needs-test notice. This does not add rotation retargeting to the runtime.
- Prototype actions must remain clearly simulated until a real converter is connected. Never present the demo output counts as successful conversions of the private samples.
- Historical runtime notes are time- and scenario-specific. Do not promote parsing or program completion into visual acceptance.
- Keep this guide synchronized when documentation structure changes.
