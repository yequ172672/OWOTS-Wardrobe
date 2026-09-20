"""Player workflow: input containers -> proven part graphs -> atomic packages.

This module owns source/reference lifetimes. The GUI exchanges plain dataclasses
and progress callbacks; it never selects raw PFB paths or assembles manifests.
"""
from __future__ import annotations
from contextlib import ExitStack
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
import hashlib
import json
import re
import shutil
import tempfile
import zipfile

import mod_converter as mc
from input_containers import ExpandedInput, InputError
import rsz_paths
from appearance_duplicates import AppearanceFingerprints, deduplicate_groups


LABELS = {'body': '服装', 'cloak': '披风', 'gauntlet': '护手', 'weapon': '武器'}
GRAPH_FORMATS = {'.pfb', '.user', '.mdf2', '.mmi', '.mpi'}


@dataclass
class Notice:
    code: str
    message: str
    paths: list[str] = field(default_factory=list)


@dataclass
class Result:
    source: str
    output: str | None = None
    entries: list[dict] = field(default_factory=list)
    notices: list[Notice] = field(default_factory=list)
    ledger: list[dict] = field(default_factory=list)
    status: str = 'converted'
    placeholder_evidence: list[dict] = field(default_factory=list)

    def as_dict(self):
        from dataclasses import asdict
        return asdict(self)


class CachedWorker:
    def __init__(self, worker):
        self.worker = worker
        self.cache = {}
    def inspect(self, path):
        key = str(path)
        if key not in self.cache:
            self.cache[key] = self.worker.inspect(path)
        return self.cache[key]
    def rewrite(self, *args, **kwargs): return self.worker.rewrite(*args, **kwargs)


class PlannedConverter(mc.Converter):
    """Uses byte-preserving paths, with structured catalog row verification."""
    def _resolve_asset(self, logical, streaming=False):
        if (not streaming and self.bundle is not None
                and self.bundle.source.get(logical) is None
                and self.bundle.source.get(logical, True) is None
                and PurePosixPath(logical).suffix.casefold() not in GRAPH_FORMATS):
            # A stock PFB/MDF is the authority for its unmodified leaf reference.
            # Its mesh/texture/physics bytes need not be read or redistributed.
            return mc.Asset(logical, '', False, self.game.root, 'game', 0)
        return super()._resolve_asset(logical, streaming)

    def _inspect_node(self, logical, asset):
        if asset.extension in ('.pfb', '.user') and logical.casefold() not in self.catalog_selection:
            try:
                deps = rsz_paths.dependencies(asset.path.read_bytes())
            except ValueError as error:
                raise mc.ConversionError(str(error), 'RSZ_PATH_LAYOUT_UNSUPPORTED') from error
            return mc.ResourceNode(logical, asset, deps)
        return super()._inspect_node(logical, asset)

    def _compute_routes(self):
        super()._compute_routes()
        try:
            self.routes = {key: rsz_paths.private_path(self.args.mod_id, self.nodes[key].logical)
                           for key in self.routes}
        except ValueError as error:
            raise mc.ConversionError(str(error), 'PRIVATE_PATH_TOO_SHORT') from error
        if len(set(value.casefold() for value in self.routes.values())) != len(self.routes):
            raise mc.ConversionError('独立资源路径重复。', 'PRIVATE_PATH_COLLISION')

    def _copy_or_rewrite(self, node, destination, remap, selection, payload_override=None):
        if node.asset.extension in ('.pfb', '.user') and selection is None:
            try:
                payload, proof = rsz_paths.rewrite(node.asset.path.read_bytes(), dict(remap))
            except ValueError as error:
                raise mc.ConversionError(str(error), 'RSZ_PATH_REWRITE_FAILED') from error
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open('xb') as stream: stream.write(payload)
            if destination.read_bytes() != payload:
                raise mc.ConversionError('写入结果核对失败。', 'OUTPUT_READBACK_FAILED')
            self.report.stats.setdefault('pathProofs', {})[node.logical] = proof
            return proof
        return super()._copy_or_rewrite(node, destination, remap, selection, payload_override)


@dataclass
class Candidate:
    record: dict
    reached: set[str]
    changed: set[str]
    covered_targets: list[dict] = field(default_factory=list)


