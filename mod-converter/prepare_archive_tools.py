"""Stage the unmodified official 7-Zip 26.03 RAR reader from an extracted MSI.

Developer only: obtain https://github.com/ip7z/7zip/releases/download/26.03/7z2603-x64.msi
(SHA256 c0680064d698a62dd4a5a47f403db356a6531a5473e4c4b1d090ea2590513926).
Use Windows Installer administrative extraction into a private build directory,
then pass its Files/7-Zip folder. This script never installs shell integration.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil

HASHES = {
    '7z.exe': '6ee3c0ed0b27663c1b948ae85a7c0bb073aed1498983182f3f0df1f6a8c30b2f',
    '7z.dll': '65e4c1f855f9ef6e8f0f5df8e3f27d9eb5f07311408639da0a1ca0b8f4871b0d',
}
SOURCE_NAME = '7z2603-src.7z'
SOURCE_HASH = '41e2a7c0e9f838351c625e01f0f581a2188bb3dda10c8e0b4a852da26546ffe2'


def prepare(source, runtime, source_archive):
    if hashlib.sha256(source_archive.read_bytes()).hexdigest() != SOURCE_HASH:
        raise ValueError('Unexpected 7-Zip corresponding source digest')
    for name, digest in HASHES.items():
        if hashlib.sha256((source/name).read_bytes()).hexdigest() != digest:
            raise ValueError('Unexpected 7-Zip binary digest: '+name)
    destination = runtime/'7zip'
    destination.mkdir(exist_ok=True)
    for name in (*HASHES, 'License.txt'):
        target = destination/name
        shutil.copyfile(source/name, target)
    if source_archive.resolve() != (destination/SOURCE_NAME).resolve():
        shutil.copyfile(source_archive, destination/SOURCE_NAME)
    (destination/'SOURCE.json').write_text(json.dumps({'version': '26.03', 'modified': False,
        'upstream': 'https://www.7-zip.org/',
        'source': 'https://github.com/ip7z/7zip/releases/download/26.03/7z2603-src.7z',
        'correspondingSource': SOURCE_NAME, 'sourceSha256': SOURCE_HASH,
        'binary': 'https://github.com/ip7z/7zip/releases/download/26.03/7z2603-x64.msi'}, indent=2), encoding='utf-8')
    manifest = runtime/'runtime-manifest.json'
    data = json.loads(manifest.read_text(encoding='utf-8'))
    files = [{'path': target.relative_to(runtime).as_posix(), 'bytes': target.stat().st_size,
              'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}
             for target in sorted(destination.iterdir()) if target.is_file()]
    data['files'] = [entry for entry in data['files'] if not entry['path'].startswith('7zip/')]+files
    manifest.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--from-directory', type=Path, required=True)
    parser.add_argument('--source-archive', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.from_directory, Path(__file__).resolve().parent/'runtime', args.source_archive)
