"""Offline structured-resource worker client; no bpy or deployment side effects."""
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from .appearance_project import _logical_path


@dataclass(frozen=True)
class ResourceBinding:
    location: str
    path: str

    @property
    def logical_path(self):
        return _logical_path(self.path.removeprefix("@"))


@dataclass(frozen=True)
class ResourceInspection:
    source_sha256: str
    bindings: tuple
    crc_warnings: tuple

    @property
    def dependencies(self):
        # Tables and fields can repeat the same reference, with/without @.
        paths = {}
        for binding in self.bindings:
            paths.setdefault(binding.logical_path.casefold(), binding.logical_path)
        return tuple(paths[key] for key in sorted(paths))


class ResourceWorkerError(RuntimeError):
    pass


def read_custom_resource(logical, local_file, original_file):
    """Read authored bytes without replacing the native source or checking rigs.

    Structured configuration needs dependency rediscovery and is not a raw
    replacement. The caller separately requires this to be a graph leaf.
    """
    logical=_logical_path(logical.removeprefix('@'))
    extension=Path(logical).suffix.lower()
    if extension in ('.pfb','.user','.mdf2'):
        raise ValueError('Structured resource sources require dependency-aware editing')
    if extension=='.tex':
        raise ValueError('Texture source registration requires base/streaming companion selection')
    source=Path(local_file).resolve(strict=True)
    original=Path(original_file)
    if (not original.suffix[1:].isdigit() or source.suffix.lower()!=original.suffix.lower()
            or len(source.suffixes)<2 or source.suffixes[-2].lower()!=extension):
        raise ValueError('Custom resource format/version must match the original reference')
    payload=source.read_bytes()
    if not payload:
        raise ValueError('Custom resource file is empty')
    return payload,hashlib.sha256(payload).hexdigest()


def mesh_import_sources(bindings, extract_root):
    """Pair mesh/MDF fields on each actual via.render.Mesh RSZ instance.

    Resource-table ordering does not establish a pairing. Import ORIGINAL paths;
    edited target paths are for export and need not exist yet.
    """
    root = Path(extract_root).resolve(strict=True)
    groups = {}
    for binding in bindings:
        fields = binding.location.split('/')
        if len(fields) < 5 or fields[0] != 'instances' or fields[2] != 'via.render.Mesh':
            continue
        group = groups.setdefault(fields[1], {})
        path = binding.logical_path
        kind = next((kind for kind in ('mesh', 'mdf2') if path.lower().endswith('.'+kind)), None)
        if kind:
            if kind in group and group[kind].casefold() != path.casefold():
                raise ValueError('Ambiguous mesh component resource fields')
            group[kind] = path
    result = []
    for group in groups.values():
        if 'mesh' not in group:
            continue
        if 'mdf2' not in group:
            raise ValueError('Mesh component has no verified MDF binding')
        resolved = {}
        for kind, version in (('mesh', '260209350'), ('mdf2', '51')):
            source = (root/(group[kind]+'.'+version)).resolve(strict=True)
            if not source.is_relative_to(root):
                raise ValueError('Source escaped the extracted directory')
            resolved[kind] = source
        if resolved not in result:
            result.append(resolved)
    if not result:
        raise ValueError('No supported via.render.Mesh references found in this PFB')
    return tuple(result)


