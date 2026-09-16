"""Developer packaging step; players use the already prepared runtime folder.

Copies tested pure-Python format readers with their source and licenses, then
publishes the existing RSZ worker. No game assets or generated game SDKs are read.
"""
from pathlib import Path
import argparse
import ast
import hashlib
import json
import shutil
import subprocess


FILES = (
    'gen_functions.py',
    'hashing/mmh3/pymmh3.py',
    'mdf/file_re_mdf.py',
    'workspace/appearance_project.py',
    'workspace/appearance_mdf.py',
    'workspace/appearance_catalog.py',
    'workspace/appearance_resources.py',
)

ASSET_FILES = ('pak/file_re_pak.py', 'encryption/re_pak_encryption.py')
PAK_DEFINITIONS = {'CompressionTypes', '_getPakEntryValue', '_getPakEntryOffsetType', 'readPakEntryData'}


def copy_pak_helpers(workspace, vendor):
    source_root = workspace / 'RE-Asset-Library-cn'
    records = []
    for relative in ASSET_FILES:
        source = source_root / 'modules' / relative
        destination = vendor / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        records.append(dict(source='RE-Asset-Library-cn/modules/' + relative,
                            destination='owots_vendor/' + relative,
                            sourceSha256=digest(source), sha256=digest(destination), changes=[]))
    source = source_root / 'modules/pak/re_pak_utils.py'
    code = source.read_text(encoding='utf-8-sig')
    syntax = ast.parse(code)
    selected = [node for node in syntax.body if isinstance(node, (ast.ClassDef, ast.FunctionDef))
                and node.name in PAK_DEFINITIONS]
    if {node.name for node in selected} != PAK_DEFINITIONS:
        raise RuntimeError('PAK helper source definitions changed')
    header = ('"""Selected verified RE Asset Library PAK reader functions; GPL source attribution in SOURCE-NOTICE.json."""\n'
              'import zlib\nimport zstandard as zstd\nfrom ..encryption.re_pak_encryption import decryptResource\n\n')
    payload = header + '\n\n'.join(ast.get_source_segment(code, node) for node in selected) + '\n'
    destination = vendor / 'pak/entry_reader.py'
    destination.write_text(payload, encoding='utf-8')
    records.append(dict(source='RE-Asset-Library-cn/modules/pak/re_pak_utils.py',
                        destination='owots_vendor/pak/entry_reader.py', sourceSha256=digest(source),
                        sha256=digest(destination), changes=['Extracted four reader definitions verbatim; imports reduced to dependencies']))
    return records


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parent / 'runtime')
    args = parser.parse_args()
    workspace = args.workspace.resolve(strict=True)
    root = Path(__file__).resolve().parent
    output = args.output.resolve()
    if output.exists():
        raise SystemExit('Choose a new runtime output directory; existing runtime is preserved')
    mesh = workspace / 'RE-Mesh-Editor-main'
    ree = workspace / 'REE-Content-Editor/RE-Engine-Lib'
    vendor = root / 'owots_vendor'
    records = []
    for relative in FILES:
        source = mesh / 'modules' / relative
        destination = vendor / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        payload = source.read_bytes()
        changes = []
        if relative == 'gen_functions.py':
            # Importing a format parser must not launch a console command.
            text = payload.decode('utf-8-sig')
            text = text.replace('os.system("color")#Enable console colors',
                                '# Console color initialization omitted by the standalone converter.')
            payload = text.encode('utf-8')
            changes.append('Removed import-time os.system(color) console side effect')
        destination.write_bytes(payload)
        records.append(dict(source='RE-Mesh-Editor-main/modules/' + relative,
                            destination='owots_vendor/' + relative,
                            sourceSha256=digest(source), sha256=digest(destination), changes=changes))
    records.extend(copy_pak_helpers(workspace, vendor))
    for directory in [vendor, *(path for path in vendor.rglob('*') if path.is_dir() and '__pycache__' not in path.parts)]:
        (directory / '__init__.py').write_text('"""Vendored format helpers; see SOURCE-NOTICE.json."""\n', encoding='utf-8')
    shutil.copyfile(mesh / 'LICENSE.GPL', vendor / 'LICENSE.GPL')
    revision = subprocess.check_output(['git', '-C', str(mesh), 'rev-parse', 'HEAD'], text=True).strip()
    (vendor / 'SOURCE-NOTICE.json').write_text(json.dumps(dict(
        upstream='https://github.com/NSACloud/RE-Mesh-Editor',
        pakUpstream='https://github.com/NSACloud/RE-Asset-Library',
        fork='https://github.com/yequ172672/RE-Mesh-Editor-5.2-CN',
        revision=revision, license='GPL-3.0; source and license included', files=records
    ), ensure_ascii=False, indent=2), encoding='utf-8')
    output.mkdir(parents=True)
    project = mesh / 'tools/appearance-rsz/AppearanceRsz.csproj'
    ree_project = ree / 'REE-Lib/REE-Lib.csproj'
    subprocess.run(['dotnet', 'publish', str(project), '-c', 'Release', '--no-self-contained',
                    '-p:ReeLibProject=' + str(ree_project), '-p:DebugType=None', '-o', str(output)], check=True)
    metadata = mesh / 'modules/workspace/appearance_data'
    for filename in ('rszoniwots.json', 'OWOTS_STM_Release.list', 'manifest.json', 'NOTICE.txt'):
        shutil.copyfile(metadata / filename, output / filename)
    for filename in ('owots_native_parts.json', 'owots_body_rules.json'):
        shutil.copyfile(mesh / 'modules/workspace' / filename, output / filename)
    source_dir = output / 'worker-source'
    source_dir.mkdir()
    for filename in ('Program.cs', 'AppearanceRsz.csproj', 'AGENTS.md'):
        shutil.copyfile(project.parent / filename, source_dir / filename)
    licenses = output / 'licenses'
    licenses.mkdir()
    shutil.copyfile(ree / 'LICENSE', licenses / 'REE-Lib-LICENSE.txt')
    shutil.copyfile(mesh / 'LICENSE.GPL', licenses / 'AppearanceRsz-GPL.txt')
    for license_file in (root / 'licenses').glob('*'):
        if license_file.is_file():
            shutil.copyfile(license_file, licenses / license_file.name)
    runtime_files = [dict(path=path.relative_to(output).as_posix(), bytes=path.stat().st_size,
                          sha256=digest(path)) for path in sorted(output.rglob('*')) if path.is_file()]
    (output / 'runtime-manifest.json').write_text(json.dumps(dict(
        framework='.NET 10 x64 runtime required; worker published framework-dependent',
        source='https://github.com/yequ172672/RE-Mesh-Editor-5.2-CN',
        reeLibSource='https://github.com/kagenocookie/RE-Engine-Lib', files=runtime_files
    ), ensure_ascii=False, indent=2), encoding='utf-8')
    print(output)


if __name__ == '__main__':
    main()