def group_candidates(candidates: list[Candidate]) -> list[list[Candidate]]:
    """No cartesian products: same-ID weapon parts, unique body companions.

    A single modified HEAD/HAIR
    in the same package applies to its body's graph; ambiguous alternatives
    remain separate results instead of being guessed into one appearance.
    """
    groups = []
    used = set()
    for variant in ('normal', 'hq'):
        current = [c for c in candidates if c.record['variant'] == variant]
        for category in ('body', 'weapon'):
            selected = [c for c in current if mc.PART_CATEGORY[c.record['part']] == category]
            primary = 'BODY' if category == 'body' else 'WEAPON'
            for candidate in [c for c in selected if c.record['part'] == primary]:
                group = [candidate]
                for part in mc.PARTS[category]:
                    if part == primary: continue
                    options = [c for c in selected if c.record['part'] == part]
                    exact = [c for c in options if c.record['native_id'] == candidate.record['native_id']]
                    # A lone authored HEAD/HAIR is shared with each replaced BODY.
                    companions = exact if exact else options if category == 'body' and part in ('HEAD', 'HAIR') and len(options) == 1 else []
                    if len(companions) == 1: group.extend(companions)
                groups.append(group)
                used.update(id(c) for c in group)
        for candidate in current:
            if id(candidate) not in used:
                groups.append([candidate])
                used.add(id(candidate))
    return groups


def companion_candidates(body: dict, entries: list[dict], category: str) -> list[dict]:
    def targets(entry):
        return entry['targets'] + entry.get('coveredTargets', [])
    variants = {t['variant'] for t in targets(body)}
    options = [entry for entry in entries if entry['category'] == category
               and variants & {t['variant'] for t in targets(entry)}]
    if len(options) < 2:
        return options
    def family(entry):
        matches = [re.match(r'^(ch\d+_\d+)_', PurePosixPath(t['prefab']).stem.casefold()) for t in targets(entry)]
        return {match[1] for match in matches if match}
    owner = family(body)
    related = [entry for entry in options if owner & family(entry)]
    # Shared meshes can affect several original character families. Prefer only
    # an unambiguous same-family attachment; keep all visible registrations.
    return related if len(related) == 1 else options