class ResourceWorker:
    def __init__(self, executable, template, *, dotnet="dotnet", timeout=60):
        self.executable = Path(executable).resolve(strict=True)
        self.template = Path(template).resolve(strict=True)
        self.dotnet = str(dotnet)
        self.timeout = timeout

    def inspect(self, source):
        report, _ = self._run(source, None, {})
        bindings = tuple(ResourceBinding(item["Location"], item["Path"])
                         for item in report["Bindings"])
        inspection = ResourceInspection(report["SourceSha256"], bindings,
                                        tuple(report["CrcWarnings"]))
        # Validate all discovered paths before giving callers a dependency set.
        inspection.dependencies
        return inspection

    def read_catalog(self, source, part, logical_catalog):
        """Read native ID/PFB associations from an inspected PlayerPartsList."""
        from .appearance_catalog import read_parts_catalog
        report, _ = self._run(source, None, {})
        return read_parts_catalog(report, part, logical_catalog)

    def rewrite(self, source, destination, remap, *, expected_source_sha256,
                allow_crc_mismatch=False, native_part_id=None):
        """Write a NEW staging file after validating worker output and input hash.

        The required source hash binds author edits to the inspected source.
        The caller owns publication/rollback. Nothing is copied into the game.
        """
        destination = Path(destination)
        if destination.exists():
            raise ResourceWorkerError("Staging destination already exists")
        normalized = {}
        keys = set()
        for old, new in remap.items():
            old = _logical_path(old.removeprefix("@"))
            new = _logical_path(new.removeprefix("@"))
            if "@" in old or "@" in new or old.casefold() in keys:
                raise ValueError("Invalid or duplicate normalized remap")
            keys.add(old.casefold())
            normalized[old] = new
        report, payload = self._run(source, destination.name, normalized,
                                    expected_source_sha256=expected_source_sha256,
                                    allow_crc_mismatch=allow_crc_mismatch, native_part_id=native_part_id)
        # Never replace an existing staged result, including a concurrent writer.
        with destination.open("xb") as stream:
            stream.write(payload)
        return report["OutputSha256"]

    def _run(self, source, output_name, remap, *, expected_source_sha256=None,
             allow_crc_mismatch=False, native_part_id=None):
        source = Path(source).resolve(strict=True)
        before = hashlib.sha256(source.read_bytes()).hexdigest()
        if expected_source_sha256 is not None and before != expected_source_sha256:
            raise ResourceWorkerError("Source changed since inspection; reimport its references")
        with tempfile.TemporaryDirectory(prefix="re-appearance-rsz-") as temporary:
            work = Path(temporary)
            output = work / "rewritten" / output_name if output_name else None
            if output:
                output.parent.mkdir()
            request = {"Operation": "rewrite" if output else "inspect",
                       "Input": str(source), "Template": str(self.template),
                       "Output": str(output) if output else None,
                       "Remap": remap, "AllowCrcMismatch": bool(allow_crc_mismatch)}
            if native_part_id is not None:
                if type(native_part_id) is not int or not -(2**31) <= native_part_id < 2**31:
                    raise ValueError('Native part ID must be a signed 32-bit integer')
                request['NativePartId']=native_part_id
            request_path, result_path = work/"request.json", work/"result.json"
            request_path.write_text(json.dumps(request), encoding="utf-8")
            command = ([self.dotnet, str(self.executable)] if self.executable.suffix.lower() == ".dll"
                       else [str(self.executable)]) + [str(request_path), str(result_path)]
            try:
                process = subprocess.run(command, capture_output=True, timeout=self.timeout,
                                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            except (OSError, subprocess.TimeoutExpired) as error:
                raise ResourceWorkerError(f"Resource worker did not complete: {error}") from error
            if process.returncode:
                diagnostic = (process.stderr + process.stdout).decode("utf-8", errors="replace")[-6000:]
                raise ResourceWorkerError(f"Resource worker failed: {diagnostic}")
            try:
                report = json.loads(result_path.read_text(encoding="utf-8"))
                if report["SchemaVersion"] != 1 or report["Operation"] != request["Operation"]:
                    raise ValueError("Unexpected worker protocol")
                after = hashlib.sha256(source.read_bytes()).hexdigest()
                if report["SourceSha256"] != before or after != before:
                    raise ValueError("Source changed during resource processing")
                payload = output.read_bytes() if output else None
                if output and (report["ReadbackVerified"] is not True or
                               hashlib.sha256(payload).hexdigest() != report["OutputSha256"]):
                    raise ValueError("Unverified or modified worker output")
                return report, payload
            except (OSError, ValueError, KeyError, TypeError) as error:
                raise ResourceWorkerError(f"Invalid resource worker result: {error}") from error
