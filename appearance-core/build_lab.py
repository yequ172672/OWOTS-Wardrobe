"""Bundle the tested core into REF's single-source plugin without a new runtime DLL."""
import argparse
import hashlib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
args = parser.parse_args()
core_dir = Path(__file__).resolve().parent
repo = core_dir.parent
lab = (repo / 'reframework/plugins/source/OWOTSAppearanceLab.cs').read_text(encoding='utf-8-sig')
# Namespace-local usings preserve each source's imports. Both copies come from the
# same tested source, so the runtime does not maintain a separate parser implementation.
combined = lab
for name in ('AppearanceRegistry.cs', 'AppearanceSaveStore.cs', 'NativeCostumeSelections.cs', 'WardrobePreferences.cs', 'AppearanceOperationClock.cs', 'WardrobeComposition.cs', 'WardrobeManifest.cs', 'WardrobeSkeleton.cs', 'WardrobeRegistry.cs', 'WardrobeSelectionState.cs', 'WardrobeSaveStore.cs'):
    core = (core_dir / name).read_text(encoding='utf-8-sig')
    prefix, separator, body = core.partition('namespace OWOTS.Appearance;')
    if not separator:
        raise RuntimeError(f'Expected the core namespace declaration in {name}')
    combined += '\n#nullable enable\nnamespace OWOTS.Appearance {\n' + prefix + body + '\n}\n'
output = Path(args.output).resolve()
if output == (repo / 'reframework/plugins/source/OWOTSAppearanceLab.cs').resolve():
    raise RuntimeError('Do not overwrite the lab source with generated output')
output.parent.mkdir(parents=True, exist_ok=True)
payload = combined.encode('utf-8')
output.write_bytes(payload)
print(f'{output}\nSHA256 {hashlib.sha256(payload).hexdigest()}')