class BatchConverter:
    def __init__(self, game_root: Path, *, progress=lambda text: None, cancelled=lambda: False):
        self.game_root = Path(game_root).resolve(strict=True)
        self.progress = progress
        self.cancelled = cancelled
        self.stack = ExitStack()
        self.game = None
        self.worker = None
        self.dependency_cache = {}
        self.geometry_cache = {}
        self.records = json.loads((Path(mc.__file__).parent/'runtime/owots_native_parts.json').read_text(encoding='utf-8'))['records']

    def __enter__(self): return self
    def __exit__(self, *args):
        if self.game: self.game.close()
        self.stack.close()

    def check_cancel(self):
        if self.cancelled(): raise InputError('已取消。', 'CANCELLED')

    def _setup(self, source):
        if self.game: return
        self.progress('正在读取游戏目录…')
        args = mc.make_parser().parse_args(['convert', '--input', str(source), '--output', str(source.parent/'unused'), '--game-root', str(self.game_root)])
        report = mc.Report('batch', source)
        converter = mc.Converter(args, report)
        converter._prepare_game()
        self.game = converter.game
        if report.errors: raise mc.ConversionError(report.errors[0].message, report.errors[0].code)
        if not converter.worker: raise mc.ConversionError('缺少转换组件，请重新解压程序。', 'WORKER_MISSING')
        self.worker = CachedWorker(converter.worker)

    def _layers(self, source, result, depth=0):
        self.check_cancel()
        if depth > 3: raise InputError('压缩包嵌套过多，请先解压后再拖入。', 'ARCHIVE_DEPTH')
        expanded = self.stack.enter_context(ExpandedInput(source, self.cancelled))
        root = expanded.root
        omitted = list(expanded.omitted)
        if root.is_file():
            yield root
        else:
            files = sorted(root.rglob('*'))
            native_roots = sorted({p.parent.parent for p in files if p.is_dir() and p.name.casefold() == 'stm' and p.parent.name.casefold() == 'natives'})
            if native_roots:
                yield from native_roots
            elif any(p.is_file() and re.search(r'\.(?:mesh|mdf2|tex|pfb)\.\d+$', p.name, re.I) for p in files):
                yield root
            for path in files:
                if path.is_file() and path.suffix.casefold() in ('.zip', '.rar', '.7z', '.pak'):
                    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
                        raise InputError('输入包含指向目录外的链接。', 'INPUT_PATH_ESCAPE')
                    yield from self._layers(path, result, depth+1)
                elif path.is_file() and path.suffix.casefold() in mc.SCRIPTS_OR_PLUGINS:
                    omitted.append(path.relative_to(root).as_posix())
        scripts = [name for name in omitted if Path(name).suffix.casefold() in mc.SCRIPTS_OR_PLUGINS]
        if scripts: result.notices.append(Notice('STATIC_ASSETS_ONLY', '包中有脚本或插件，已只转换模型和附属资源；部分效果可能无法工作。', scripts))
        other_assets = [name for name in omitted if re.search(r'\.[a-z][a-z0-9_]*\.\d+$', name, re.I)]
        if other_assets:
            result.notices.append(Notice('OUTSIDE_WARDROBE_SCOPE', '这些资源暂不能转为服装，已跳过；部分效果可能无法工作。', other_assets))
            result.ledger.extend({'path': name, 'disposition': 'unsupported'} for name in other_assets)

    def _dependencies(self, logical, source):
        asset = source.get(logical) or self.game.find(logical)
        if asset is None: raise mc.ConversionError('缺少原版资源：' + logical, 'GAME_ASSET_MISSING')
        key = str(asset.path)
        if key not in self.dependency_cache:
            payload = asset.path.read_bytes()
            if asset.extension in ('.pfb', '.user'):
                deps = rsz_paths.dependencies(payload)
            elif asset.extension == '.mdf2': deps = mc.mdf_dependencies(payload)
            else: deps = mc._extract_paths(payload)
            self.dependency_cache[key] = deps
        return self.dependency_cache[key]

    def _candidate(self, record, source):
        pending = [record['prefab']]
        reached = set()
        while pending:
            self.check_cancel()
            logical = pending.pop()
            key = logical.casefold()
            if key in reached: continue
            reached.add(key)
            if PurePosixPath(logical).suffix.casefold() in GRAPH_FORMATS:
                try:
                    pending.extend(self._dependencies(logical, source))
                except (mc.ConversionError, ValueError, OSError) as error:
                    error.reached_assets = reached | {path.casefold() for path in pending}
                    raise
        changed = {asset.logical.casefold() for asset in source.assets.values()} & reached
        return Candidate(record, reached, changed)

    def _mesh_placeholder(self, logical, source):
        from mesh_probe import placeholder
        self.check_cancel()
        asset = source.get(logical)
        if not asset:
            return {'hide': False, 'reason': 'unmodified-visible-mesh'}
        key = str(asset.path)
        if key not in self.geometry_cache:
            baseline = self.game.find(logical)
            self.geometry_cache[key] = placeholder(asset.path.read_bytes(), baseline.path.read_bytes()) if baseline else {'hide': False, 'reason': 'no-original-mesh'}
        return self.geometry_cache[key]

    def _placeholder_parts(self, candidates, source, result):
        hidden = {}
        variants = {c.record['variant'] for c in candidates if c.record['part'] == 'BODY'}
        for variant in variants:
            for part in ('HEAD', 'HAIR', 'BODY_SUB', 'CLOAK', 'GAUNTLET'):
                options = [c for c in candidates if c.record['variant'] == variant and c.record['part'] == part]
                decisions = []
                for candidate in options:
                    meshes = [key for key in candidate.reached if key.endswith('.mesh')]
                    materials = [key for key in candidate.reached if key.endswith('.mdf2')]
                    # Only stock prefab graphs prove the complete renderer set.
                    # A mixed or custom graph keeps its original mesh/material
                    # replacement, including zero-material MDF bytes unchanged.
                    empty_materials = (bool(meshes) and bool(materials)
                        and source.get(candidate.record['prefab']) is None
                        and all((asset := source.get(key)) is not None
                                and mc.is_empty_mdf(asset.path.read_bytes()) for key in materials))
                    if empty_materials:
                        result.placeholder_evidence.append({'prefab': candidate.record['prefab'],
                            'part': part, 'hide': True, 'reason': 'zero-material-mdf',
                            'materials': sorted(materials)})
                        decisions.append(True)
                        continue
                    proofs = []
                    for logical in meshes:
                        proof = self._mesh_placeholder(logical, source)
                        proofs.append(proof)
                        result.placeholder_evidence.append({'path': logical, 'part': part, **proof})
                    decisions.append(bool(proofs) and all(proof['hide'] for proof in proofs))
                if options and all(decisions): hidden[(variant, part)] = set().union(*(c.changed for c in options))
        return hidden

    def convert(self, source: Path, output_root: Path | None = None) -> Result:
        source = Path(source).resolve(strict=True)
        output_root = Path(output_root).resolve() if output_root is not None else source.parent
        if any(output_root == root or output_root.is_relative_to(root) for root in (source, self.game_root)):
            raise InputError('请把输出目录设在 Mod 和游戏目录之外。', 'OUTPUT_INSIDE_INPUT')
        self._setup(source)
        result = Result(str(source))
        layers = list(self._layers(source, result))
        if not layers: raise InputError('没有找到可转换的模型或纹理。', 'NO_ASSETS')
        output_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.owots-', dir=output_root) as temporary:
            package = Path(temporary)/'package'
            package.mkdir()
            for number, layer in enumerate(layers):
                self._convert_layer(layer, source, number, package, result)
            self.check_cancel()
            if not result.entries: raise InputError('没有找到可注册的服装、披风、护手或武器。', 'NO_MATCHING_PARTS')
            result.status = 'needs_test' if result.notices else 'converted'
            self._verify_links(package, result.entries)
            self._publish_archive(package, source, output_root, result)
        return result

    def _publish_archive(self, package: Path, source: Path, output_root: Path, result: Result):
        name = source.name if source.is_dir() else source.stem
        base = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', name).strip(' .')[:80] or 'Mod'
        archive = package.parent/'result.zip'
        count = 1
        while True:
            suffix = '' if count == 1 else f' ({count})'
            destination = output_root/(base + '-衣橱' + suffix + '.zip')
            count += 1
            if destination.exists() or destination.is_symlink(): continue
            result.output = str(destination)
            (package/'conversion-report.json').write_text(json.dumps(result.as_dict(), ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
            self.progress('正在打包…')
            with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
                for path in sorted(package.rglob('*')):
                    self.check_cancel()
                    if not path.is_file(): continue
                    with path.open('rb') as incoming, bundle.open(path.relative_to(package).as_posix(), 'w', force_zip64=True) as outgoing:
                        while chunk := incoming.read(1024*1024):
                            self.check_cancel()
                            outgoing.write(chunk)
            self.progress('正在检查压缩包…')
            with zipfile.ZipFile(archive) as bundle:
                for member in bundle.infolist():
                    with bundle.open(member) as incoming:
                        while incoming.read(1024*1024): self.check_cancel()
            self.check_cancel()
            try:
                # Windows rename refuses an existing target, including one
                # created by another conversion after the name check above.
                archive.rename(destination)
                return
            except FileExistsError:
                continue

    def _convert_layer(self, layer, original, layer_number, package, result):
        report = mc.Report('batch', original)
        index = mc.HashIndex.from_file(mc.bundled_file_list(), report) if layer.suffix.casefold() == '.pak' else None
        bundle = mc.InputBundle(layer, report, index)
        bundle.load()
        if bundle.temp: self.stack.callback(bundle.temp.cleanup)
        if report.errors: raise mc.ConversionError(report.errors[0].message, report.errors[0].code)
        unsupported = [path for path in bundle.source.other_files if re.search(r'\.[a-z][a-z0-9_]*\.\d+$', path, re.I)]
        if unsupported:
            result.notices.append(Notice('OUTSIDE_WARDROBE_SCOPE', '这些资源暂不能转为服装，已跳过；部分效果可能无法工作。', unsupported))
        candidates = []
        scan_errors = []
        for index, record in enumerate(self.records):
            self.progress(f'正在识别部位… {index+1}/{len(self.records)}')
            try:
                candidate = self._candidate(record, bundle.source)
                if candidate.changed: candidates.append(candidate)
            except (mc.ConversionError, ValueError, OSError) as error:
                authored = {asset.logical.casefold() for asset in bundle.source.assets.values()}
                if authored & getattr(error, 'reached_assets', set()):
                    scan_errors.append({'prefab': record['prefab'], 'part': record['part'], 'reason': str(error)})
        critical_errors = [e for e in scan_errors if e['part'] in ('HEAD', 'HAIR')]
        if critical_errors:
            raise mc.ConversionError('头部或头发替换无法完整读取，已停止转换，避免原角色头部重叠。\n'
                + '\n'.join(e['prefab'] + ': ' + e['reason'] for e in critical_errors),
                'HEAD_REPLACEMENT_INCOMPLETE')
        hidden = self._placeholder_parts(candidates, bundle.source, result)
        groups = group_candidates([c for c in candidates if (c.record['variant'], c.record['part']) not in hidden])
        if not groups:
            result.notices.append(Notice('NO_MATCHING_PARTS', '没有找到对应的可穿戴部位。', [str(layer)]))
            result.ledger.extend({'path': a.logical, 'disposition': 'unrecognized'} for a in bundle.source.assets.values())
            return
        self.progress('正在合并重复外观…')
        hidden_assets = set().union(*hidden.values()) if hidden else set()
        comparison_meshes = set()
        def hidden_mesh(logical):
            proof = self._mesh_placeholder(logical, bundle.source)
            if proof['hide'] and logical not in comparison_meshes:
                comparison_meshes.add(logical)
                result.placeholder_evidence.append({'path': logical, 'purpose': 'duplicate-comparison', **proof})
            return proof['hide']
        fingerprints = AppearanceFingerprints(bundle.source, self.game, self.records,
                                              self._dependencies, self.check_cancel, hidden_assets, hidden_mesh)
        body_rules = json.loads((Path(mc.__file__).parent/'runtime/owots_body_rules.json').read_text(encoding='utf-8'))['records']
        plans = deduplicate_groups(groups, fingerprints, hidden, body_rules, mc.PART_CATEGORY, companion_candidates)
        used = set()
        duplicate_assets = {}
        rig_fallbacks = set()
        registrations = []
        for group_number, appearance in enumerate(plans):
            group = appearance.group
            self.check_cancel()
            category = mc.PART_CATEGORY[group[0].record['part']]
            identity_seed = str(original) + '\0' + str(layer_number) + '\0' + '|'.join(c.record['prefab'] for c in group)
            identity = 'c' + hashlib.sha256(identity_seed.encode()).hexdigest()[:12]
            label = f'{original.name if original.is_dir() else original.stem} · {LABELS[category]} {len(result.entries)+1}'
            if group[0].record['variant'] == 'hq': label += ' HQ'
            self.progress(f'正在转换 {LABELS[category]}… {group_number+1}/{len(plans)}')
            work = Path(self.stack.enter_context(tempfile.TemporaryDirectory(prefix='owots-plan-')))
            plan = {'parts': [{'part': c.record['part'], 'prefab': c.record['prefab'], 'catalog': c.record['catalog'], 'nativeId': c.record['native_id']} for c in group]}
            plan_path = work/'parts.json'
            plan_path.write_text(json.dumps(plan), encoding='utf-8')
            args = mc.make_parser().parse_args(['convert', '--input', str(layer), '--output', str(work/'result'), '--game-root', str(self.game_root), '--id', identity, '--category', category, '--parts-plan', str(plan_path)])
            args.asset_only = True
            args.body_rule_hides = True
            if any(c.record['part'] == 'BODY' for c in group):
                args.hide_parts = [part for (variant, part) in hidden if variant == group[0].record['variant']]
            converter = PlannedConverter(args, mc.Report('convert', original))
            converter.worker = self.worker
            chosen = mc.InputBundle(layer, converter.report)
            chosen.source = mc.SourceFiles(bundle.source.root, converter.report)
            reached = set().union(*(c.reached for c in group))
            chosen.source.assets = {key: asset for key, asset in bundle.source.assets.items() if key[0] in reached}
            if category == 'body' and any(c.record['part'] == 'BODY' for c in group):
                for key, asset in bundle.source.assets.items():
                    if asset.extension == '.fbxskel': chosen.source.assets[key] = asset
            try:
                converter.prepare(bundle=chosen, game=self.game)
            except mc.ConversionError:
                if converter.report.errors:
                    issue = converter.report.errors[0]
                    raise mc.ConversionError(issue.message + ('\n' + issue.path if issue.path else ''), issue.code)
                raise
            converter.publish(work/'result')
            for fallback in converter.report.stats.get('actorSkeletonFallbacks', []):
                rig_fallbacks.add(fallback['source'].casefold())
            manifest = json.loads((work/'result'/converter.report.stats['manifest']).read_text(encoding='utf-8'))
            manifest['name'] = label
            entry = {'id': identity, 'name': label, 'category': category, 'parts': [c.record['part'] for c in group], 'targets': [c.record for c in group], 'coveredTargets': appearance.covered_targets, 'appearanceFingerprint': appearance.fingerprint, 'duplicateEvidence': appearance.merge_evidence, 'manifest': 'reframework/data/owots_appearance_lab/mods/'+identity+'/manifest.json'}
            for logical in appearance.duplicate_assets:
                duplicate_assets.setdefault(logical, []).append(identity)
            registrations.append((manifest, entry))
            for path in (work/'result').rglob('*'):
                if path.is_file() and path.relative_to(work/'result').parts[0] in ('natives', 'reframework'):
                    target = package/path.relative_to(work/'result')
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with target.open('xb') as stream: stream.write(path.read_bytes())
            report_dir = package/'reports'
            report_dir.mkdir(exist_ok=True)
            (report_dir/(identity+'.json')).write_text(json.dumps(converter.report.as_dict(), ensure_ascii=False, indent=2), encoding='utf-8')
            used.update(a.logical.casefold() for a in chosen.source.assets.values())
            result.entries.append(entry)
        for manifest, entry in registrations:
            if entry['category'] == 'body' and 'BODY' in entry['parts']:
                equip = {}
                for category in ('cloak', 'gauntlet'):
                    companions = companion_candidates(entry, [e for _, e in registrations], category)
                    if len(companions) == 1:
                        equip[category] = companions[0]['id']
                        manifest['rules']['hideParts'] = [p for p in manifest['rules']['hideParts'] if mc.PART_CATEGORY[p] != category]
                    elif len(companions) > 1:
                        result.notices.append(Notice('COMPANION_AMBIGUOUS', f'发现多个{LABELS[category]}，已分别转换；穿戴后可自行选择。', [c['name'] for c in companions]))
                if equip:
                    manifest['rules']['equip'] = equip
            (package/entry['manifest']).write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        for asset in bundle.source.assets.values():
            consumed = asset.logical.casefold() in used
            declared = any(asset.logical.casefold() in values for values in hidden.values())
            aliases = duplicate_assets.get(asset.logical.casefold(), [])
            row = {'path': asset.logical, 'streaming': asset.streaming, 'disposition': 'mesh-rest-fallback' if asset.logical.casefold() in rig_fallbacks else 'converted' if consumed else 'declared-hide' if declared else 'duplicate-appearance' if aliases else 'unrecognized'}
            if aliases: row['representedBy'] = aliases
            result.ledger.append(row)
        if rig_fallbacks:
            result.notices.append(Notice('ACTOR_SKELETON_ROTATION_MESH_FALLBACK',
                '已使用模型内的体型数据；独立骨架的旋转未迁移，请进游戏测试。', sorted(rig_fallbacks)))
        omitted = [a.logical for a in bundle.source.assets.values() if a.logical.casefold() not in used | hidden_assets | duplicate_assets.keys()]
        if omitted: result.notices.append(Notice('UNRECOGNIZED_ASSETS', f'{len(omitted)} 个资源没有找到可穿戴部位，未加入结果。', omitted))
        if scan_errors and omitted:
            result.notices.append(Notice('PART_SCAN_INCOMPLETE', '部分部位无法读取，可能影响识别结果。', [e['prefab']+': '+e['reason'] for e in scan_errors]))

    @staticmethod
    def _verify_links(package, entries):
        manifests = {e['id']: json.loads((package/e['manifest']).read_text(encoding='utf-8')) for e in entries}
        for manifest in manifests.values():
            for category, identity in manifest['rules'].get('equip', {}).items():
                if identity not in manifests or manifests[identity]['category'] != category:
                    raise mc.ConversionError('配套附件未完整生成，转换已停止。', 'EQUIP_PACKAGE_INCOMPLETE')
            for part in manifest['parts']:
                for key, version in (('catalog', '3'), ('prefab', '18')):
                    if not (package/mc.physical_for(part[key], version, False)).is_file():
                        raise mc.ConversionError('转换结果缺少必要文件。', 'OUTPUT_REFERENCE_MISSING')


def main(argv=None):
    """The same automatic workflow for local automation and frozen acceptance."""
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, help='Optional output folder; defaults to beside the input')
    parser.add_argument('--game-root', type=Path, required=True)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args(argv)
    if args.report:
        destination = args.report.resolve()
        if destination.exists() or any(destination == root.resolve() or destination.is_relative_to(root.resolve()) for root in (args.input, args.game_root)):
            raise InputError('报告必须写到 Mod 和游戏目录之外的新文件。', 'REPORT_PATH_UNSAFE')
    try:
        with BatchConverter(args.game_root) as converter:
            value = converter.convert(args.input, args.output).as_dict()
        code = 0
    except Exception as error:
        value = {'source': str(args.input), 'status': 'blocked', 'code': getattr(error, 'code', type(error).__name__), 'message': str(error)}
        code = 2
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with args.report.open('x', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
    else: print(json.dumps(value, ensure_ascii=False, indent=2))
    return code


if __name__ == '__main__': raise SystemExit(main())
