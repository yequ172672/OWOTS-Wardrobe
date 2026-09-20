"""Build a portable Windows GUI release without game assets or sample MODs.

Run with a Python environment containing pinned PyInstaller and zstandard.
prepare_dependencies.py must have prepared runtime/ first. Outputs are new
directories only; no deletion, installation, or modification of source MODs.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.metadata
import json
import shutil
import subprocess
import sys
import zipfile

RELEASE_VERSION = '2026.09.20b'
RELEASE_DATE = '20260920b'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New directory for build intermediates')
    parser.add_argument('--release-dir', type=Path, default=root.parent/'release', help='Final package directory (default: project release/)')
    args = parser.parse_args()
    output = args.output.resolve()
    release = args.release_dir.resolve()
    archive = release / f'OWOTS-ModConverter-{RELEASE_DATE}.zip'
    if archive.exists():
        raise SystemExit('Release archive already exists; use a new version or --release-dir')
    if output.exists():
        raise SystemExit('Build output already exists; choose a new path')
    runtime = root / 'runtime'
    if not (runtime / 'AppearanceRsz.exe').is_file():
        raise SystemExit('Run prepare_dependencies.py first')
    if not (runtime / '7zip/7z.exe').is_file():
        raise SystemExit('Run prepare_archive_tools.py first')
    output.mkdir(parents=True)
    staged_runtime = output / 'bundled-runtime'
    shutil.copytree(runtime, staged_runtime, ignore=shutil.ignore_patterns('OWOTS_STM_Release.list'))
    runtime_manifest_path = staged_runtime / 'runtime-manifest.json'
    runtime_manifest = json.loads(runtime_manifest_path.read_text(encoding='utf-8'))
    runtime_manifest['files'] = [entry for entry in runtime_manifest['files']
                                 if entry['path'] != 'OWOTS_STM_Release.list']
    runtime_manifest['externalFileList'] = 'OWOTS_STM_Release.list beside the executable; covered by release-manifest.json'
    runtime_manifest_path.write_text(json.dumps(runtime_manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    build_licenses = output / 'dependency-licenses'
    build_licenses.mkdir()
    shutil.copyfile(Path(sys.base_prefix) / 'LICENSE.txt', build_licenses / 'Python-LICENSE.txt')
    tk_license = Path(sys.base_prefix) / 'tcl/tk8.6/license.terms'
    if tk_license.is_file():
        shutil.copyfile(tk_license, build_licenses / 'Tk-license.terms')
    versions = {}
    for name in ('pyinstaller', 'pyinstaller-hooks-contrib', 'zstandard', 'altgraph', 'pefile', 'pywin32-ctypes', 'packaging',
                 'tkinterdnd2', 'rarfile', 'py7zr', 'backports.zstd', 'brotli', 'psutil', 'pycryptodomex',
                 'pyppmd', 'pybcj', 'multivolumefile', 'inflate64', 'texttable'):
        distribution = importlib.metadata.distribution(name)
        versions[name] = distribution.version
        for relative in distribution.files or []:
            if relative.name.upper().startswith(('LICENSE', 'COPYING')):
                source = Path(distribution.locate_file(relative))
                if source.is_file():
                    shutil.copyfile(source, build_licenses / (name + '-' + relative.name))
    subprocess.run([sys.executable, '-m', 'PyInstaller', '--noconfirm', '--onefile', '--windowed',
                    '--name', 'OWOTS-ModConverter', '--distpath', str(output / 'dist'),
                    '--workpath', str(output / 'work'), '--specpath', str(output),
                    '--paths', str(root), '--collect-submodules', 'owots_vendor',
                    '--collect-all', 'zstandard', '--hidden-import', 'game_pak_reference',
                    '--hidden-import', 'texture_resolution',
                    '--collect-all', 'tkinterdnd2', '--collect-all', 'py7zr',
                    '--collect-all', 'backports.zstd', '--collect-all', 'pyppmd',
                    '--collect-all', 'inflate64', '--collect-all', 'bcj',
                    '--collect-all', 'Cryptodome', '--hidden-import', 'rarfile',
                    '--add-data', str(staged_runtime) + ';runtime',
                    '--add-data', str(build_licenses) + ';licenses',
                    str(root / 'converter_gui.py')], check=True)
    package = output / 'dist/OWOTS-ModConverter'
    package.mkdir()
    (output / 'dist/OWOTS-ModConverter.exe').rename(package / 'OWOTS-ModConverter.exe')
    shutil.copyfile(runtime / 'OWOTS_STM_Release.list', package / 'OWOTS_STM_Release.list')
    # The EXE is windowed, so a startup crash would otherwise ship silently.
    self_test = subprocess.run([str(package / 'OWOTS-ModConverter.exe'), '--self-test'],
                               cwd=package, capture_output=True, text=True)
    if self_test.returncode != 0:
        raise SystemExit('Packaged GUI self-test failed (rc={}): {}{}'.format(
            self_test.returncode, self_test.stdout, self_test.stderr))
    shutil.copytree(build_licenses, package / 'licenses')
    source_target = package / 'source'
    source_target.mkdir()
    for filename in ('mod_converter.py', 'converter_gui.py', 'game_pak_reference.py',
                     'texture_resolution.py', 'input_containers.py', 'rsz_paths.py', 'mesh_probe.py',
                     'batch_converter.py', 'appearance_duplicates.py', 'prepare_dependencies.py', 'prepare_archive_tools.py', 'build_release.py',
                     'convert_mod.cmd', 'README.md', 'AI-START.md', 'requirements.txt', 'requirements-build.txt', 'AGENTS.md'):
        shutil.copyfile(root / filename, source_target / filename)
    for dirname in ('owots_vendor', 'tests', 'licenses', 'ai-skill'):
        shutil.copytree(root / dirname, source_target / dirname,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    shutil.copytree(staged_runtime, source_target / 'runtime')
    shutil.copyfile(root / 'README.md', package / 'README-zh-CN.md')
    shutil.copyfile(root / 'AI-START.md', package / 'AI-START.md')
    shutil.copytree(root / 'ai-skill', package / 'ai-skill',
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    shutil.copyfile(root / 'owots_vendor/LICENSE.GPL', package / 'LICENSE.GPL')
    (source_target / 'SOURCE-RUN.txt').write_text(
        'Source mode: copy ../OWOTS_STM_Release.list beside these scripts; '
        'then install requirements.txt with Python 3.11+. The EXE needs no Python installation.\n', encoding='utf-8')
    files = [dict(path=p.relative_to(package).as_posix(), bytes=p.stat().st_size, sha256=digest(p))
             for p in sorted(package.rglob('*')) if p.is_file()]
    (package / 'release-manifest.json').write_text(json.dumps(dict(
        name='OWOTS-ModConverter', version=RELEASE_VERSION, python=sys.version,
        dependencies=versions, prerequisites=['.NET 10 x64 runtime for structured resource worker'],
        gameAssetsIncluded=False, files=files), ensure_ascii=False, indent=2), encoding='utf-8')
    release.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
        for path in sorted(package.rglob('*')):
            if path.is_file():
                bundle.write(path, Path(package.name) / path.relative_to(package))
    (release / (archive.name + '.sha256')).write_text(digest(archive) + '  ' + archive.name + '\n', encoding='ascii')
    print(json.dumps(dict(archive=str(archive), sha256=digest(archive), bytes=archive.stat().st_size)))


if __name__ == '__main__':
    main()
