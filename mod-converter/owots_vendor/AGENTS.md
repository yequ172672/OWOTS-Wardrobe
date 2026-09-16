# Portable format helpers

## Subdirectories
| Directory | Purpose |
| --- | --- |
| `hashing` | Existing RE Engine Murmur3 UTF-16 path hash implementation |
| `mdf` | Existing OWOTS MDF 51 binary parser/writer |
| `workspace` | Pure Python material remapping, catalogs and RSZ worker client |
| `pak` | Existing RE Asset Library encrypted-TOC/chunk reader and extracted entry-reader functions |
| `encryption` | Existing standard game PAK table/resource transforms; not custom MOD envelope decryption |

## Key Files
| File | Purpose |
| --- | --- |
| `gen_functions.py` | Shared binary primitives; import-time console command removed |
| `__init__.py` | Standalone package boundary; no Blender import |
| `LICENSE.GPL` | Original GPL license for copied source helpers |
| `SOURCE-NOTICE.json` | Original repository revision, per-file source/output hashes and changes |

## Dependencies
- Python 3.11 or later; selected helpers use the standard library only.
- `workspace.appearance_resources` optionally invokes the separately packaged .NET RSZ worker.
- `pak.entry_reader` uses zstandard for ordinary ZSTD entries and native chunk tables.

## For AI Agents
- Regenerate from the explicit source map in `../prepare_dependencies.py`; preserve provenance and GPL notice.
- Import as `owots_vendor`, never modify `sys.path` to depend on a sibling checkout or load Blender.
- Do not replace structured MDF readback with arbitrary binary string substitution.
- No game payloads, generated game assemblies, or user MOD resources belong here.
